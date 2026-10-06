import AppKit

// Exercise the actual routing engine against a deterministic desktop service.
// No running applications, browser windows or user settings are accessed.
final class TestSystem: SystemAccessProtocol {
    var onEvent: ((String, Int32?, UInt32?) -> Void)?
    var trusted = true
    var canMove = true
    var lastReadMilliseconds = 0.0
    var display = Display(id: "screen", systemID: 1, name: "Test display", builtIn: true,
                          frame: CGRect(x: 0, y: 0, width: 1400, height: 900), visibleFrame: CGRect(x: 0, y: 30, width: 1400, height: 870))
    var desktops = [Desktop(id: "home", systemID: 1, displayID: "screen", ordinal: 0, fullScreen: false, active: true),
                    Desktop(id: "existing-empty", systemID: 2, displayID: "screen", ordinal: 1, fullScreen: false, active: false)]
    var windows: [WindowInfo] = []
    var serverWindows = Set<WindowIdentity>()
    var creates = 0
    var moves = 0
    var failMove = false
    var failCreation = false
    var failedSpaceReads = 0
    var onBeginMove: (() -> Void)?
    func start() {}
    func screens() -> [Display] { [display] }
    func spaces(displays: [Display]) -> [Desktop]? {
        if failedSpaceReads > 0 { failedSpaceReads -= 1; return nil }
        return desktops
    }
    func readWindows(dirty: Set<Int32>?) -> [WindowInfo] { windows }
    func windowIdentities() -> Set<WindowIdentity>? { serverWindows.union(windows.map(\.identity)) }
    func focusedWindowID() -> UInt32? { windows.first?.id }
    func missionControlRoot() -> AXUIElement? { nil }
    @MainActor func missionControl(display: Display, select: Desktop?, create: Bool) async throws {
        if create {
            if failCreation { throw AppError.message("Simulated desktop creation failure") }
            creates += 1
            desktops.append(Desktop(id: "created-\(creates)", systemID: UInt64(100 + creates), displayID: display.id, ordinal: desktops.count, fullScreen: false, active: false))
        }
    }
    func setFrame(_ rect: CGRect, windowID: UInt32) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return false }
        windows[index].frame = rect; return true
    }
    func beginMove(_ windowID: UInt32, to spaceID: UInt64) -> String? {
        if failMove { return "Simulated move failure" }
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return "Missing test window" }
        moves += 1; windows[index].spaceIDs = [spaceID]
        onBeginMove?()
        return nil
    }
    func windowSpaces(_ windowID: UInt32) -> [UInt64]? { windows.first { $0.id == windowID }?.spaceIDs }
    func endMove() {}
}

