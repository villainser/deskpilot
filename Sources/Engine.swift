import AppKit
import SwiftUI
import CryptoKit
import ServiceManagement

@MainActor final class Engine: ObservableObject {
    @Published var state = AppState()
    @Published var displays: [Display] = []
    @Published var desktops: [Desktop] = []
    @Published var windows: [WindowInfo] = []
    @Published var chromeProfiles: [ChromeProfile] = []
    @Published var chromeCatalogStatus = "Not read yet"
    @Published var chromeCatalogAvailable = false
    @Published var chromeConnectionStatus = "Not connected with the file picker"
    @Published var choosingChromeCatalog = false
    private var chromePicker: NSOpenPanel?
    private var chromeRetryAfter = Date.distantPast
    private var chromeCatalogLocationUnavailable = false
    private(set) var chromeCatalogReadAttempts = 0
    @Published var status = "Ready to set up"
    @Published var trusted = false
    @Published var busy = false
    @Published var locked = false
    @Published var events = 0
    private var eventCounts: [String: Int] = [:]
    @Published var refreshes = 0
    @Published var lastReadMilliseconds = 0.0
    @Published var activeProfileID: String?
    @Published var lastError: String?
    var onChange: (() -> Void)?
    let system: SystemAccessProtocol
    let dataURL: URL
    private var chromeProfilesURL: URL
    var rememberedWindow: UInt32?
    private var pending: DispatchWorkItem?
    private var scheduledFor: Date?
    private var dirty = Set<Int32>()
    private var fullRead = false
    private var routingInbox = RoutingInbox()
    private var knownServerWindows: Set<WindowIdentity>?
    private var launching: [Int32: Date] = [:]
    private var previous: [UInt32: (Int32, UInt64)] = [:]
    private var chromeBindings: [String: ChromeProfile] = [:]
    private var manualChromeBindings: [String: String] = [:]
    private var chromeModified: Date?
    private var guardUntil = Date.distantPast
    private var generation = 0
    private var topologyTask: Task<Void, Never>?
    private var hasBaseline = false
    private var restoring = false
    private var temporaryTargets: [String: String] = [:]
    private var operational = true
    private var oldDisplaySignature = ""
    private var displayGeometry = ""
    private var operationGeneration: Int?
    private var lastOwnMovement = Date.distantPast
    private var lastRuntimeSnapshot: Data?
    private var waitingForMissionControl = false
    private var spaceSnapshotAvailable = false
    private var focusOrder: [WindowIdentity: Int] = [:]
    private var summonOrder: [WindowIdentity: Int] = [:]
    private var interactionSerial = 0
    private enum WindowCommand {
        case summon(source: String, destination: String)
        case sendBack(UInt32)
    }
    private var windowCommands: [WindowCommand] = []
    private var commandTask: Task<Void, Never>?

