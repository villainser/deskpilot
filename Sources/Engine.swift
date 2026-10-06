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
    @Published var status = "Ready to set up"
    @Published var trusted = false
    @Published var busy = false
    @Published var locked = false
    @Published var events = 0
    @Published var refreshes = 0
    @Published var lastReadMilliseconds = 0.0
    @Published var activeProfileID: String?
    @Published var lastError: String?
    var onChange: (() -> Void)?
    let system: SystemAccessProtocol
    let dataURL: URL
    private let chromeProfilesURL: URL
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
            } catch {
                operational = false
                lastError = "Unable to load settings. The original file was preserved: \(error.localizedDescription)"
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
        status = trusted ? (state.enabled ? "Automation enabled" : "Automation paused") : "Grant window management access"
    }

    func event(_ name: String, pid: Int32?, windowID: UInt32?) {
        events += 1
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
            routingInbox.remove(WindowIdentity(pid: pid, windowID: windowID))
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
        guard !locked else { return }
        let previousTrust = trusted
        trusted = system.trusted
        if previousTrust != trusted { writeRuntimeStatus() }
        displays = system.screens()
        displayGeometry = geometrySignature(displays)
        guard let spaces = system.spaces(displays: displays) else {
            lastError = "Unable to read desktops. No windows will be moved."
            if state.enabled && (routingInbox.needsRetry() || launching.values.contains(where: { Date().timeIntervalSince($0) < 8 })) {
                schedule(delay: 1, full: true)
            }
            return
        }
        desktops = spaces
        let currentSignature = displays.map(\.id).sorted().joined(separator: "|")
        if !oldDisplaySignature.isEmpty && oldDisplaySignature != currentSignature {
            oldDisplaySignature = currentSignature
            handleTopology(); return
        }
        oldDisplaySignature = currentSignature
        let changed = dirty; dirty.removeAll()
        let raw = system.readWindows(dirty: full || !hasBaseline ? nil : changed)
        if let serverWindows = system.windowIdentities() {
            if let before = knownServerWindows, state.enabled && !restoring {
                for identity in serverWindows.subtracting(before) { routingInbox.enqueue(identity) }
            }
            knownServerWindows = serverWindows
            routingInbox.reconcile(live: serverWindows)
        }
        loadChromeProfiles()
        windows = raw.map { item in
            var item = item
            if item.appID == "com.google.Chrome" {
                let key = "\(item.pid):\(item.id)"
                let manual = manualChromeBindings[key].flatMap { id in chromeProfiles.first { $0.id == id } }
                let cached = chromeBindings[key].flatMap { old in chromeProfiles.first { $0.id == old.id } }
                let titles = [item.title] + item.accessibilityTitles
                let explicitIdentity = titles.contains(where: ChromeResolver.hasIdentitySuffix)
                let profile = manual ?? ChromeResolver.resolve(titles: titles, profiles: chromeProfiles) ?? (explicitIdentity ? nil : cached)
                if explicitIdentity && profile == nil { chromeBindings[key] = nil }
                if let profile { chromeBindings[key] = profile; item.group = item.appID + "::" + profile.id; item.profileName = profile.name; item.profileDirectory = profile.id }
            } else { item.group = item.appID }
            return item
        }
        let live = Set(windows.filter { $0.appID == "com.google.Chrome" }.map { "\($0.pid):\($0.id)" })
        chromeBindings = chromeBindings.filter { live.contains($0.key) }
        manualChromeBindings = manualChromeBindings.filter { live.contains($0.key) }
        refreshes += 1; lastReadMilliseconds = system.lastReadMilliseconds
        var manual: [(WindowInfo, Desktop)] = []
        if hasBaseline && state.enabled && !busy && !restoring && Date() > guardUntil && Date().timeIntervalSince(lastOwnMovement) > 2 {
            for window in windows {
                guard let key = window.group, let before = previous[window.id], before.0 == window.pid,
                      window.spaceIDs.count == 1, before.1 != window.spaceIDs[0],
                      let destination = desktops.first(where: { $0.systemID == window.spaceIDs[0] && !$0.fullScreen }),
                      state.assignments.contains(where: { $0.id == key }), system.missionControlRoot() == nil else { continue }
                manual.append((window, destination))
            }
        }
        previous = Dictionary(uniqueKeysWithValues: windows.compactMap { w in w.spaceIDs.count == 1 ? (w.id, (w.pid, w.spaceIDs[0])) : nil })
        let new = hasBaseline ? routingInbox.candidates(in: windows) : []
        hasBaseline = true
        onChange?()
        guard trusted && operational && state.enabled && !busy && !restoring else { return }
        guard Date() > guardUntil else {
            if !routingInbox.isEmpty || !launching.isEmpty { schedule(delay: max(0.1, guardUntil.timeIntervalSinceNow + 0.1), full: true) }
            return
        }
        guard system.missionControlRoot() == nil else {
            if routingInbox.needsRetry() { schedule(delay: 0.5, full: true) }
            return
        }
        // Poll only during a bounded startup interval. Unresolved live windows
        // stay queued and can complete after a later title/profile event.
        let deadline = Date().addingTimeInterval(-8)
        launching = launching.filter { $0.value > deadline }
        if routingInbox.needsRetry() || !launching.isEmpty { schedule(delay: 1, full: true) }
        if !manual.isEmpty {
            Task { await runOperation {
                var handled = Set<String>()
                for (window, destination) in manual {
                    guard let key = window.group, handled.insert(key).inserted else { continue }
                    try await self.moveGroup(key, to: destination)
                    self.record(window, on: destination)
                }
            } }
        } else if !new.isEmpty {
            Task { await routeNew(new) }
        }
    }

    private func geometrySignature(_ values: [Display]) -> String {
        values.map { "\($0.id):\($0.frame)" }.sorted().joined(separator: "|")
    }

    private func checkpoint() throws {
        guard !locked, operationGeneration == generation else { throw AppError.message("The operation was cancelled after a system state change.") }
    }

    func name(_ desktop: Desktop) -> String {
        DesktopNaming.name(for: desktop, customNames: state.names, assignments: state.assignments, windows: windows)
    }

    func save() {
        guard operational else { return }
        do {
            try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: dataURL, options: .atomic)
        } catch { fail(error) }
        onChange?()
    }

    func fail(_ error: Error) { lastError = error.localizedDescription; status = error.localizedDescription }

    func toggleEnabled() {
        guard operational else { return }
        // Permission may have changed in System Settings since the last scan.
        trusted = system.trusted
        writeRuntimeStatus()
        if !state.enabled && !trusted { requestAccessibility(); return }
        state.enabled.toggle(); generation += 1; routingInbox.clear(); launching.removeAll()
        if !state.enabled { topologyTask?.cancel() }
        guardUntil = Date().addingTimeInterval(1)
        refresh(full: true)
        if state.enabled { enqueueOpenWindows() }
        schedule(delay: 1.1, full: true)
        status = state.enabled ? "Automation enabled" : "Automation paused"
        save()
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

    func checkAccessibility() {
        refresh(full: true)
        writeRuntimeStatus()
        if !busy {
            status = trusted ? (state.enabled ? "Automation enabled" : "Access granted · automation paused") : "Access is not granted to this copy of DeskPilot"
        }
    }

    func writeRuntimeStatus() {
        let report: [String: Any] = ["pid": getpid(), "applicationPath": Bundle.main.bundleURL.path,
                                   "accessibility": trusted, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                                   "checkedAt": ISO8601DateFormatter().string(from: Date())]
        let url = dataURL.deletingLastPathComponent().appendingPathComponent("runtime-status.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func loadChromeProfiles() {
        let url = chromeProfilesURL
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard chromeModified == nil || modified != chromeModified else { return }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: Any] else { return }
        chromeProfiles = ChromeResolver.profiles(from: cache); chromeModified = modified
    }

    func setChromeProfile(windowID: UInt32, profile: ChromeProfile) {
        guard let w = windows.first(where: { $0.id == windowID && $0.appID == "com.google.Chrome" }) else { return }
        manualChromeBindings["\(w.pid):\(windowID)"] = profile.id
        if state.enabled { routingInbox.enqueue(w.identity) }
        refresh(full: true)
        status = "Profile set to \(profile.name) for this window"
    }

    private func enqueueOpenWindows() {
        for window in windows where window.spaceIDs.count == 1 && desktops.contains(where: { $0.systemID == window.spaceIDs[0] && !$0.fullScreen }) {
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
        if let rule, let desktop = Policy.target(for: rule, desktops: desktops, displays: displays) { return desktop }
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

    func runOperation(_ operation: () async throws -> Void) async {
        guard !busy && !locked && trusted && operational else {
            if !trusted { status = "Grant window management access" }
            return
        }
        busy = true; lastError = nil; operationGeneration = generation
        defer { operationGeneration = nil; busy = false; lastOwnMovement = Date(); schedule(full: true) }
        do { try await operation(); status = "Done" }
        catch { fail(error) }
    }

    func routeNew(_ incoming: [WindowInfo]) async {
        await runOperation {
            do {
                let token = self.generation
                var handled = Set<String>()
                for window in incoming {
                    guard self.state.enabled, token == self.generation else { return }
                    guard let key = window.group, handled.insert(key).inserted, window.spaceIDs.count == 1,
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
                }
            } catch {
                self.state.enabled = false; self.save()
                throw error
            }
        }
    }

    func moveGroup(_ key: String, to desktop: Desktop) async throws {
        try checkpoint()
        let token = operationGeneration
        for window in windows.filter({ $0.group == key }) {
            guard !locked && token == generation else { throw AppError.message("Cancelled after a system state change.") }
            guard window.spaceIDs.count == 1,
                  desktops.contains(where: { $0.systemID == window.spaceIDs[0] && !$0.fullScreen }) else { continue }
            if window.spaceIDs[0] == desktop.systemID { continue }
            if let error = system.beginMove(window.id, to: desktop.systemID) { throw AppError.message(error) }
            defer { system.endMove() }
            var confirmed = false
            for _ in 0..<24 {
                try await Task.sleep(nanoseconds: 125_000_000)
                if system.windowSpaces(window.id) == [desktop.systemID] { confirmed = true; break }
                if locked || token != generation { break }
            }
            guard confirmed else {
                state.enabled = false; save()
                throw AppError.message("macOS did not confirm the window move. Automation has been paused.")
            }
            previous[window.id] = (window.pid, desktop.systemID)
        }
    }

    func assign(_ windowID: UInt32, to desktop: Desktop) {
        guard let w = windows.first(where: { $0.id == windowID }), let key = w.group else { status = "Choose a Chrome profile first"; return }
        Task { await runOperation { try await self.moveGroup(key, to: desktop); self.record(w, on: desktop) } }
    }

    func organize() {
        refresh(full: true)
        let all = windows
        Task { await runOperation {
            var handled = Set<String>()
            for window in all {
                guard let key = window.group, handled.insert(key).inserted, window.spaceIDs.count == 1,
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
                  let desktop = desktops.first(where: { $0.systemID == w.spaceIDs[0] && !$0.fullScreen }),
                  let display = displays.first(where: { $0.id == desktop.displayID }) else { continue }
            if seen.insert(key).inserted {
                rules.append(Assignment(id: key, appID: w.appID, appName: w.appName, profileDirectory: w.profileDirectory,
                                        profileName: w.profileName, desktopID: desktop.id, displayID: desktop.displayID, ordinal: desktop.ordinal))
            }
            frames.append(SavedWindow(group: key, titleHash: Self.hash(w.title), frame: RelativeFrame(w.frame, in: display.visibleFrame)))
        }
        let profile = LayoutProfile(name: name.isEmpty ? "Layout \(state.profiles.count + 1)" : name,
                                    displayIDs: displays.map(\.id), assignments: rules, frames: frames, names: state.names)
        state.profiles.append(profile)
        if fallback { state.defaultProfileID = profile.id }
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
            guard !locked && token == generation else { throw AppError.message("Layout restoration was cancelled after a system change.") }
            guard let window = windows.first(where: { $0.group == rule.id }) else { missing += 1; continue }
            let target: Desktop
            if let shared = remap[rule.desktopID] { target = shared }
            else { target = try await self.target(for: window); remap[rule.desktopID] = target }
            try await moveGroup(rule.id, to: target)
            let homeMissing = !displays.contains { $0.id == rule.displayID }
            record(window, on: target, preserveHome: homeMissing)
            guard let display = displays.first(where: { $0.id == target.displayID }) else { continue }
            if let label = profile.names[rule.desktopID] { state.names[target.id] = label }
            let actual = windows.filter { $0.group == rule.id }
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
            guard self.state.enabled, self.state.automaticProfiles else { self.status = "Displays updated"; return }
            if let profile = Policy.profile(for: self.displays.map(\.id), state: self.state) {
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
