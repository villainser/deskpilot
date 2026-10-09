import AppKit
import ApplicationServices

func ax(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}
func axChildren(_ element: AXUIElement) -> [AXUIElement] { ax(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

protocol SystemAccessProtocol: AnyObject {
    var onEvent: ((String, Int32?, UInt32?) -> Void)? { get set }
    var trusted: Bool { get }
    var canMove: Bool { get }
    var lastReadMilliseconds: Double { get }
    var missionControlHost: String? { get }
    var windowDiscovery: [String: [String: Int]] { get }
    var windowInteraction: [String: [String: Int]] { get }
    func start()
    func screens() -> [Display]
    func spaces(displays: [Display]) -> [Desktop]?
    func readWindows(dirty: Set<Int32>?) -> [WindowInfo]
    func windowIdentities() -> Set<WindowIdentity>?
    func focusedWindowID() -> UInt32?
    func pointerDisplayID() -> String?
    func processStarted(_ pid: Int32) -> Date?
    func focusWindow(_ windowID: UInt32) -> Bool
    func isWindowVisible(_ windowID: UInt32) -> Bool
    func setMinimized(_ minimized: Bool, windowID: UInt32) -> Bool
    func missionControlRoot() -> AXUIElement?
    @MainActor func missionControl(display: Display, select: Desktop?, create: Bool) async throws
    func setFrame(_ rect: CGRect, windowID: UInt32) -> Bool
    func beginMove(_ windowID: UInt32, to spaceID: UInt64) -> String?
    func windowSpaces(_ windowID: UInt32) -> [UInt64]?
    func endMove()
}

extension SystemAccessProtocol {
    var missionControlHost: String? { nil }
    var windowDiscovery: [String: [String: Int]] { [:] }
    var windowInteraction: [String: [String: Int]] { [:] }
}

final class SystemAccess: SystemAccessProtocol {
    var onEvent: ((String, Int32?, UInt32?) -> Void)?
    private var observers: [Int32: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var observedWindows = Set<String>()
    private var cache: [Int32: [WindowInfo]] = [:]
    var elements: [UInt32: AXUIElement] = [:]
    var readCount = 0
    var lastReadMilliseconds = 0.0
    private(set) var missionControlHost: String?
    private(set) var windowDiscovery: [String: [String: Int]] = [:]
    private(set) var windowInteraction: [String: [String: Int]] = [:]

    var trusted: Bool { AXIsProcessTrusted() }
    var canMove: Bool { DPCanMove() }
    func beginMove(_ windowID: UInt32, to spaceID: UInt64) -> String? { DPBeginMove(windowID, spaceID) }
    func windowSpaces(_ windowID: UInt32) -> [UInt64]? { (DPWindowSpaces(windowID) as? [NSNumber])?.map(\.uint64Value) }
    func endMove() { DPEndMove() }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                      NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                      NSWorkspace.didWakeNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            tokens.append(nc.addObserver(forName: event, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if note.name == NSWorkspace.didTerminateApplicationNotification, let pid = app?.processIdentifier { self?.remove(pid) }
                self?.attachObservers()
                self?.onEvent?(note.name.rawValue, app?.processIdentifier, nil)
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onEvent?("displays", nil, nil)
        })
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            tokens.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in self?.onEvent?(note.name.rawValue, nil, nil) })
        }
        attachObservers()
    }

    func attachObservers() {
        guard trusted else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            let pid = app.processIdentifier
            guard observers[pid] == nil else { continue }
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, element, notification, context in
                guard let context else { return }
                let owner = Unmanaged<SystemAccess>.fromOpaque(context).takeUnretainedValue()
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                let id = DPWindowID(element)
                owner.onEvent?(notification as String, pid, id == 0 ? nil : id)
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
            observers[pid] = observer
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.3)
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
                AXObserverAddNotification(observer, root, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    private func remove(_ pid: Int32) {
        if let observer = observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        for item in cache.removeValue(forKey: pid) ?? [] { elements[item.id] = nil; observedWindows.remove("\(pid):\(item.id)") }
    }

    func screens() -> [Display] {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid) as String
            let visible = CGRect(x: screen.visibleFrame.minX, y: primaryHeight - screen.visibleFrame.maxY, width: screen.visibleFrame.width, height: screen.visibleFrame.height)
            return Display(id: id, systemID: number.uint32Value, name: screen.localizedName, builtIn: CGDisplayIsBuiltin(number.uint32Value) != 0,
                           frame: CGDisplayBounds(number.uint32Value), visibleFrame: visible)
        }.sorted { $0.frame.minX < $1.frame.minX }
    }

    func spaces(displays: [Display]) -> [Desktop]? {
        guard let raw = DPSpaces() as? [[String: Any]] else { return nil }
        var result: [Desktop] = []
        for display in raw {
            guard let displayID = display["Display Identifier"] as? String,
                  let rows = display["Spaces"] as? [[String: Any]] else { continue }
            let mappedDisplay = displayID == "Main" ? displays.first?.id ?? displayID : displayID
            let current = display["Current Space"] as? [String: Any]
            let active = (current?["id64"] as? NSNumber)?.uint64Value ?? (current?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            for (index, row) in rows.enumerated() {
                guard let number = (row["id64"] ?? row["ManagedSpaceID"]) as? NSNumber else { continue }
                let uuid = row["uuid"] as? String
                let key = uuid.flatMap { $0.isEmpty ? nil : $0 } ?? "session:\(mappedDisplay):\(number)"
                result.append(Desktop(id: key, systemID: number.uint64Value, displayID: mappedDisplay, ordinal: index,
                                      fullScreen: (row["type"] as? NSNumber)?.intValue != 0, active: active == number.uint64Value))
            }
        }
        return result.isEmpty ? nil : result
    }

    func readWindows(dirty: Set<Int32>? = nil) -> [WindowInfo] {
        let began = ProcessInfo.processInfo.systemUptime
        readCount += 1
        attachObservers()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        let running = Set(apps.map(\.processIdentifier))
        let appIDs = Set(apps.map { $0.bundleIdentifier ?? "pid:\($0.processIdentifier)" })
        windowDiscovery = windowDiscovery.filter { appIDs.contains($0.key) }
        for pid in Array(cache.keys) where !running.contains(pid) { remove(pid) }
        for app in apps where dirty == nil || dirty!.contains(app.processIdentifier) || cache[app.processIdentifier] == nil {
            let pid = app.processIdentifier, root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.3)
            let appID = app.bundleIdentifier ?? "pid:\(pid)"
            var readError: AXError = .success
            func read(_ element: AXUIElement) -> [AXUIElement]? {
                var value: CFTypeRef?
                readError = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
                return readError == .success ? value as? [AXUIElement] : nil
            }
            let appWindows: [AXUIElement]?
            if app.bundleIdentifier == "com.google.Chrome" {
                appWindows = ChromeAccessibility.windows(application: root,
                    role: { ax($0, kAXRoleAttribute) as? String },
                    read: read)
            } else {
                // Electron applications also lazily initialize native accessibility.
                _ = ax(root, kAXRoleAttribute)
                appWindows = read(root)
            }
            var diagnostic = ["readError": Int(readError.rawValue), "reportedWindows": appWindows?.count ?? -1,
                              "missingNativeID": 0, "nonStandardWindows": 0, "acceptedWindows": 0]
            guard let windows = appWindows else { windowDiscovery[appID] = diagnostic; continue }
            var records: [WindowInfo] = []
            for window in windows {
                let id = DPWindowID(window)
                guard id > 0 else { diagnostic["missingNativeID", default: 0] += 1; continue }
                guard ax(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else {
                    diagnostic["nonStandardWindows", default: 0] += 1; continue
                }
                elements[id] = window
                var point = CGPoint.zero, size = CGSize.zero
                if let value = ax(window, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
                if let value = ax(window, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgSize, &size) }
                let spaces = (DPWindowSpaces(id) as? [NSNumber] ?? []).map(\.uint64Value)
                var record = WindowInfo(id: id, pid: pid, appID: app.bundleIdentifier ?? app.bundleURL?.path ?? "pid:\(pid)",
                                          appName: app.localizedName ?? "Application", title: ax(window, kAXTitleAttribute) as? String ?? "",
                                          frame: CGRect(origin: point, size: size), spaceIDs: spaces,
                                          minimized: ax(window, kAXMinimizedAttribute) as? Bool ?? false)
                if record.appID == "com.google.Chrome" { record.accessibilityTitles = chromeWindowTitles(window) }
                records.append(record)
                diagnostic["acceptedWindows", default: 0] += 1
                let identity = "\(pid):\(id)"
                if !observedWindows.contains(identity), let observer = observers[pid] {
                    for name in [kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                        AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque())
                    }
                    observedWindows.insert(identity)
                }
            }
            // A missing AX window can be inaccessible on an unvisited desktop.
            // Retain it only while WindowServer still confirms its identity.
            let nowIDs = Set(records.map(\.id))
            for old in cache[pid] ?? [] where !nowIDs.contains(old.id) {
                if let spaces = DPWindowSpaces(old.id) as? [NSNumber], !spaces.isEmpty {
                    var kept = old
                    kept.spaceIDs = spaces.map(\.uint64Value)
                    records.append(kept)
                } else { elements[old.id] = nil; observedWindows.remove("\(pid):\(old.id)") }
            }
            cache[pid] = records
            diagnostic["cachedWindows"] = records.count
            windowDiscovery[appID] = diagnostic
        }
        lastReadMilliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
        return cache.values.flatMap { $0 }.sorted { $0.id < $1.id }
    }

    private func chromeWindowTitles(_ window: AXUIElement) -> [String] {
        ChromeAccessibility.windowTitles(window: window,
            role: { ax($0, kAXRoleAttribute) as? String },
            strings: { element in [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { ax(element, $0) as? String } },
            children: axChildren)
    }

    func windowIdentities() -> Set<WindowIdentity>? {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        return Set(rows.compactMap { row in
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != getpid() else { return nil }
            return WindowIdentity(pid: pid, windowID: id)
        })
    }

    func occupancy() -> [UInt64: Set<UInt32>]? {
        guard let descriptions = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var map: [UInt64: Set<UInt32>] = [:]
        for row in descriptions {
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != getpid() else { continue }
            guard let locations = DPWindowSpaces(id) as? [NSNumber] else { return nil }
            for space in locations { map[space.uint64Value, default: []].insert(id) }
        }
        return map
    }

    func setFrame(_ rect: CGRect, windowID: UInt32) -> Bool {
        windowInteraction["frame"] = ["windowID": Int(windowID), "elementAvailable": elements[windowID] == nil ? 0 : 1]
        guard let element = elements[windowID] else { return false }
        var position = rect.origin, size = rect.size
        guard let p = AXValueCreate(.cgPoint, &position), let s = AXValueCreate(.cgSize, &size) else { return false }
        let resize = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        let move = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        windowInteraction["frame"]?["resize"] = Int(resize.rawValue)
        windowInteraction["frame"]?["position"] = Int(move.rawValue)
        return move == .success && resize == .success
    }

    func focusedWindowID() -> UInt32? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let value = ax(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let id = DPWindowID(value as! AXUIElement)
        return id == 0 ? nil : id
    }

    func pointerDisplayID() -> String? {
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - mouse.y)
        return screens().first { $0.frame.contains(point) }?.id
    }

    func windowAtPointer() -> UInt32? {
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - mouse.y)
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for row in rows {
            guard (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            // Menus, panels and other overlays block focus through them.
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  elements[id] != nil else { return nil }
            return id
        }
        return nil
    }

    func processStarted(_ pid: Int32) -> Date? { DPProcessStartDate(pid) }

    func setMinimized(_ minimized: Bool, windowID: UInt32) -> Bool {
        guard let element = elements[windowID] else { return false }
        return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    func focusWindow(_ windowID: UInt32) -> Bool {
        windowInteraction["focus"] = ["windowID": Int(windowID), "elementAvailable": elements[windowID] == nil ? 0 : 1]
        guard let element = elements[windowID] else { return false }
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        windowInteraction["focus"]?["pidRead"] = Int(pidResult.rawValue)
        guard pidResult == .success, let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let root = AXUIElementCreateApplication(pid)
        windowInteraction["focus"]?["mainWindow"] = Int(AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue).rawValue)
        windowInteraction["focus"]?["focusedWindow"] = Int(AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, element).rawValue)
        if app.isHidden { app.unhide() }
        // A nonactivating picker leaves another app frontmost. LaunchServices
        // can refuse activate() from that background app even after AXRaise
        // succeeds. Use the granted Accessibility channel to activate the owner.
        let activationResult = AXUIElementSetAttributeValue(root, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        windowInteraction["focus"]?["frontmost"] = Int(activationResult.rawValue)
        let activated = activationResult == .success
        windowInteraction["focus"]?["activationAccepted"] = activated ? 1 : 0
        windowInteraction["focus"]?["focused"] = Int(AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)
        let raiseResult = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        windowInteraction["focus"]?["raise"] = Int(raiseResult.rawValue)
        let raised = raiseResult == .success
        return activated && raised
    }

    func isWindowVisible(_ windowID: UInt32) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }) else { return false }
        return (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
            && ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
    }

    func find(_ id: String, below root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if ax(root, kAXIdentifierAttribute) as? String == id { return root }
        guard depth < 6 else { return nil }
        for child in axChildren(root) { if let match = find(id, below: child, depth: depth + 1) { return match } }
        return nil
    }

    static var missionControlHosts: [String] {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? ["com.apple.WindowManager", "com.apple.dock"] : ["com.apple.dock", "com.apple.WindowManager"]
    }

    func missionControlRoot() -> AXUIElement? {
        guard trusted else { return nil }
        for bundleID in Self.missionControlHosts {
            for host in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let root = AXUIElementCreateApplication(host.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.08)
                if let live = MissionControlAccessibility.liveRoot(in: [root], identifier: { ax($0, kAXIdentifierAttribute) as? String }, children: axChildren) {
                    missionControlHost = bundleID
                    return live
                }
            }
        }
        return nil
    }

    @MainActor func missionControl(display: Display, select: Desktop? = nil, create: Bool = false) async throws {
        guard trusted else { throw AppError.message("Grant window management access to DeskPilot.") }
        let alreadyOpen = missionControlRoot() != nil
        defer { if !alreadyOpen { escapeMissionControl() } }
        if !alreadyOpen {
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            let config = NSWorkspace.OpenConfiguration()
            try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        var target: AXUIElement?
        for _ in 0..<20 {
            if let root = missionControlRoot() {
                target = missionControlDisplay(display, below: root)
                if target != nil { break }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let target else { throw AppError.message("Mission Control did not expose the selected display.") }
        try await Task.sleep(nanoseconds: 180_000_000)
        if create {
            guard let button = find("mc.spaces.add", below: target), AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { throw AppError.message("Unable to create a desktop. Check the macOS Space limit.") }
            try await Task.sleep(nanoseconds: 250_000_000)
        } else if let selected = select {
            guard let list = find("mc.spaces.list", below: target) else { throw AppError.message("Mission Control did not expose its desktop list.") }
            let buttons = axChildren(list)
            // Re-check native identity before acting on a position.
            guard let current = spaces(displays: screens())?.first(where: { $0.id == selected.id }), current.displayID == display.id,
                  current.ordinal < buttons.count else { throw AppError.message("Desktop order changed. Try switching again.") }
            guard AXUIElementPerformAction(buttons[current.ordinal], kAXPressAction as CFString) == .success else { throw AppError.message("macOS refused to switch desktops.") }
        }
    }

    func missionControlDisplay(_ display: Display, below root: AXUIElement) -> AXUIElement? {
        let candidates = MissionControlAccessibility.displays(in: root, identifier: { ax($0, kAXIdentifierAttribute) as? String }, children: axChildren)
        return MissionControlAccessibility.display(in: candidates, targetID: display.systemID, targetFrame: display.frame, displayID: { element in
            if let number = ax(element, "AXDisplayID") as? NSNumber { return number.uint32Value }
            if let string = ax(element, "AXDisplayID") as? String { return UInt32(string) }
            return nil
        }, frame: { element in
            guard let p = ax(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = ax(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var position = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: position, size: size)
        })
    }

    func escapeMissionControl() {
        guard missionControlRoot() != nil else { return }
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
