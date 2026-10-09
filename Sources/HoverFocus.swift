import AppKit

// Mouse-driven and throttled: no repeating idle timer or screen capture.
@MainActor final class HoverFocus {
    var suspended = false
    private weak var engine: Engine?
    private var monitor: Any?
    private var pending: DispatchWorkItem?
    private var lastMovement = 0.0

    init(engine: Engine) { self.engine = engine }

    func update() {
        guard let engine, engine.trusted, engine.state.focusFollowsMouse ?? true else { stop(); return }
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.moved() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; pending?.cancel(); pending = nil
    }

    private func moved() {
        guard !suspended, let engine, !engine.busy, !engine.locked, !(NSApp.isActive && NSApp.keyWindow?.isVisible == true),
              NSEvent.pressedMouseButtons == 0,
              NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            pending?.cancel(); pending = nil; return
        }
        lastMovement = ProcessInfo.processInfo.systemUptime
        if pending == nil { schedule(after: 0.2) }
    }

    private func schedule(after delay: TimeInterval) {
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            guard !self.suspended else { return }
            let quiet = ProcessInfo.processInfo.systemUptime - self.lastMovement
            if quiet < 0.2 { self.schedule(after: 0.2 - quiet); return }
            guard let engine = self.engine, let access = engine.system as? SystemAccess,
                  NSEvent.pressedMouseButtons == 0,
                  NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !(NSApp.isActive && NSApp.keyWindow?.isVisible == true), let id = access.windowAtPointer() else { return }
            engine.focusHoveredWindow(id)
        }
        pending = job
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }
}
