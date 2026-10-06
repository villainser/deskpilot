import AppKit

// Read Dock's Space thumbnail geometry and display click-through name badges.
// No Dock injection, system preference patching or screenshot capture is used.
@MainActor final class MissionControlNames {
    static let preference = "showMissionControlNames"
    static let preferenceChanged = Notification.Name("DeskPilotMissionControlNamesChanged")
    private weak var engine: Engine?
    private let access = SystemAccess()
    private var panels: [String: NSPanel] = [:]
    private var labels: [String: NSTextField] = [:]
    private var timer: Timer?
    private var dockObserver: AXObserver?
    private var dockPID: Int32?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var preferenceToken: NSObjectProtocol?
    private var locked = false
    private var visible = false

    init(engine: Engine) { self.engine = engine }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.preference) as? Bool ?? true
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.schedule(after: 0.15) }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributedTokens.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self else { return }
                    self.locked = note.name.rawValue == "com.apple.screenIsLocked"
                    if self.locked { self.timer?.invalidate(); self.timer = nil; self.hide() }
                    else { self.schedule(after: 0.3) }
                }
            })
        }
        preferenceToken = NotificationCenter.default.addObserver(forName: Self.preferenceChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.timer?.invalidate(); self?.timer = nil
                self?.hide(); self?.schedule(after: 0.1)
            }
        }
        schedule(after: 0.2)
    }

    func stop() {
        timer?.invalidate(); timer = nil; hide()
        if let observer = dockObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        dockObserver = nil; dockPID = nil
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in distributedTokens { DistributedNotificationCenter.default().removeObserver(token) }
        if let token = preferenceToken { NotificationCenter.default.removeObserver(token) }
        workspaceTokens.removeAll(); distributedTokens.removeAll(); preferenceToken = nil
    }

    func namesChanged() { if visible { schedule(after: 0.05) } }

    private func schedule(after delay: TimeInterval) {
        guard enabled, !locked else { return }
        if let timer, timer.fireDate <= Date().addingTimeInterval(delay) { return }
        timer?.invalidate()
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.timer = nil; self?.update() }
        }
        next.tolerance = min(delay / 4, 0.2)
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    private func observeDock() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              dockPID != dock.processIdentifier else { return }
        if let observer = dockObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        dockObserver = nil; dockPID = nil
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let owner = Unmanaged<MissionControlNames>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak owner] in owner?.schedule(after: 0.08) }
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.08)
        for name in [kAXWindowCreatedNotification, kAXFocusedUIElementChangedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        dockObserver = observer; dockPID = dock.processIdentifier
    }

    private func update() {
        guard enabled, !locked else { hide(); return }
        guard access.trusted else { hide(); schedule(after: 1.5); return }
        observeDock()
        guard let root = access.missionControlRoot() else {
            hide(); schedule(after: 1.5); return
        }
        visible = true
        defer { schedule(after: 0.25) }
        let displays = access.screens()
        guard let desktops = access.spaces(displays: displays), let engine else { hide(); return }
        var proposed: [(Desktop, CGRect, String)] = []
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        for display in displays {
            guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.systemID }),
                  let container = access.missionControlDisplay(display.systemID, below: root),
                  let list = access.find("mc.spaces.list", below: container) else { continue }
            let entries = axChildren(list)
            let frames = entries.map { self.frame($0) ?? .zero }
            for (desktop, frame) in MissionControlLabelPolicy.paired(desktops: desktops, frames: frames, displayID: display.id) {
                guard let position = MissionControlLabelPolicy.frame(thumbnail: frame, screen: screen.frame, primaryHeight: primaryHeight) else { continue }
                let name = engine.name(desktop)
                guard name != "Desktop \(desktop.ordinal + 1)" else { continue }
                proposed.append((desktop, position, name))
            }
        }
        // The user can reorder a thumbnail while we read its geometry.
        guard access.spaces(displays: displays) == desktops else { hide(); return }
        let keep = Set(proposed.map { $0.0.id })
        for id in Array(panels.keys) where !keep.contains(id) { panels.removeValue(forKey: id)?.close(); labels[id] = nil }
        for (desktop, rect, name) in proposed { show(desktop.id, name: name, frame: rect) }
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = ax(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = ax(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func show(_ id: String, name: String, frame: CGRect) {
        let panel: NSPanel
        if let existing = panels[id] { panel = existing }
        else {
            panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let label = NSTextField(labelWithString: name)
            label.alignment = .center; label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .white; label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.94).cgColor
            content.layer?.cornerRadius = 7
            content.addSubview(label); panel.contentView = content
            panels[id] = panel; labels[id] = label
        }
        labels[id]?.stringValue = name
        labels[id]?.frame = CGRect(x: 6, y: 4, width: frame.width - 12, height: 17)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hide() {
        visible = false
        for panel in panels.values { panel.orderOut(nil) }
    }
}