    init(dataURL: URL? = nil, system: SystemAccessProtocol = SystemAccess(), chromeProfilesURL: URL? = nil) {
        self.system = system
        self.chromeProfilesURL = chromeProfilesURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        self.dataURL = dataURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskPilot Native", isDirectory: true).appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: self.dataURL) {
            do {
                let loaded = try JSONDecoder().decode(AppState.self, from: data)
                guard loaded.schema == 1 else { throw AppError.message("Unsupported settings version.") }
                state = loaded
                self.chromeProfiles = loaded.chromeCatalogProfiles ?? []
            } catch {
                operational = false
                lastError = "Unable to load settings. The original file was preserved: \(error.localizedDescription)"
            }
        }
        if chromeProfilesURL == nil, let bookmark = state.chromeCatalogBookmark {
            chromeConnectionStatus = "Restoring saved file access"
            var stale = false
            let selected = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale))
            if let selected {
                self.chromeProfilesURL = selected
                chromeConnectionStatus = "Saved file selected; checking access"
            } else {
                chromeCatalogLocationUnavailable = true
                chromeCatalogStatus = "Reconnect Chrome profiles: the saved file permission could not be restored."
            }
        }
    }

    func start() {
        system.onEvent = { [weak self] name, pid, id in
            Task { @MainActor in self?.event(name, pid: pid, windowID: id) }
        }
        system.start()
        refresh(full: true)
        if state.enabled { enqueueOpenWindows() }
        guardUntil = Date().addingTimeInterval(3)
        if state.enabled && state.automaticProfiles { handleTopology() }
        else { schedule(delay: 3.1) }
        status = automationStatus
    }

    func event(_ name: String, pid: Int32?, windowID: UInt32?) {
        // Showing or updating our own panel does not change managed windows.
        if pid == getpid() { return }
        if name == kAXFocusedWindowChangedNotification || name == NSWorkspace.didActivateApplicationNotification.rawValue,
           let id = windowID ?? system.focusedWindowID(), let window = windows.first(where: { $0.id == id }) {
            interactionSerial += 1; focusOrder[window.identity] = interactionSerial
        }
        events += 1
        eventCounts[name, default: 0] += 1
        if name == "com.apple.screenIsLocked" || name == NSWorkspace.sessionDidResignActiveNotification.rawValue {
            locked = true; generation += 1; routingInbox.clear(); launching.removeAll(); pending?.cancel()
            topologyTask?.cancel(); status = "Mac is locked"; return
        }
        if name == "com.apple.screenIsUnlocked" || name == NSWorkspace.sessionDidBecomeActiveNotification.rawValue || name == NSWorkspace.didWakeNotification.rawValue {
            locked = false; handleTopology(); return
        }
        guard !locked else { return }
        if name == "displays" {
            let current = geometrySignature(system.screens())
            guard current != displayGeometry else { return }
            displayGeometry = current
            handleTopology(); return
        }
        if state.enabled && !restoring {
            if name == kAXWindowCreatedNotification, let pid {
                if let windowID { routingInbox.enqueue(WindowIdentity(pid: pid, windowID: windowID)) }
                // The native window ID may not exist yet when AX announces it.
                launching[pid] = Date()
            }
            if name == NSWorkspace.didLaunchApplicationNotification.rawValue, let pid { launching[pid] = Date() }
        }
        if name == kAXUIElementDestroyedNotification, let pid, let windowID {
            chromeBindings["\(pid):\(windowID)"] = nil
            manualChromeBindings["\(pid):\(windowID)"] = nil
            let identity = WindowIdentity(pid: pid, windowID: windowID)
            routingInbox.remove(identity)
            if state.borrowedWindows?.contains(where: { $0.id == identity }) == true {
                state.borrowedWindows?.removeAll { $0.id == identity }; save()
            }
            focusOrder[identity] = nil; summonOrder[identity] = nil
        }
        if let pid { dirty.insert(pid) }
        if name == NSWorkspace.activeSpaceDidChangeNotification.rawValue { fullRead = true }
        if name == kAXMovedNotification || name == kAXResizedNotification { schedule(delay: 0.8) }
        else { schedule(delay: 0.35) }
    }

    func schedule(delay: TimeInterval = 0.35, full: Bool = false) {
        fullRead = fullRead || full
        let requested = Date().addingTimeInterval(delay)
        // A stream of window events must not postpone an already scheduled read.
        if let scheduledFor, scheduledFor <= requested, pending?.isCancelled == false { return }
        pending?.cancel()
        scheduledFor = requested
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.scheduledFor = nil
            let full = self.fullRead; self.fullRead = false
            self.refresh(full: full)
        }
        pending = job
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }

    func refresh(full: Bool = false) {
        spaceSnapshotAvailable = false
        guard !locked else { return }
        defer { writeRuntimeStatus(onlyIfChanged: true) }
        waitingForMissionControl = false
        let previousTrust = trusted
        trusted = system.trusted
        if previousTrust != trusted { writeRuntimeStatus() }
        displays = system.screens()
        displayGeometry = geometrySignature(displays)
        // Profile discovery must not depend on a successful Space snapshot.
        loadChromeProfiles()
        guard let spaces = system.spaces(displays: displays) else {
            lastError = "Unable to read desktops. No windows will be moved."
            if state.enabled && (routingInbox.needsRetry() || launching.values.contains(where: { Date().timeIntervalSince($0) < 8 })) {
                schedule(delay: 1, full: true)
            }
            return
        }
        desktops = spaces
        spaceSnapshotAvailable = true
        let currentSignature = displays.map(\.id).sorted().joined(separator: "|")
        if !oldDisplaySignature.isEmpty && oldDisplaySignature != currentSignature {
            oldDisplaySignature = currentSignature
            handleTopology(); return
        }
        oldDisplaySignature = currentSignature
        let changed = dirty; dirty.removeAll()
        let raw = system.readWindows(dirty: full || !hasBaseline ? nil : changed)
        let liveServerWindows = system.windowIdentities()
        if let serverWindows = liveServerWindows {
            if let before = knownServerWindows, state.enabled && !restoring {
                for identity in serverWindows.subtracting(before) { routingInbox.enqueue(identity) }
            }
            knownServerWindows = serverWindows
            routingInbox.reconcile(live: serverWindows)
        }
        let previouslyRead = Set(windows.map(\.identity))
        windows = raw.map { item in
            var item = item
            if item.appID == "com.google.Chrome" {
                let key = "\(item.pid):\(item.id)"
                let manual = manualChromeBindings[key].flatMap { id in chromeProfiles.first { $0.id == id } }
                let cached = chromeBindings[key].flatMap { old in chromeProfiles.first { $0.id == old.id } }
                let titles = [item.title] + item.accessibilityTitles
                let explicitIdentity = titles.contains(where: ChromeResolver.hasIdentitySuffix)
                // A saved catalog may be out of date. Require an explicit
                // profile suffix before matching against it; never assume the
                // only saved profile is still Chrome's only profile.
                let resolved = chromeCatalogAvailable || explicitIdentity ? ChromeResolver.resolve(titles: titles, profiles: chromeProfiles) : nil
                let profile = manual ?? resolved ?? (explicitIdentity ? nil : cached)
                if explicitIdentity && profile == nil { chromeBindings[key] = nil }
                if let profile { chromeBindings[key] = profile; item.group = item.appID + "::" + profile.id; item.profileName = profile.name; item.profileDirectory = profile.id }
            } else { item.group = item.appID }
            return item
        }
        // WindowServer may have listed an existing window before Accessibility
        // exposes it (for example on an unvisited desktop). Its native ID is
        // not new, but its first usable AX record still needs automatic routing.
        if hasBaseline && state.enabled && !restoring {
            for window in windows where !previouslyRead.contains(window.identity) {
                routingInbox.enqueue(window.identity)
            }
        }
        let live = Set(windows.filter { $0.appID == "com.google.Chrome" }.map { "\($0.pid):\($0.id)" })
        chromeBindings = chromeBindings.filter { live.contains($0.key) }
        manualChromeBindings = manualChromeBindings.filter { live.contains($0.key) }
        if trusted && !busy { reconcileBorrowedWindows(live: liveServerWindows) }
        refreshes += 1; lastReadMilliseconds = system.lastReadMilliseconds
        if hasBaseline && state.enabled && !busy && !restoring {
            for window in windows {
                guard borrowed(window) == nil, let key = window.group, window.spaceIDs.count == 1,
                      let rule = state.assignments.first(where: { $0.id == key }),
                      let home = desktops.first(where: { $0.id == (temporaryTargets[key] ?? rule.desktopID) && !$0.fullScreen }),
                      window.spaceIDs != [home.systemID] else { continue }
                // Movement is not consent to change an app's permanent home.
                // Explicit assignment and temporary summon have their own paths.
                routingInbox.enqueue(window.identity)
            }
        }
        previous = Dictionary(uniqueKeysWithValues: windows.compactMap { w in w.spaceIDs.count == 1 ? (w.id, (w.pid, w.spaceIDs[0])) : nil })
        let new = hasBaseline ? routingInbox.candidates(in: windows).filter { borrowed($0) == nil } : []
        hasBaseline = true
        onChange?()
        guard trusted && operational && state.enabled && !busy && !restoring else { return }
        guard Date() > guardUntil else {
            if !routingInbox.isEmpty || !launching.isEmpty { schedule(delay: max(0.1, guardUntil.timeIntervalSinceNow + 0.1), full: true) }
            return
        }
        guard system.missionControlRoot() == nil else {
            waitingForMissionControl = true
            if routingInbox.needsRetry() { schedule(delay: 0.5, full: true) }
            return
        }
        // Poll only during a bounded startup interval. Unresolved live windows
        // stay queued and can complete after a later title/profile event.
        let deadline = Date().addingTimeInterval(-8)
        launching = launching.filter { $0.value > deadline }
        if routingInbox.needsRetry() || !launching.isEmpty { schedule(delay: 1, full: true) }
        if !new.isEmpty {
            Task { await routeNew(new) }
        }
    }

    private func geometrySignature(_ values: [Display]) -> String {
        values.map { "\($0.id):\($0.frame)" }.sorted().joined(separator: "|")
    }

    private func checkpoint() throws {
        guard !locked, operationGeneration == generation else { throw CancellationError() }
    }

    func name(_ desktop: Desktop) -> String {
        let homeWindows = windows.map { window -> WindowInfo in
            guard let loan = borrowed(window) else { return window }
            var home = window
            home.spaceIDs = desktops.first { $0.id == loan.homeDesktopID }.map { [$0.systemID] } ?? []
            return home
        }
        return DesktopNaming.name(for: desktop, customNames: state.names, assignments: state.assignments, windows: homeWindows)
    }

    @discardableResult func save() -> Bool {
        guard operational else { return false }
        do {
            try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: dataURL, options: .atomic)
        } catch { fail(error); return false }
        onChange?()
        return true
    }

    func fail(_ error: Error) { lastError = error.localizedDescription; status = error.localizedDescription }

    private var automationStatus: String {
        if !trusted { return "Grant window management access" }
        if state.enabled { return "Automation enabled" }
        return state.automationPauseReason.map { "Automation paused: \($0)" } ?? "Automation paused"
    }

    private func pauseAutomation(after error: Error) {
        state.enabled = false
        state.automationPauseReason = error.localizedDescription
        save()
    }

    func toggleEnabled() {
        guard operational else { return }
        // Permission may have changed in System Settings since the last scan.
        trusted = system.trusted
        writeRuntimeStatus()
        if !state.enabled && !trusted { requestAccessibility(); return }
        state.enabled.toggle(); generation += 1; routingInbox.clear(); launching.removeAll()
        state.automationPauseReason = nil
        if !state.enabled { topologyTask?.cancel() }
        guardUntil = Date().addingTimeInterval(1)
        refresh(full: true)
        if state.enabled { enqueueOpenWindows() }
        schedule(delay: 1.1, full: true)
        status = state.enabled ? "Automation enabled" : "Automation paused"
        save()
        writeRuntimeStatus()
    }

    func requestAccessibility() {
        checkAccessibility()
        if trusted { status = "Window management access is granted"; return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    var permissionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    func checkAccessibility(retryChromeCatalog: Bool = false) {
        if retryChromeCatalog { loadChromeProfiles(force: true) }
        refresh(full: true)
        if !busy {
            status = trusted ? automationStatus : "Access is not granted to this copy of DeskPilot"
        }
        writeRuntimeStatus()
    }

    func writeRuntimeStatus(onlyIfChanged: Bool = false) {
        let report: [String: Any] = ["pid": getpid(), "applicationPath": Bundle.main.bundleURL.path,
                                   "accessibility": trusted, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                                   "windowDiscovery": system.windowDiscovery,
                                   "busy": busy,
                                   "chromeProfiles": chromeProfiles.count,
                                   "chromeWindows": windows.filter { $0.appID == "com.google.Chrome" }.count,
                                   "recognizedChromeWindows": windows.filter { $0.appID == "com.google.Chrome" && $0.group != nil }.count,
                                   "chromeCatalogStatus": chromeCatalogStatus,
                                   "chromeCatalogAvailable": chromeCatalogAvailable,
                                   "chromeConnectionStatus": chromeConnectionStatus,
                                   "choosingChromeCatalog": choosingChromeCatalog,
                                   "chromeCatalogReadAttempts": chromeCatalogReadAttempts,
                                   "chromeCatalogPath": chromeProfilesURL.path,
                                   "desktops": desktops.count, "displays": displays.count, "windows": windows.count,
                                   "reads": refreshes, "locked": locked, "status": status,
                                   "automationEnabled": state.enabled,
                                   "automationPauseReason": state.automationPauseReason ?? "",
                                   "missionControlHost": system.missionControlHost ?? "Not detected yet",
                                   "pendingWindows": routingInbox.pending.count,
                                   "borrowedWindows": state.borrowedWindows?.count ?? 0,
                                   "readyToRouteWindows": routingInbox.candidates(in: windows).filter { borrowed($0) == nil }.count,
                                   "waitingForMissionControl": waitingForMissionControl,
                                   "lastError": lastError ?? "",
                                   "eventCounts": eventCounts,
                                   "checkedAt": ISO8601DateFormatter().string(from: Date())]
        // Event counters and timing alone must not cause a disk write on every
        // move or resize. Record meaningful routing changes and explicit checks.
        let volatile: Set<String> = ["checkedAt", "reads", "eventCounts", "chromeCatalogReadAttempts"]
        let stable = report.filter { !volatile.contains($0.key) }
        let snapshot = try? JSONSerialization.data(withJSONObject: stable, options: .sortedKeys)
        if onlyIfChanged && snapshot == lastRuntimeSnapshot { return }
        lastRuntimeSnapshot = snapshot
        let url = dataURL.deletingLastPathComponent().appendingPathComponent("runtime-status.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    var chromeCatalogCountLabel: String {
        if chromeCatalogAvailable { return String(chromeProfiles.count) }
        return chromeProfiles.isEmpty ? "Unavailable" : "\(chromeProfiles.count) saved"
    }

    private func readChromeCatalog(_ url: URL) throws -> [ChromeProfile] {
        chromeCatalogReadAttempts += 1
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: Any] else {
            throw AppError.message("Choose Chrome's Local State file, not a profile's Preferences file.")
        }
        return ChromeResolver.profiles(from: cache)
    }

    private func acceptChromeProfiles(_ profiles: [ChromeProfile], modified: Date?) {
        chromeProfiles = profiles; chromeModified = modified
        chromeCatalogAvailable = true; chromeRetryAfter = .distantPast
        chromeCatalogStatus = "Read \(profiles.count) profiles"
        // Retain only the names and IDs already read with permission, never the
        // source catalog. A later permission failure must not erase this catalog.
        if state.chromeCatalogProfiles != profiles {
            state.chromeCatalogProfiles = profiles
            save()
        }
    }

    func loadChromeProfiles(force: Bool = false) {
        guard !choosingChromeCatalog, force || Date() >= chromeRetryAfter else { return }
        guard !chromeCatalogLocationUnavailable else {
            chromeCatalogAvailable = false
            chromeCatalogStatus = "Reconnect Chrome profiles: the selected file is unavailable.\(chromeProfiles.isEmpty ? "" : " Using saved profile names.")"
            return
        }
        let url = chromeProfilesURL
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard force || chromeModified == nil || modified != chromeModified else { return }
        do {
            let profiles = try readChromeCatalog(url)
            acceptChromeProfiles(profiles, modified: modified)
        } catch {
            chromeCatalogAvailable = false; chromeModified = nil
            // Window events can arrive many times per second. They must not
            // repeatedly trigger a denied file read or a system privacy prompt.
            chromeRetryAfter = Date().addingTimeInterval(30)
            let prefix = chromeProfiles.isEmpty ? "Profile catalog unavailable" : "Using \(chromeProfiles.count) saved profiles; live catalog unavailable"
            chromeCatalogStatus = "\(prefix): \(error.localizedDescription)"
        }
    }

    func connectChromeProfiles() {
        if let chromePicker { chromePicker.makeKeyAndOrderFront(nil); return }
        let picker = NSOpenPanel()
        chromePicker = picker; choosingChromeCatalog = true
        chromeConnectionStatus = "Waiting for a file selection"
        writeRuntimeStatus()
        picker.title = "Connect Chrome profiles"
        picker.message = "Choose Chrome's Local State file. DeskPilot reads profile names and directory identifiers from this file."
        picker.prompt = "Connect profiles"
        picker.directoryURL = chromeProfilesURL.deletingLastPathComponent()
        picker.nameFieldStringValue = "Local State"
        picker.canChooseFiles = true; picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false; picker.canCreateDirectories = false
        picker.showsHiddenFiles = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let url = response == .OK ? picker.url : nil
            Task { @MainActor in
                guard let self else { return }
                self.chromePicker = nil; self.choosingChromeCatalog = false
                if let url { self.connectChromeProfiles(to: url) }
                else { self.chromeConnectionStatus = "File selection cancelled; no access was changed"; self.writeRuntimeStatus() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { picker.beginSheetModal(for: window, completionHandler: completion) }
        else { picker.begin(completionHandler: completion) }
    }

    func connectChromeProfiles(to url: URL) {
        chromeConnectionStatus = "Reading the selected file"
        writeRuntimeStatus()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let profiles = try readChromeCatalog(url)
            let bookmark: Data
            if let scopedBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmark = scopedBookmark
            } else {
                bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            chromeProfilesURL = url; chromeModified = nil; chromeCatalogLocationUnavailable = false
            state.chromeCatalogBookmark = bookmark
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            acceptChromeProfiles(profiles, modified: modified)
            chromeConnectionStatus = "Selected file connected successfully"
            lastError = nil
            save()
            refresh(full: true)
            if state.enabled { enqueueOpenWindows(); schedule(full: true) }
            status = "Connected \(chromeProfiles.count) Chrome profiles"
            writeRuntimeStatus()
        } catch {
            chromeConnectionStatus = "Could not connect the selected file: \(error.localizedDescription)"
            fail(error); writeRuntimeStatus()
        }
    }

    func setChromeProfile(windowID: UInt32, profile: ChromeProfile) {
        guard let w = windows.first(where: { $0.id == windowID && $0.appID == "com.google.Chrome" }) else { return }
        manualChromeBindings["\(w.pid):\(windowID)"] = profile.id
        if state.enabled { routingInbox.enqueue(w.identity) }
        refresh(full: true)
        status = "Profile set to \(profile.name) for this window"
    }

    private func enqueueOpenWindows() {
        for window in windows where borrowed(window) == nil && window.spaceIDs.count == 1 && desktops.contains(where: { $0.systemID == window.spaceIDs[0] && !$0.fullScreen }) {
            routingInbox.enqueue(window.identity)
        }
    }

    func record(_ window: WindowInfo, on desktop: Desktop, preserveHome: Bool = false) {
        guard let key = window.group else { return }
        if preserveHome { temporaryTargets[key] = desktop.id; return }
        let assignment = Assignment(id: key, appID: window.appID, appName: window.appName, profileDirectory: window.profileDirectory,
                                    profileName: window.profileName, desktopID: desktop.id, displayID: desktop.displayID, ordinal: desktop.ordinal)
        state.assignments.removeAll { $0.id == key }; state.assignments.append(assignment)
        temporaryTargets[key] = nil
        save()
    }

    func target(for window: WindowInfo) async throws -> Desktop {
        try checkpoint()
        guard let key = window.group else { throw AppError.message("Choose a Chrome profile for this window.") }
        if let id = temporaryTargets[key], let desktop = desktops.first(where: { $0.id == id && !$0.fullScreen }) { return desktop }
        let rule = state.assignments.first { $0.id == key }
        if let rule, let desktop = Policy.target(for: rule, desktops: desktops, displays: displays), canKeepAssignment(key, on: desktop) { return desktop }
        let current = desktops.first { window.spaceIDs.contains($0.systemID) }
        guard let displayID = Policy.preferredDisplay(for: rule, current: current?.displayID, displays: displays),
              let display = displays.first(where: { $0.id == displayID }) else { throw AppError.message("Unable to identify the destination display.") }
        let before = Set(desktops.map(\.id))
        status = "Creating a desktop for \(window.profileName ?? window.appName)…"
        try checkpoint()
        try await system.missionControl(display: display, select: nil, create: true)
        try checkpoint()
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 150_000_000)
            if let current = system.spaces(displays: displays) {
                desktops = current
                if let created = current.first(where: { $0.displayID == displayID && !$0.fullScreen && !before.contains($0.id) }) {
                    temporaryTargets[key] = created.id
                    return created
                }
            }
        }
        throw AppError.message("macOS did not confirm desktop creation.")
    }

    @discardableResult func runOperation(_ operation: () async throws -> Void) async -> Bool {
        guard !busy && !locked && trusted && operational else {
            if !trusted { status = "Grant window management access" }
            return false
        }
        busy = true; lastError = nil; operationGeneration = generation
        defer { operationGeneration = nil; busy = false; lastOwnMovement = Date(); schedule(full: true); writeRuntimeStatus() }
        do {
            try await operation()
            status = lastError ?? "Done"
            return lastError == nil
        }
        catch {
            if error is CancellationError || locked || operationGeneration != generation {
                status = locked ? "Mac is locked" : (state.enabled ? "Waiting for desktops to settle…" : "Automation paused")
            } else { fail(error) }
            return false
        }
    }

    func routeNew(_ incoming: [WindowInfo]) async {
        await runOperation {
            do {
                let token = self.generation
                var handled = Set<String>()
                for window in incoming {
                    guard self.state.enabled, token == self.generation else { return }
                    guard self.borrowed(window) == nil, let key = window.group, handled.insert(key).inserted, window.spaceIDs.count == 1,
                          self.desktops.contains(where: { $0.systemID == window.spaceIDs[0] && !$0.fullScreen }) else { continue }
                    let destination = try await self.target(for: window)
                    try await self.moveGroup(key, to: destination)
                    let rule = self.state.assignments.first { $0.id == key }
                    let missingHome = rule.map { r in !self.displays.contains { $0.id == r.displayID } } ?? false
                    self.record(window, on: destination, preserveHome: missingHome)
                    // A window may arrive during the awaited move. Complete only
                    // windows whose destination is confirmed, leaving late arrivals queued.
                    let confirmed = self.windows.filter {
                        $0.group == key && self.system.windowSpaces($0.id) == [destination.systemID]
                    }
                    self.routingInbox.complete(confirmed.map(\.identity))
                    self.refresh(full: true)
                    self.arrangeSharedDesktop(destination)
                }
            } catch {
                // A display/session change invalidates the in-flight operation,
                // not the user's decision to keep automation enabled.
                if error is CancellationError || self.locked || self.operationGeneration != self.generation {
                    throw CancellationError()
                }
                self.pauseAutomation(after: error)
                throw error
            }
        }
    }

    func moveGroup(_ key: String, to desktop: Desktop, includeBorrowed: Bool = false) async throws {
        for window in windows.filter({ $0.group == key && (includeBorrowed || borrowed($0) == nil) }) {
            guard window.spaceIDs.count == 1,
                  desktops.contains(where: { $0.systemID == window.spaceIDs[0] && !$0.fullScreen }) else { continue }
            try await moveWindow(window, to: desktop)
        }
    }

    private func moveWindow(_ window: WindowInfo, to desktop: Desktop) async throws {
        try checkpoint()
        guard let current = system.windowSpaces(window.id), current.count == 1,
              desktops.contains(where: { $0.systemID == current[0] && !$0.fullScreen }),
              desktops.contains(where: { $0.id == desktop.id && !$0.fullScreen }) else {
            throw AppError.message("Only windows on one regular desktop can be moved.")
        }
        if current == [desktop.systemID] { return }
        if let error = system.beginMove(window.id, to: desktop.systemID) { throw AppError.message(error) }
        defer { system.endMove() }
        for _ in 0..<24 {
            try await Task.sleep(nanoseconds: 125_000_000)
            try checkpoint()
            if system.windowSpaces(window.id) == [desktop.systemID] {
                previous[window.id] = (window.pid, desktop.systemID)
                return
            }
        }
        let error = AppError.message("macOS did not confirm the window move. Automation has been paused.")
        pauseAutomation(after: error)
        throw error
    }

    func assign(_ windowID: UInt32, to desktop: Desktop, allowSharing: Bool = false) {
        guard let w = windows.first(where: { $0.id == windowID }), let key = w.group else { status = "Choose a Chrome profile first"; return }
        if !allowSharing && hasOtherGroups(on: desktop, than: key) {
            fail(AppError.message("This desktop already belongs to another app or profile. Use Share desktop to place them together.")); return
        }
        Task { await runOperation {
            try await self.moveGroup(key, to: desktop, includeBorrowed: true)
            let confirmed = Set(self.windows.filter { $0.group == key && self.system.windowSpaces($0.id) == [desktop.systemID] }.map(\.identity))
            self.state.borrowedWindows?.removeAll { confirmed.contains($0.id) }
            if allowSharing {
                self.approveSharing(key, on: desktop)
                for resident in self.windows where resident.group != key && self.borrowed(resident) == nil && self.system.windowSpaces(resident.id) == [desktop.systemID] {
                    self.record(resident, on: desktop)
                }
            }
            self.record(w, on: desktop)
            self.arrangeSharedDesktop(desktop)
        } }
    }

    func hasOtherGroups(on desktop: Desktop, than group: String) -> Bool {
        state.assignments.contains { $0.desktopID == desktop.id && $0.id != group } ||
        windows.contains { $0.spaceIDs == [desktop.systemID] && $0.group != nil && $0.group != group }
    }

    private func canKeepAssignment(_ group: String, on desktop: Desktop) -> Bool {
        let residents = Set(state.assignments.filter { $0.desktopID == desktop.id }.map(\.id))
        guard residents.count > 1 else { return true }
        let approved = Set(state.sharedDesktopGroups?[desktop.id] ?? [])
        if approved.contains(group) { return true }
        if !approved.intersection(residents).isEmpty { return false }
        // Old ambiguous collisions split deterministically, without using Space numbers.
        return residents.sorted().first == group
    }

    private func approveSharing(_ group: String, on desktop: Desktop) {
        let residents = state.assignments.filter { $0.desktopID == desktop.id }.map(\.id) +
            windows.filter { system.windowSpaces($0.id) == [desktop.systemID] && borrowed($0) == nil }.compactMap(\.group)
        if state.sharedDesktopGroups == nil { state.sharedDesktopGroups = [:] }
        state.sharedDesktopGroups?[desktop.id] = Array(Set(residents + [group])).sorted()
    }

    func assignSavedGroup(_ group: String, to desktop: Desktop) {
        guard let index = state.assignments.firstIndex(where: { $0.id == group }), !busy else { return }
        approveSharing(group, on: desktop)
        state.assignments[index].desktopID = desktop.id
        state.assignments[index].displayID = desktop.displayID
        state.assignments[index].ordinal = desktop.ordinal
        save()
    }

    func arrangeSharedDesktop(_ desktop: Desktop) {
        guard state.autoTileSharedWindows ?? true,
              let display = displays.first(where: { $0.id == desktop.displayID }), !desktop.fullScreen else { return }
        let visible = windows.filter {
            !$0.minimized && $0.group != nil && system.windowSpaces($0.id) == [desktop.systemID]
        }.sorted { $0.id < $1.id }
        guard visible.count == 2, visible[0].group != visible[1].group else { return }
        // Only a recorded home or an explicit summon authorizes sharing.
        guard visible.allSatisfy({ window in
            borrowed(window) != nil || state.assignments.contains { $0.id == window.group && $0.desktopID == desktop.id }
        }) else { return }
        let area = display.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = (area.width - 8) / 2
        for (index, window) in visible.enumerated() {
            let frame = CGRect(x: area.minX + CGFloat(index) * (width + 8), y: area.minY, width: width, height: area.height)
            if !system.setFrame(frame, windowID: window.id) {
                lastError = "The app did not allow automatic side-by-side placement. Its desktop assignment is unchanged."
            }
        }
    }

    func focusHoveredWindow(_ id: UInt32) {
        guard state.focusFollowsMouse ?? true, trusted, !busy, !locked,
              let window = windows.first(where: { $0.id == id && !$0.minimized }),
              let spaces = system.windowSpaces(window.id), spaces.count == 1,
              desktops.contains(where: { $0.systemID == spaces[0] && $0.active && !$0.fullScreen }),
              system.focusedWindowID() != id, system.missionControlRoot() == nil else { return }
        _ = system.focusWindow(id)
    }

    func organize() {
        refresh(full: true)
        let all = windows
        Task { await runOperation {
            var handled = Set<String>()
            for window in all {
                guard self.borrowed(window) == nil, let key = window.group, handled.insert(key).inserted, window.spaceIDs.count == 1,
                      self.desktops.contains(where: { $0.systemID == window.spaceIDs[0] && !$0.fullScreen }) else { continue }
                let target = try await self.target(for: window)
                try await self.moveGroup(key, to: target)
                self.record(window, on: target)
                self.refresh(full: true)
            }
        } }
    }

    func switchTo(_ desktop: Desktop) {
        guard let display = displays.first(where: { $0.id == desktop.displayID }) else { return }
        Task { await runOperation {
            try await self.system.missionControl(display: display, select: desktop, create: false)
            for _ in 0..<15 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if self.system.spaces(displays: self.displays)?.contains(where: { $0.id == desktop.id && $0.active }) == true { return }
            }
            throw AppError.message("macOS did not confirm the desktop switch.")
        } }
    }

    func rename(_ desktop: Desktop, to name: String) {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.names[desktop.id] = text.isEmpty ? nil : String(text.prefix(80)); save()
    }

    func tile(windowID: UInt32, side: String) {
        guard !busy, let window = windows.first(where: { $0.id == windowID }),
              let desktop = desktops.first(where: { window.spaceIDs.contains($0.systemID) && !$0.fullScreen }),
              let display = displays.first(where: { $0.id == desktop.displayID }) else { return }
        let area = display.visibleFrame.insetBy(dx: 8, dy: 8)
        let half = (area.width - 8) / 2
        let frame = side == "fill" ? area : CGRect(x: side == "right" ? area.minX + half + 8 : area.minX, y: area.minY, width: half, height: area.height)
        if system.setFrame(frame, windowID: windowID) { status = "Window arranged"; schedule(full: true) }
        else { status = "The app did not allow this window to be resized" }
    }

    func saveProfile(name: String, fallback: Bool) {
        guard !busy && trusted else { return }
        refresh(full: true)
        var rules: [Assignment] = []
        var frames: [SavedWindow] = []
        var seen = Set<String>()
        for w in windows {
            guard let key = w.group, w.spaceIDs.count == 1,
                  let desktop = desktops.first(where: { d in !d.fullScreen && (borrowed(w).map { $0.homeDesktopID == d.id } ?? (d.systemID == w.spaceIDs[0])) }),
                  let display = displays.first(where: { $0.id == desktop.displayID }) else { continue }
            if seen.insert(key).inserted {
                rules.append(state.assignments.first(where: { $0.id == key && (state.borrowedWindows ?? []).contains { $0.group == key } }) ?? Assignment(id: key, appID: w.appID, appName: w.appName, profileDirectory: w.profileDirectory,
                                        profileName: w.profileName, desktopID: desktop.id, displayID: desktop.displayID, ordinal: desktop.ordinal))
            }
            frames.append(SavedWindow(group: key, titleHash: Self.hash(w.title), frame: borrowed(w)?.originalFrame ?? RelativeFrame(w.frame, in: display.visibleFrame)))
        }
        // A disconnected home must not be lost when saving while a window is borrowed.
        for rule in state.assignments where !seen.contains(rule.id) && (state.borrowedWindows ?? []).contains(where: { $0.group == rule.id }) {
            rules.append(rule)
        }
        let profile = LayoutProfile(name: name.isEmpty ? "Layout \(state.profiles.count + 1)" : name,
                                    displayIDs: displays.map(\.id), assignments: rules, frames: frames, names: state.names)
        state.profiles.append(profile)
        if fallback { state.defaultProfileID = profile.id }
        for (desktopID, shared) in Dictionary(grouping: rules, by: \.desktopID) where shared.count > 1 {
            if state.sharedDesktopGroups == nil { state.sharedDesktopGroups = [:] }
            state.sharedDesktopGroups?[desktopID] = shared.map(\.id)
        }
        state.assignments = rules; activeProfileID = profile.id; save(); status = "Saved layout “\(profile.name)”"
    }

    func restore(_ profile: LayoutProfile) {
        Task { await runOperation { try await self.restoreProfile(profile) } }
    }

    private func restoreProfile(_ profile: LayoutProfile) async throws {
        try checkpoint()
        restoring = true
        defer { restoring = false }
        let token = generation
        state.assignments = profile.assignments; state.names.merge(profile.names) { _, new in new }; temporaryTargets.removeAll()
        // A saved layout is an explicit grouping choice, including when restored automatically.
        for (desktopID, rules) in Dictionary(grouping: profile.assignments, by: \.desktopID) where rules.count > 1 {
            if state.sharedDesktopGroups == nil { state.sharedDesktopGroups = [:] }
            state.sharedDesktopGroups?[desktopID] = rules.map(\.id)
        }
        if state.launchMissingApps {
            for rule in profile.assignments where !windows.contains(where: { $0.group == rule.id }) {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.appID) else { continue }
                let config = NSWorkspace.OpenConfiguration(); config.activates = false
                if let directory = rule.profileDirectory { config.arguments = ["--profile-directory=\(directory)"] }
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            refresh(full: true)
        }
        // Share a recreated desktop among groups that shared it in the saved profile.
        var remap: [String: Desktop] = [:]
        var missing = 0
        for rule in profile.assignments {
            guard !locked && token == generation else { throw CancellationError() }
            guard let window = windows.first(where: { $0.group == rule.id && borrowed($0) == nil }) else {
                if !windows.contains(where: { $0.group == rule.id }) { missing += 1 }
                continue
            }
            let target: Desktop
            if let shared = remap[rule.desktopID] { target = shared }
            else { target = try await self.target(for: window); remap[rule.desktopID] = target }
            let savedSharing = profile.assignments.filter { $0.desktopID == rule.desktopID }.map(\.id)
            if savedSharing.count > 1 {
                if state.sharedDesktopGroups == nil { state.sharedDesktopGroups = [:] }
                state.sharedDesktopGroups?[target.id] = savedSharing
            }
            try await moveGroup(rule.id, to: target)
            let homeMissing = !displays.contains { $0.id == rule.displayID }
            record(window, on: target, preserveHome: homeMissing)
            guard let display = displays.first(where: { $0.id == target.displayID }) else { continue }
            if let label = profile.names[rule.desktopID] { state.names[target.id] = label }
            let actual = windows.filter { $0.group == rule.id && borrowed($0) == nil }
            let saved = profile.frames.filter { $0.group == rule.id }
            for w in actual {
                let candidates = saved.filter { $0.titleHash == Self.hash(w.title) }
                let entry = actual.count == 1 && saved.count == 1 ? saved.first : (candidates.count == 1 && actual.filter { Self.hash($0.title) == Self.hash(w.title) }.count == 1 ? candidates.first : nil)
                if let entry { _ = system.setFrame(entry.frame.rect(in: display.visibleFrame), windowID: w.id) }
            }
            refresh(full: true)
        }
        activeProfileID = profile.id; save()
        if missing > 0 { lastError = "Available windows restored. \(missing) saved apps or profiles have no open windows." }
    }

    private func handleTopology() {
        generation += 1; guardUntil = Date().addingTimeInterval(5)
        routingInbox.clear(); launching.removeAll(); previous.removeAll(); temporaryTargets.removeAll()
        topologyTask?.cancel(); status = "Waiting for displays to settle…"
        topologyTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard let self, !self.locked else { return }
            self.oldDisplaySignature = ""
            self.refresh(full: true)
            guard self.state.enabled else { self.status = "Displays updated"; return }
            if self.state.automaticProfiles, let profile = Policy.profile(for: self.displays.map(\.id), state: self.state) {
                await self.runOperation { try await self.restoreProfile(profile) }
            } else {
                self.enqueueOpenWindows()
                self.schedule(full: true)
                self.status = "Assigning apps to desktops"
            }
        }
    }

    func removeProfile(_ id: String) {
        state.profiles.removeAll { $0.id == id }; if state.defaultProfileID == id { state.defaultProfileID = nil }; save()
    }

    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { fail(error) }
    }

    static func hash(_ title: String) -> String { SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined() }
}