@main struct EngineTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskPilotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("ChromeProfiles.json")
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Work"},"Profile 1":{"name":"Home"}}}}"#.utf8).write(to: chrome)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            checks += 1; precondition(value(), "FAILED: \(name)")
        }
        func make(_ system: TestSystem) -> Engine {
            let engine = Engine(dataURL: root.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json"), system: system, chromeProfilesURL: chrome)
            engine.state.enabled = true; engine.state.automaticProfiles = false
            engine.refresh(full: true)
            return engine
        }
        func window(_ id: UInt32, app: String = "editor", title: String = "Document", space: UInt64 = 1) -> WindowInfo {
            WindowInfo(id: id, pid: 42, appID: app, appName: app == "editor" ? "Editor" : "Google Chrome", title: title,
                       frame: CGRect(x: 100, y: 100, width: 800, height: 600), spaceIDs: [space], minimized: false)
        }
        func settle(_ engine: Engine, until condition: () -> Bool) async {
            for _ in 0..<60 {
                if condition() && !engine.busy { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        let basic = TestSystem(); basic.windows = [window(1), window(2)]
        let engine = make(basic)
        await engine.routeNew(engine.windows)
        check(basic.creates == 1, "An unassigned app gets one NEW desktop despite an existing empty desktop")
        check(basic.windows.allSatisfy { $0.spaceIDs == [101] }, "All windows of the app move together")
        check(engine.state.assignments.count == 1 && engine.name(basic.desktops.last!) == "Editor", "Confirmed app assignment supplies its desktop name")
        basic.windows.append(window(3)); engine.refresh(full: true)
        await engine.routeNew(engine.windows)
        check(basic.creates == 1 && basic.windows.last?.spaceIDs == [101], "A subsequent window reuses the assigned desktop")
        engine.rename(basic.desktops.last!, to: "Writing")
        check(engine.name(basic.desktops.last!) == "Writing", "Custom rename is applied")
        engine.rename(basic.desktops.last!, to: "")
        check(engine.name(basic.desktops.last!) == "Editor", "Clearing a rename restores the app name")
        engine.state.enabled = false

        let browser = TestSystem()
        browser.windows = [window(10, app: "com.google.Chrome", title: "Page - Google Chrome - Work"), window(11, app: "com.google.Chrome", title: "Other - Google Chrome - Home"), window(12, app: "com.google.Chrome", title: "More - Google Chrome - Work")]
        let profiles = make(browser)
        await profiles.routeNew(profiles.windows)
        check(browser.creates == 2, "Chrome profiles get separate desktops")
        check(browser.windows[0].spaceIDs == browser.windows[2].spaceIDs && browser.windows[0].spaceIDs != browser.windows[1].spaceIDs, "Only the matching Chrome profile moves together")
        check(Set(browser.desktops.dropFirst(2).map { profiles.name($0) }) == ["Work", "Home"], "Chrome desktop names are the exact profile names")
        profiles.state.enabled = false

        let delayed = TestSystem(); let late = make(delayed)
        delayed.serverWindows = [WindowIdentity(pid: 42, windowID: 20)]
        late.event(kAXWindowCreatedNotification, pid: 42, windowID: nil)
        late.refresh(full: true)
        check(delayed.creates == 0, "AX creation without a native ID does not move an arbitrary window")
        delayed.windows = [window(20, app: "com.google.Chrome", title: "Loading")]
        late.refresh(full: true)
        check(delayed.creates == 0, "Unresolved Chrome waits for profile metadata")
        delayed.windows = [window(20, app: "com.google.Chrome", title: "Page - Google Chrome - Work")]
        late.event(kAXTitleChangedNotification, pid: 42, windowID: 20)
        late.refresh(full: true)
        await settle(late) { delayed.creates == 1 && delayed.windows[0].spaceIDs == [101] }
        check(delayed.creates == 1 && delayed.windows[0].spaceIDs == [101], "Late Chrome identity automatically completes the queued route")
        late.state.enabled = false

        let occupied = TestSystem(); let busy = make(occupied)
        busy.busy = true; occupied.windows = [window(30)]
        busy.event(kAXWindowCreatedNotification, pid: 42, windowID: 30)
        busy.refresh(full: true)
        check(occupied.creates == 0, "Busy engine defers routing")
        busy.busy = false; busy.refresh(full: true)
        await settle(busy) { occupied.creates == 1 && occupied.windows[0].spaceIDs == [101] }
        check(occupied.creates == 1 && occupied.windows[0].spaceIDs == [101], "Busy engine retains the queued window")
        busy.state.enabled = false

        let failed = TestSystem(); failed.windows = [window(40)]; failed.failMove = true
        let retry = make(failed)
        await retry.routeNew(retry.windows)
        check(!retry.state.enabled && retry.state.assignments.isEmpty, "Failed move pauses automation without claiming assignment success")
        retry.checkAccessibility()
        check(retry.state.automationPauseReason?.contains("Simulated move failure") == true && retry.status.contains("Simulated move failure"), "Returning to the app keeps the automatic pause reason visible")
        let failureReport = try JSONSerialization.jsonObject(with: Data(contentsOf: retry.dataURL.deletingLastPathComponent().appendingPathComponent("runtime-status.json"))) as! [String: Any]
        check(failureReport["automationEnabled"] as? Bool == false && (failureReport["automationPauseReason"] as? String)?.contains("Simulated move failure") == true, "A failed automatic operation immediately records its paused state and reason")
        let restartedFailure = Engine(dataURL: retry.dataURL, system: TestSystem(), chromeProfilesURL: chrome)
        check(restartedFailure.state.automationPauseReason == retry.state.automationPauseReason, "The reason for pausing automation survives app restart")
        failed.failMove = false; retry.state.enabled = true
        await retry.routeNew(retry.windows)
        check(failed.creates == 1 && failed.windows[0].spaceIDs == [101], "Retry reuses the created desktop instead of making duplicates")
        retry.state.enabled = false

        let refused = TestSystem(); refused.windows = [window(50)]; refused.failCreation = true
        let rejected = make(refused); await rejected.routeNew(rejected.windows)
        check(!rejected.state.enabled && refused.moves == 0, "Desktop creation failure pauses automation and leaves windows alone")

        let manual = TestSystem(); manual.windows = [window(60, app: "com.google.Chrome", title: "Page - Google Chrome - Home")]
        let chosen = make(manual)
        chosen.setChromeProfile(windowID: 60, profile: ChromeProfile(id: "Default", name: "Work"))
        await settle(chosen) { manual.creates == 1 && manual.windows[0].spaceIDs == [101] }
        check(chosen.windows.first?.profileDirectory == "Default" && chosen.state.assignments.first?.profileName == "Work", "Explicit profile selection takes priority and triggers routing")
        chosen.state.enabled = false

        let transient = TestSystem(); let recovering = make(transient)
        transient.windows = [window(70)]; transient.failedSpaceReads = 1
        recovering.event(kAXWindowCreatedNotification, pid: 42, windowID: 70)
        recovering.refresh(full: true)
        check(transient.moves == 0 && transient.creates == 0, "A failed Space snapshot leaves windows untouched")
        await settle(recovering) { transient.creates == 1 && transient.windows[0].spaceIDs == [101] }
        check(transient.creates == 1 && transient.windows[0].spaceIDs == [101], "The pending route recovers from a temporary Space read failure")
        recovering.state.enabled = false

        let burst = TestSystem(); burst.windows = [window(80)]
        let concurrent = make(burst)
        burst.onBeginMove = {
            burst.onBeginMove = nil
            burst.windows.append(window(81))
            concurrent.event(kAXWindowCreatedNotification, pid: 42, windowID: 81)
            concurrent.refresh(full: true)
        }
        await concurrent.routeNew(concurrent.windows)
        await settle(concurrent) { burst.windows.allSatisfy { $0.spaceIDs == [101] } }
        check(burst.creates == 1 && burst.windows.allSatisfy { $0.spaceIDs == [101] }, "A window arriving during a move remains queued and joins the same desktop")
        concurrent.state.enabled = false

        let enabling = TestSystem(); enabling.windows = [window(90)]
        let guarded = make(enabling); guarded.state.enabled = false
        guarded.state.automationPauseReason = "Previous creation failure"
        guarded.schedule(delay: 0.05, full: true)
        guarded.toggleEnabled()
        check(guarded.state.automationPauseReason == nil, "Explicitly enabling automation clears the previous pause reason")
        await settle(guarded) { enabling.windows[0].spaceIDs == [101] }
        check(enabling.creates == 1 && enabling.windows[0].spaceIDs == [101], "An earlier scheduled refresh does not consume the enable-automation retry")
        guarded.state.enabled = false

        let initiallyHidden = TestSystem()
        initiallyHidden.serverWindows = [WindowIdentity(pid: 42, windowID: 95)]
        let revealed = make(initiallyHidden); revealed.state.enabled = false
        revealed.toggleEnabled()
        // WindowServer already knew this window before automation was enabled,
        // but Accessibility only reveals it after visiting its desktop.
        initiallyHidden.windows = [window(95, app: "com.google.Chrome", title: "Page - Google Chrome - Work")]
        revealed.event(NSWorkspace.didActivateApplicationNotification.rawValue, pid: 42, windowID: nil)
        await settle(revealed) { initiallyHidden.windows[0].spaceIDs == [101] }
        check(initiallyHidden.creates == 1 && initiallyHidden.windows[0].spaceIDs == [101], "An existing window first exposed by Accessibility after enabling automation is still routed")
        revealed.state.enabled = false

        let conflicting = TestSystem()
        conflicting.windows = [window(100, app: "com.google.Chrome", title: "Page - Google Chrome - Work")]
        let identity = make(conflicting)
        check(identity.windows[0].profileDirectory == "Default", "Initial explicit Chrome identity is recognized")
        conflicting.windows[0].accessibilityTitles = ["Page - Google Chrome - Home"]
        identity.refresh(full: true)
        check(identity.windows[0].group == nil, "Conflicting explicit identity cannot reuse a cached Chrome profile")
        identity.state.enabled = false

        let manualFailure = TestSystem(); manualFailure.windows = [window(110), window(111)]
        let following = make(manualFailure)
        following.record(following.windows[0], on: manualFailure.desktops[0])
        manualFailure.windows[0].spaceIDs = [2]; manualFailure.failMove = true
        following.refresh(full: true)
        await settle(following) { following.lastError != nil }
        check(following.lastError != nil && following.state.assignments[0].desktopID == "home", "Failed group movement after a manual move preserves the last confirmed assignment")
        following.state.enabled = false

        let noSpaces = TestSystem(); noSpaces.failedSpaceReads = 1
        let catalog = make(noSpaces)
        check(catalog.chromeProfiles.count == 2, "Chrome profile catalog is loaded even when the Space snapshot fails")
        catalog.state.enabled = false
        let unreadable = Engine(dataURL: root.appendingPathComponent("unreadable-state.json"), system: TestSystem(), chromeProfilesURL: root.appendingPathComponent("missing-catalog"))
        unreadable.refresh(full: true)
        check(unreadable.chromeProfiles.isEmpty && unreadable.chromeCatalogStatus.contains("unavailable"), "Missing profile catalog exposes an error instead of silently showing zero profiles")
        check(unreadable.chromeCatalogCountLabel == "Unavailable", "An unreadable catalog is not reported as zero profiles")
        let failedAttempts = unreadable.chromeCatalogReadAttempts
        unreadable.refresh(full: true); unreadable.checkAccessibility()
        check(unreadable.chromeCatalogReadAttempts == failedAttempts, "Background refreshes and activations do not repeatedly read a denied catalog")
        unreadable.checkAccessibility(retryChromeCatalog: true)
        check(unreadable.chromeCatalogReadAttempts == failedAttempts + 1, "Explicit Refresh immediately retries catalog access")
        unreadable.connectChromeProfiles(to: chrome)
        check(unreadable.chromeProfiles.count == 2 && unreadable.state.chromeCatalogBookmark != nil, "Connecting a selected profile catalog loads profiles and saves its bookmark")
        check(unreadable.chromeCatalogAvailable && unreadable.chromeConnectionStatus.contains("successfully") && unreadable.lastError == nil, "Successful connection is visible and clears the previous error")
        let savedBookmark = unreadable.state.chromeCatalogBookmark
        let invalid = root.appendingPathComponent("Preferences")
        try Data(#"{"profile":{"name":"Not the catalog"}}"#.utf8).write(to: invalid)
        unreadable.connectChromeProfiles(to: invalid)
        check(unreadable.state.chromeCatalogBookmark == savedBookmark && unreadable.chromeProfiles.count == 2 && unreadable.chromeConnectionStatus.contains("Could not connect"), "An invalid selection reports failure and preserves the connected catalog")
        let connected = Engine(dataURL: root.appendingPathComponent("unreadable-state.json"), system: TestSystem())
        connected.refresh(full: true)
        check(connected.chromeProfiles.count == 2, "The selected Chrome profile catalog is restored on restart")
        let beforeEvents = connected.events
        connected.event(NSWorkspace.didActivateApplicationNotification.rawValue, pid: getpid(), windowID: nil)
        check(connected.events == beforeEvents, "DeskPilot activation does not trigger another managed-window refresh")

        let cachedFile = root.appendingPathComponent("temporary-catalog")
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Work"}}},"unrelated_secret":"must not persist"}"#.utf8).write(to: cachedFile)
        let cachedState = root.appendingPathComponent("cached-state.json")
        let caching = Engine(dataURL: cachedState, system: TestSystem(), chromeProfilesURL: cachedFile)
        caching.connectChromeProfiles(to: cachedFile)
        try FileManager.default.removeItem(at: cachedFile)
        let cachedSystem = TestSystem()
        cachedSystem.windows = [window(91, app: "com.google.Chrome", title: "Page - Google Chrome"), window(92, app: "com.google.Chrome", title: "Page - Google Chrome - Work")]
        let offline = Engine(dataURL: cachedState, system: cachedSystem)
        offline.refresh(full: true)
        check(offline.chromeProfiles.count == 1 && !offline.chromeCatalogAvailable && offline.chromeCatalogCountLabel == "1 saved", "A later read failure retains a clearly marked saved catalog across restart")
        check(offline.windows[0].group == nil && offline.windows[1].profileDirectory == "Default", "Saved profiles require an explicit window profile suffix rather than a single-profile guess")
        let persisted = try String(contentsOf: cachedState, encoding: .utf8)
        check(!persisted.contains("unrelated_secret") && !persisted.contains("must not persist") && persisted.contains("chromeCatalogProfiles"), "Only profile names and IDs are retained, not the source catalog")
        print("PASS: \(checks) engine checks")
    }
}
