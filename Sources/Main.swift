import AppKit
import SwiftUI
import Carbon
import Darwin

// Keep one automation engine per settings directory, including copies launched
// from different folders. The operating system releases this lock on exit.
final class AppInstance {
    private let descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if descriptor < 0 { throw AppError.message("Unable to acquire the application lock.") }
    }
    func acquire() -> Bool { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }
    deinit { close(descriptor) }
}

final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var action: ((UInt32) -> Void)?
    var failures: [UInt32] = []
    func start() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue().action?(id.id)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let modifier = UInt32(controlKey | optionKey)
        register(1, key: 49, modifiers: modifier)
        register(2, key: 35, modifiers: modifier)
        register(3, key: 123, modifiers: modifier)
        register(4, key: 124, modifiers: modifier)
        let numbers: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, key) in numbers.enumerated() {
            register(UInt32(10 + index), key: key, modifiers: modifier)
            register(UInt32(30 + index), key: key, modifiers: modifier | UInt32(shiftKey))
        }
    }
    private func register(_ id: UInt32, key: UInt32, modifiers: UInt32) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x44504e56, id: id), GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference { refs.append(reference) } else { failures.append(id) }
    }
    deinit { for ref in refs { UnregisterEventHotKey(ref) }; if let handler { RemoveEventHandler(handler) } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var item: NSStatusItem!
    var engine: Engine!
    let hotkeys = Hotkeys()
    var missionControlNames: MissionControlNames?
    private var showToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        var dataURL: URL?
        if let index = args.firstIndex(of: "--data-dir"), index + 1 < args.count { dataURL = URL(fileURLWithPath: args[index + 1], isDirectory: true).appendingPathComponent("state.json") }
        engine = Engine(dataURL: dataURL)
        engine.onChange = { [weak self] in self?.updateMenu(); self?.missionControlNames?.namesChanged() }
        engine.start()
        engine.writeRuntimeStatus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DeskPilot"
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: RootView(engine: engine, ui: PanelState()))
        window.center()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenu()
        makeApplicationMenu()
        missionControlNames = MissionControlNames(engine: engine)
        missionControlNames?.start()
        showToken = DistributedNotificationCenter.default().addObserver(forName: .init("pl.deskpilot.native.show"), object: engine.dataURL.deletingLastPathComponent().path, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }
        hotkeys.action = { [weak self] id in Task { @MainActor in self?.hotkey(id) } }
        hotkeys.start()
        if !hotkeys.failures.isEmpty { engine.lastError = "Some shortcuts are used by another app. The panel controls remain available." }
        if !args.contains("--background") { show() }
        if args.contains("--smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationWillTerminate(_ notification: Notification) { missionControlNames?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard engine != nil else { return }
        engine.checkAccessibility()
    }

    func makeApplicationMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem(); root.addItem(appItem)
        let menu = NSMenu(title: "DeskPilot")
        let showItem = NSMenuItem(title: "Show panel", action: #selector(show), keyEquivalent: "0"); showItem.target = self; menu.addItem(showItem)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide DeskPilot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"); hide.target = NSApp; menu.addItem(hide)
        let quit = NSMenuItem(title: "Quit DeskPilot", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        appItem.submenu = menu
        NSApp.mainMenu = root
    }

    @objc func show() {
        if let current = engine.system.focusedWindowID() { engine.rememberedWindow = current }
        engine.checkAccessibility()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func toggle() { if window.isVisible && window.isKeyWindow { window.orderOut(nil) } else { show() } }
    @objc func pause() { engine.toggleEnabled() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func switchFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let desktop = engine.desktops.first(where: { $0.id == id }) { engine.switchTo(desktop) }
    }

    func updateMenu() {
        guard item != nil else { return }
        let names = engine.desktops.filter(\.active).map { engine.name($0) }
        item.button?.title = String((names.isEmpty ? "DeskPilot" : names.joined(separator: " · ")).prefix(40))
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "DeskPilot")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open DeskPilot", action: #selector(show), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        menu.addItem(.separator())
        for display in engine.displays {
            let header = NSMenuItem(title: display.name, action: nil, keyEquivalent: ""); header.isEnabled = false; menu.addItem(header)
            for desktop in engine.desktops.filter({ $0.displayID == display.id }) {
                let row = NSMenuItem(title: "\(desktop.ordinal + 1)  \(engine.name(desktop))", action: #selector(switchFromMenu(_:)), keyEquivalent: "")
                row.representedObject = desktop.id; row.target = self; row.state = desktop.active ? .on : .off; menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        let paused = NSMenuItem(title: engine.state.enabled ? "Pause automation" : "Enable automation", action: #selector(pause), keyEquivalent: ""); paused.target = self; menu.addItem(paused)
        let exit = NSMenuItem(title: "Quit DeskPilot", action: #selector(quit), keyEquivalent: "q"); exit.target = self; menu.addItem(exit)
        item.menu = menu
    }

    func hotkey(_ id: UInt32) {
        if id == 1 { toggle(); return }
        if id == 2 { engine.toggleEnabled(); return }
        if id == 3 || id == 4 {
            if let window = engine.system.focusedWindowID() { engine.tile(windowID: window, side: id == 3 ? "left" : "right") }
            return
        }
        let regular = engine.displays.flatMap { display in engine.desktops.filter { $0.displayID == display.id && !$0.fullScreen } }
        if id >= 10 && id <= 18, Int(id - 10) < regular.count { engine.switchTo(regular[Int(id - 10)]) }
        if id >= 30 && id <= 38, Int(id - 30) < regular.count, let window = engine.system.focusedWindowID() { engine.assign(window, to: regular[Int(id - 30)]) }
    }
}

@main struct DeskPilotMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            let access = SystemAccess()
            let screens = access.screens()
            let desktops = access.spaces(displays: screens)
            let report: [String: Any] = ["macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                                       "accessibility": access.trusted, "moveSymbolsAvailable": access.canMove,
                                       "displays": screens.count, "spaces": desktops?.count ?? 0,
                                       "readOnly": true, "moveTested": false]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--verify-move") {
            app.setActivationPolicy(.accessory)
            let check = IntegrationCheck()
            DispatchQueue.main.async { check.start() }
            app.run()
            withExtendedLifetime(check) {}
            return
        }
        let args = CommandLine.arguments
        let directory: URL
        if let index = args.firstIndex(of: "--data-dir"), index + 1 < args.count { directory = URL(fileURLWithPath: args[index + 1], isDirectory: true).standardizedFileURL }
        else { directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeskPilot Native", isDirectory: true) }
        let instance: AppInstance
        do { instance = try AppInstance(directory: directory) }
        catch { fputs("DeskPilot: \(error.localizedDescription)\n", stderr); return }
        guard instance.acquire() else {
            DistributedNotificationCenter.default().postNotificationName(.init("pl.deskpilot.native.show"), object: directory.path, userInfo: nil, deliverImmediately: true)
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
        withExtendedLifetime(instance) {}
    }
}