@MainActor extension Engine {
    var numberedDesktops: [Desktop] {
        displays.flatMap { display in desktops.filter { $0.displayID == display.id && !$0.fullScreen }.sorted { $0.ordinal < $1.ordinal } }
    }

    func number(_ desktop: Desktop) -> String {
        numberedDesktops.firstIndex { $0.id == desktop.id }.map { String($0 + 1) } ?? "Full screen"
    }

    func borrowed(_ window: WindowInfo) -> BorrowedWindow? {
        state.borrowedWindows?.first { $0.id == window.identity && $0.appID == window.appID && system.processStarted(window.pid) == $0.processStarted }
    }

    private func reconcileBorrowedWindows(live: Set<WindowIdentity>?) {
        if let live {
            focusOrder = focusOrder.filter { live.contains($0.key) }
            summonOrder = summonOrder.filter { live.contains($0.key) }
        }
        guard let saved = state.borrowedWindows, !saved.isEmpty else { return }
        let retained = saved.filter { loan in
            system.processStarted(loan.id.pid) == loan.processStarted && (live?.contains(loan.id) ?? true)
        }
        if retained != saved { state.borrowedWindows = retained; save() }
    }

    func activeDestination() throws -> Desktop {
        if let focused = system.focusedWindowID(), let spaces = system.windowSpaces(focused), spaces.count == 1,
           let desktop = desktops.first(where: { $0.systemID == spaces[0] && $0.active }) {
            guard !desktop.fullScreen else { throw AppError.message("Leave full screen before summoning a window.") }
            return desktop
        }
        if let display = system.pointerDisplayID(), let desktop = desktops.first(where: { $0.displayID == display && $0.active }) {
            guard !desktop.fullScreen else { throw AppError.message("Leave full screen before summoning a window.") }
            return desktop
        }
        let active = desktops.filter(\.active)
        guard active.count == 1, let desktop = active.first, !desktop.fullScreen else {
            throw AppError.message("Focus a window on the destination display, then summon again.")
        }
        return desktop
    }

