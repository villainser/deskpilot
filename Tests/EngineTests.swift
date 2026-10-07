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
    var focused: UInt32?
    var pointerDisplay: String? = "screen"
    var launchDate = Date(timeIntervalSince1970: 100)
    var extraDisplays: [Display] = []
    var failFrame = false
    var minimizedWrites: [UInt32: Bool] = [:]
    func start() {}
    func screens() -> [Display] { [display] + extraDisplays }
    func spaces(displays: [Display]) -> [Desktop]? {
        if failedSpaceReads > 0 { failedSpaceReads -= 1; return nil }
        return desktops
    }
    func readWindows(dirty: Set<Int32>?) -> [WindowInfo] { windows }
    func windowIdentities() -> Set<WindowIdentity>? { serverWindows.union(windows.map(\.identity)) }
    func focusedWindowID() -> UInt32? { focused ?? windows.first?.id }
    func pointerDisplayID() -> String? { pointerDisplay }
    func processStarted(_ pid: Int32) -> Date? { launchDate }
    func focusWindow(_ windowID: UInt32) -> Bool { focused = windowID; return true }
    func setMinimized(_ minimized: Bool, windowID: UInt32) -> Bool { minimizedWrites[windowID] = minimized; return true }
    func missionControlRoot() -> AXUIElement? { nil }
    @MainActor func missionControl(display: Display, select: Desktop?, create: Bool) async throws {
        if create {
            if failCreation { throw AppError.message("Simulated desktop creation failure") }
            creates += 1
            desktops.append(Desktop(id: "created-\(creates)", systemID: UInt64(100 + creates), displayID: display.id, ordinal: desktops.count, fullScreen: false, active: false))
        }
    }
    func setFrame(_ rect: CGRect, windowID: UInt32) -> Bool {
        if failFrame { return false }
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

        // Summoning moves individual windows without changing the app/profile home.
        let borrowedSystem = TestSystem()
        borrowedSystem.windows = [window(200, space: 2), window(201, space: 2)]
        let loans = make(borrowedSystem); loans.state.enabled = false
        let originalFrame = borrowedSystem.windows[1].frame
        loans.record(loans.windows[0], on: borrowedSystem.desktops[1])
        let originalRules = loans.state.assignments
        loans.event(kAXFocusedWindowChangedNotification, pid: 42, windowID: 201)
        await loans.summonNextWindow(from: "existing-empty", to: "home")
        check(borrowedSystem.windows[0].spaceIDs == [2] && borrowedSystem.windows[1].spaceIDs == [1], "Summon takes one most-recently focused window, leaving its siblings home")
        check(loans.state.assignments == originalRules && loans.state.borrowedWindows?.count == 1, "A temporary move preserves the permanent app assignment and remembers return data")
        check(loans.name(borrowedSystem.desktops[1]) == "Editor", "An emptied home retains its app name while windows are borrowed")
        loans.summon(borrowedSystem.desktops[1])
        await settle(loans) { loans.state.borrowedWindows?.count == 2 }
        check(borrowedSystem.windows.allSatisfy { $0.spaceIDs == [1] }, "The same shortcut takes the next window without returning the previous one")
        await loans.summonNextWindow(from: "existing-empty", to: "home")
        check(loans.lastError?.contains("No more") == true && borrowedSystem.moves == 2, "An exhausted source reports no more windows without changing another window")
        loans.tile(windowID: 201, side: "right")
        loans.refresh(full: true)
        loans.saveProfile(name: "Homes", fallback: false)
        check(loans.state.assignments == originalRules && loans.state.profiles.last?.frames.allSatisfy { $0.frame.rect(in: borrowedSystem.display.visibleFrame) == originalFrame } == true,
              "Saving a layout uses home assignments and pre-summon geometry")
        loans.activeProfileID = nil
        loans.restore(loans.state.profiles.last!)
        await settle(loans) { loans.activeProfileID == loans.state.profiles.last?.id }
        check(borrowedSystem.windows.allSatisfy { $0.spaceIDs == [1] }, "Layout restoration leaves summoned windows in place")
        await loans.returnWindow(201)
        check(borrowedSystem.windows[1].spaceIDs == [2] && borrowedSystem.windows[1].frame == originalFrame && borrowedSystem.windows[0].spaceIDs == [1],
              "Return restores only the selected window's original desktop and geometry")
        check(loans.state.borrowedWindows?.count == 1 && loans.state.assignments == originalRules, "Returning one window retains the other loan and the permanent home")
        await loans.summonNextWindow(from: "existing-empty", to: "home")
        check(loans.state.borrowedWindows?.count == 2, "A returned window can be summoned again")
        let restartedLoans = Engine(dataURL: loans.dataURL, system: borrowedSystem, chromeProfilesURL: chrome)
        restartedLoans.refresh(full: true)
        check(restartedLoans.state.borrowedWindows?.count == 2, "Window return locations survive a DeskPilot restart")
        borrowedSystem.launchDate = Date(timeIntervalSince1970: 200)
        restartedLoans.refresh(full: true)
        check(restartedLoans.state.borrowedWindows?.isEmpty == true, "Process start time rejects recycled process and window identifiers")
        borrowedSystem.launchDate = Date(timeIntervalSince1970: 100)

        // New windows route normally, while a borrowed sibling remains protected.
        let routingSystem = TestSystem(); routingSystem.windows = [window(210, space: 2)]
        let routingLoans = make(routingSystem); routingLoans.state.enabled = false
        routingLoans.record(routingLoans.windows[0], on: routingSystem.desktops[1])
        await routingLoans.summonNextWindow(from: "existing-empty", to: "home")
        routingSystem.windows.append(window(211))
        routingLoans.busy = true; routingLoans.refresh(full: true); routingLoans.busy = false
        routingLoans.state.enabled = true
        await routingLoans.routeNew(routingLoans.windows)
        check(routingSystem.windows[0].spaceIDs == [1] && routingSystem.windows[1].spaceIDs == [2] && routingSystem.creates == 0,
              "Automatic routing excludes the summoned window but sends new siblings home")
        routingLoans.state.enabled = false
        // Let the manual-movement grace expire, then move the borrowed window manually.
        try await Task.sleep(nanoseconds: 2_100_000_000)
        routingSystem.desktops.append(Desktop(id: "third", systemID: 3, displayID: "screen", ordinal: 2, fullScreen: false, active: false))
        routingSystem.windows[0].spaceIDs = [3]
        routingLoans.state.enabled = true; routingLoans.refresh(full: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        check(routingLoans.state.assignments.first?.desktopID == "existing-empty" && routingSystem.windows[1].spaceIDs == [2],
              "A manual move of a borrowed window does not reassign or pull its siblings")
        routingLoans.state.enabled = false
        routingLoans.assign(210, to: routingSystem.desktops[0])
        await settle(routingLoans) { routingLoans.state.assignments.first?.desktopID == "home" }
        check(routingLoans.state.borrowedWindows?.isEmpty == true && routingSystem.windows.allSatisfy { $0.spaceIDs == [1] },
              "Explicit permanent assignment moves the whole group and clears temporary return data")

        let chromeLoansSystem = TestSystem()
        chromeLoansSystem.windows = [window(220, app: "com.google.Chrome", title: "A - Google Chrome - Work", space: 2),
                                     window(221, app: "com.google.Chrome", title: "B - Google Chrome - Home", space: 2),
                                     window(222, app: "com.google.Chrome", title: "Unknown - Google Chrome - Guest", space: 2)]
        let chromeLoans = make(chromeLoansSystem); chromeLoans.state.enabled = false
        chromeLoans.summon(chromeLoansSystem.desktops[1]); chromeLoans.summon(chromeLoansSystem.desktops[1])
        await settle(chromeLoans) { chromeLoans.state.borrowedWindows?.count == 2 }
        check(Set((chromeLoans.state.borrowedWindows ?? []).map(\.group)) == ["com.google.Chrome::Default", "com.google.Chrome::Profile 1"] && chromeLoansSystem.windows[2].spaceIDs == [2],
              "Rapid presses queue separate recognized Chrome windows and skip unknown profiles")
        await chromeLoans.returnWindow(220)
        check(chromeLoansSystem.windows[0].spaceIDs == [2] && chromeLoansSystem.windows[1].spaceIDs == [1], "One Chrome profile window returns without moving another profile")

        let failingLoanSystem = TestSystem(); failingLoanSystem.windows = [window(230, space: 2)]
        let failingLoan = make(failingLoanSystem); failingLoan.state.enabled = false
        failingLoanSystem.failMove = true
        await failingLoan.summonNextWindow(from: "existing-empty", to: "home")
        check((failingLoan.state.borrowedWindows ?? []).isEmpty && failingLoanSystem.windows[0].spaceIDs == [2], "A refused summon removes its unused return record")
        failingLoanSystem.failMove = false
        await failingLoan.summonNextWindow(from: "existing-empty", to: "home")
        failingLoanSystem.failMove = true
        await failingLoan.returnWindow(230)
        check(failingLoan.state.borrowedWindows?.count == 1 && failingLoanSystem.windows[0].spaceIDs == [1], "Failed return preserves the return record for retry")
        failingLoanSystem.failMove = false; failingLoanSystem.failFrame = true
        await failingLoan.returnWindow(230)
        check(failingLoan.state.borrowedWindows?.count == 1 && failingLoanSystem.windows[0].spaceIDs == [2], "A geometry failure after returning home remains retryable")
        failingLoanSystem.failFrame = false
        await failingLoan.returnWindow(230)
        check(failingLoan.state.borrowedWindows?.isEmpty == true, "Retry clears a return record only after geometry succeeds")
        await failingLoan.summonNextWindow(from: "existing-empty", to: "home")
        failingLoanSystem.desktops[1] = Desktop(id: "replacement", systemID: 9, displayID: "screen", ordinal: 1, fullScreen: false, active: false)
        await failingLoan.returnWindow(230)
        check(failingLoan.state.borrowedWindows?.count == 1 && failingLoanSystem.windows[0].spaceIDs == [1] && failingLoan.lastError?.contains("unavailable") == true,
              "A deleted home never falls back to another desktop at the same position")
        failingLoanSystem.windows.removeAll(); failingLoan.refresh(full: true)
        check(failingLoan.state.borrowedWindows?.isEmpty == true, "Closing a summoned window removes its stale return record")

        let multiSystem = TestSystem()
        let external = Display(id: "external", systemID: 2, name: "External", builtIn: false,
                               frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: -170, width: 1920, height: 1050))
        multiSystem.extraDisplays = [external]
        multiSystem.desktops.append(Desktop(id: "external-home", systemID: 3, displayID: "external", ordinal: 0, fullScreen: false, active: true))
        multiSystem.windows = [window(240, space: 3), window(241, app: "other")]
        multiSystem.windows[0].frame = CGRect(x: -1800, y: -100, width: 900, height: 700)
        multiSystem.focused = 241
        let multiLoans = make(multiSystem); multiLoans.state.enabled = false
        check(multiLoans.number(multiSystem.desktops[2]) == "3", "Shortcut numbers are unique across displays")
        multiLoans.summon(multiSystem.desktops[2])
        await settle(multiLoans) { multiLoans.state.borrowedWindows?.count == 1 }
        check(multiSystem.windows[0].spaceIDs == [1] && multiSystem.display.visibleFrame.contains(multiSystem.windows[0].frame),
              "Summon targets the focused display and fits the window to its visible area")
        // The same Space can move to another monitor; identity still wins.
        multiSystem.desktops[2] = Desktop(id: "external-home", systemID: 3, displayID: "screen", ordinal: 2, fullScreen: false, active: false)
        await multiLoans.returnWindow(240)
        check(multiSystem.windows[0].spaceIDs == [3] && multiSystem.display.visibleFrame.contains(multiSystem.windows[0].frame),
              "Return follows the home Space identity after it moves between monitors")
        multiSystem.desktops[0] = Desktop(id: "home", systemID: 1, displayID: "screen", ordinal: 0, fullScreen: true, active: true)
        multiSystem.focused = 241
        multiLoans.summon(multiSystem.desktops[2])
        check(multiLoans.lastError?.contains("full screen") == true && multiLoans.state.borrowedWindows?.isEmpty == true, "Fullscreen destinations refuse summon before any move")


        let staleSystem = TestSystem(); staleSystem.windows = [window(250, space: 2)]
        let staleLoan = make(staleSystem); staleLoan.state.enabled = false
        staleSystem.failedSpaceReads = 1
        await staleLoan.summonNextWindow(from: "existing-empty", to: "home")
        check(staleSystem.moves == 0 && (staleLoan.state.borrowedWindows ?? []).isEmpty, "Failed fresh desktop discovery never uses a stale cached destination")
        staleSystem.onBeginMove = {
            staleSystem.desktops[0] = Desktop(id: "home", systemID: 1, displayID: "screen", ordinal: 0, fullScreen: false, active: false)
            staleSystem.desktops[1] = Desktop(id: "existing-empty", systemID: 2, displayID: "screen", ordinal: 1, fullScreen: false, active: true)
        }
        await staleLoan.summonNextWindow(from: "existing-empty", to: "home")
        check(staleLoan.state.borrowedWindows?.count == 1 && staleSystem.focused == nil && staleLoan.lastError?.contains("no longer active") == true,
              "A destination switched during movement is not activated again by focusing the app")

        let unwritableSystem = TestSystem(); unwritableSystem.windows = [window(260, space: 2)]
        let obstruction = root.appendingPathComponent("not-a-directory")
        try Data("test".utf8).write(to: obstruction)
        let unsavedLoan = Engine(dataURL: obstruction.appendingPathComponent("state.json"), system: unwritableSystem, chromeProfilesURL: chrome)
        unsavedLoan.refresh(full: true)
        await unsavedLoan.summonNextWindow(from: "existing-empty", to: "home")
        check(unwritableSystem.moves == 0 && (unsavedLoan.state.borrowedWindows ?? []).isEmpty, "An unsavable return location prevents the move")

        let minimizedSystem = TestSystem()
        let standard = window(270, space: 2)
        minimizedSystem.windows = [WindowInfo(id: standard.id, pid: standard.pid, appID: standard.appID, appName: standard.appName,
                                              title: standard.title, frame: standard.frame, spaceIDs: standard.spaceIDs, minimized: true)]
        let minimizedLoan = make(minimizedSystem); minimizedLoan.state.enabled = false
        await minimizedLoan.summonNextWindow(from: "existing-empty", to: "home")
        check(minimizedSystem.minimizedWrites[270] == false && minimizedSystem.focused == 270, "Summon unminimizes and focuses the chosen window")
        await minimizedLoan.returnWindow(270)
        check(minimizedSystem.minimizedWrites[270] == true && minimizedLoan.state.borrowedWindows?.isEmpty == true, "Return restores the original minimized state")

        print("PASS: \(checks) engine checks")
    }
}
