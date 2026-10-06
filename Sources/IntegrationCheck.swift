import AppKit

// A bounded integration check moves only a window created by this process.
// It never moves a user's existing window and always attempts to restore origin.
@MainActor final class IntegrationCheck {
    private var window: NSWindow?
    private var keeper: Task<Void, Never>?
    func start() {
        keeper = Task {
            guard AXIsProcessTrusted() else { finish(["ok": false, "reason": "accessibility_required", "moveTested": false]); return }
            let access = SystemAccess()
            let displays = access.screens()
            guard let spaces = access.spaces(displays: displays) else { finish(["ok": false, "reason": "spaces_unavailable"]); return }
            let test = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 400, height: 170), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            test.isReleasedWhenClosed = false
            test.title = "DeskPilot — test window"
            let label = NSTextField(labelWithString: "Testing this window’s move and return.\nYour existing windows stay in place.")
            label.frame = NSRect(x: 24, y: 45, width: 350, height: 75)
            test.contentView?.addSubview(label)
            window = test
            test.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 350_000_000)
            let id = UInt32(test.windowNumber)
            guard let locations = DPWindowSpaces(id) as? [NSNumber], locations.count == 1,
                  let source = spaces.first(where: { $0.systemID == locations[0].uint64Value && !$0.fullScreen }),
                  let target = spaces.first(where: { !$0.fullScreen && $0.displayID == source.displayID && $0.systemID != source.systemID }) else {
                finish(["ok": false, "reason": "requires_two_regular_spaces", "moveTested": false]); return
            }
            let moved = await move(id, to: target.systemID)
            let restored = await move(id, to: source.systemID)
            finish(["ok": moved && restored, "outboundConfirmed": moved, "returnConfirmed": restored, "moveTested": true, "onlyOwnTestWindow": true])
        }
    }
    private func move(_ window: UInt32, to space: UInt64) async -> Bool {
        if let current = DPWindowSpaces(window) as? [NSNumber], current.count == 1, current[0].uint64Value == space { return true }
        guard DPBeginMove(window, space) == nil else { return false }
        defer { DPEndMove() }
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 125_000_000)
            if let current = DPWindowSpaces(window) as? [NSNumber], current.count == 1, current[0].uint64Value == space { return true }
        }
        return false
    }
    private func finish(_ result: [String: Any]) {
        window?.close()
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let output = String(data: data, encoding: .utf8) { print(output) }
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