    func summon(_ desktop: Desktop, destinationID: String? = nil) {
        do {
            let screens = system.screens()
            guard let spaces = system.spaces(displays: screens) else { throw AppError.message("Unable to read desktops.") }
            displays = screens; desktops = spaces
            queue(.summon(source: desktop.id, destination: try destinationID ?? activeDestination().id))
        } catch { fail(error) }
    }

    func sendBack(_ windowID: UInt32) { queue(.sendBack(windowID)) }

    func summonUnavailableReason(from source: Desktop, to destination: Desktop) -> String? {
        if !trusted { return "Window access is required" }
        if source.id == destination.id { return "You are here" }
        let residents = windows.filter { $0.spaceIDs == [source.systemID] }
        if residents.isEmpty { return "No accessible windows · try Refresh windows" }
        if residents.allSatisfy({ borrowed($0) != nil }) { return "Windows already summoned" }
        if !residents.contains(where: { $0.group != nil && borrowed($0) == nil }) {
            return "Choose a Chrome profile in the main panel"
        }
        return nil
    }

    private func queue(_ command: WindowCommand) {
        guard trusted, !locked else { status = "Grant window access and unlock the Mac first"; return }
        guard windowCommands.count < 20 else { status = "Please wait for queued window moves"; return }
        windowCommands.append(command)
        guard commandTask == nil else { return }
        let token = generation
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { self.commandTask = nil; self.windowCommands.removeAll() }
            while !self.windowCommands.isEmpty {
                guard !self.locked, token == self.generation else { return }
                if self.busy { try? await Task.sleep(nanoseconds: 100_000_000); continue }
                let next = self.windowCommands.removeFirst()
                switch next {
                case let .summon(source, destination): await self.summonNextWindow(from: source, to: destination)
                case let .sendBack(id): await self.returnWindow(id)
                }
                // Do not repeat a failed action for each queued keypress.
                if self.lastError != nil { return }
            }
        }
    }

    @discardableResult func summonNextWindow(from sourceID: String, to destinationID: String) async -> Bool {
        return await runOperation {
            self.refresh(full: true)
            try self.checkpoint()
            guard self.spaceSnapshotAvailable else { throw AppError.message("Unable to read current desktops. No window was moved.") }
            guard self.system.missionControlRoot() == nil else { throw AppError.message("Close Mission Control before summoning a window.") }
            guard let source = self.desktops.first(where: { $0.id == sourceID && !$0.fullScreen }),
                  let destination = self.desktops.first(where: { $0.id == destinationID && !$0.fullScreen && $0.active }),
                  source.id != destination.id else {
                throw AppError.message("Choose another desktop as the source. The destination must still be active.")
            }
            let candidates = self.windows.filter {
                self.borrowed($0) == nil && $0.group != nil && $0.spaceIDs == [source.systemID]
            }.sorted { lhs, rhs in
                let left = self.summonOrder[lhs.identity, default: 0], right = self.summonOrder[rhs.identity, default: 0]
                if left != right { return left < right }
                let lf = self.focusOrder[lhs.identity, default: 0], rf = self.focusOrder[rhs.identity, default: 0]
                return lf == rf ? lhs.id < rhs.id : lf > rf
            }
            guard let window = candidates.first, let group = window.group else {
                throw AppError.message("No more recognized windows to summon from this desktop. Return a window to use it again.")
            }
            guard let started = self.system.processStarted(window.pid),
                  let homeDisplay = self.displays.first(where: { $0.id == source.displayID }),
                  let destinationDisplay = self.displays.first(where: { $0.id == destination.displayID }) else {
                throw AppError.message("Unable to identify this window's app or display. No window was moved.")
            }
            let loan = BorrowedWindow(id: window.identity, processStarted: started, appID: window.appID, group: group,
                                      homeDesktopID: source.id, originalFrame: RelativeFrame(window.frame, in: homeDisplay.visibleFrame), wasMinimized: window.minimized)
            let before = self.state.borrowedWindows
            self.state.borrowedWindows = (before ?? []).filter { $0.id != loan.id } + [loan]
            guard self.save() else {
                self.state.borrowedWindows = before
                throw AppError.message("Could not save the return location. No window was moved.")
            }
            self.routingInbox.remove(window.identity)
            do { try await self.moveWindow(window, to: destination) }
            catch {
                if self.system.windowSpaces(window.id) == [source.systemID] {
                    self.state.borrowedWindows = before; self.save()
                }
                throw error
            }
            self.interactionSerial += 1; self.summonOrder[window.identity] = self.interactionSerial
            guard self.system.spaces(displays: self.displays)?.contains(where: { $0.id == destination.id && $0.active }) == true else {
                throw AppError.message("Window moved, but the destination is no longer active. Its return location is saved.")
            }
            if window.minimized && !self.system.setMinimized(false, windowID: window.id) {
                throw AppError.message("Window moved, but the app could not unminimize it. Its return location is saved.")
            }
            let placed = self.system.setFrame(loan.originalFrame.rect(in: destinationDisplay.visibleFrame), windowID: window.id)
            let focused = self.system.focusWindow(window.id)
            self.rememberedWindow = window.id
            self.refresh(full: true)
            if !placed || !focused { throw AppError.message("Window moved, but the app did not accept its position or focus. Use Return home to send it back.") }
            // App activation and WindowServer visibility settle asynchronously.
            // A successful move request alone does not mean the user can see it.
            try await self.confirmSummonedWindow(window.id, on: destination)
            self.arrangeSharedDesktop(destination)
        }
    }

    private func confirmSummonedWindow(_ id: UInt32, on destination: Desktop) async throws {
        for attempt in 0..<9 {
            try checkpoint()
            guard system.spaces(displays: displays)?.contains(where: { $0.id == destination.id && $0.active }) == true else {
                throw AppError.message("The active desktop changed while focusing the window. Its return location is saved. Go back to the destination and try again.")
            }
            if system.windowSpaces(id) == [destination.systemID], system.isWindowVisible(id), system.focusedWindowID() == id { return }
            if attempt < 8 { try await Task.sleep(nanoseconds: 125_000_000) }
        }
        throw AppError.message("The window moved, but is not visible or focused on this desktop. Its return location is saved; use Return home to undo the move.")
    }

    @discardableResult func returnWindow(_ windowID: UInt32) async -> Bool {
        return await runOperation {
            self.refresh(full: true)
            try self.checkpoint()
            guard self.spaceSnapshotAvailable else { throw AppError.message("Unable to read current desktops. No window was moved.") }
            guard self.system.missionControlRoot() == nil else { throw AppError.message("Close Mission Control before returning a window.") }
            guard let window = self.windows.first(where: { $0.id == windowID }), let loan = self.borrowed(window) else {
                throw AppError.message("The selected window was not summoned by DeskPilot.")
            }
            guard let home = self.desktops.first(where: { $0.id == loan.homeDesktopID && !$0.fullScreen }),
                  let display = self.displays.first(where: { $0.id == home.displayID }) else {
                throw AppError.message("The original desktop is unavailable. Reconnect its display, or use Move to to choose a new permanent home.")
            }
            try await self.moveWindow(window, to: home)
            guard self.system.setFrame(loan.originalFrame.rect(in: display.visibleFrame), windowID: window.id),
                  !loan.wasMinimized || self.system.setMinimized(true, windowID: window.id) else {
                throw AppError.message("Window is home, but its original size or minimized state was not restored. Return home can retry.")
            }
            self.state.borrowedWindows?.removeAll { $0.id == loan.id }
            if !self.save() {
                self.state.borrowedWindows = (self.state.borrowedWindows ?? []) + [loan]
                throw AppError.message("Window is home, but saving its return failed. Return home can retry.")
            }
            self.routingInbox.remove(window.identity)
            self.refresh(full: true)
        }
    }
}
