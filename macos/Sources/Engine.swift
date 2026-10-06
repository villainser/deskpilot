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
    @Published var status = "Gotowy do konfiguracji"
    @Published var trusted = false
    @Published var busy = false
    @Published var locked = false
    @Published var events = 0
    @Published var refreshes = 0
    @Published var lastReadMilliseconds = 0.0
    @Published var activeProfileID: String?
    @Published var lastError: String?
    var onChange: (() -> Void)?
    let system = SystemAccess()
    let dataURL: URL
    var rememberedWindow: UInt32?
    private var pending: DispatchWorkItem?
    private var dirty = Set<Int32>()
    private var fullRead = false
    private var births: [UInt32: Date] = [:]
    private var launching: [Int32: Date] = [:]
    private var previous: [UInt32: (Int32, UInt64)] = [:]
    private var chromeBindings: [String: ChromeProfile] = [:]
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

    init(dataURL: URL? = nil) {
        self.dataURL = dataURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskPilot Native", isDirectory: true).appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: self.dataURL) {
            do {
                let loaded = try JSONDecoder().decode(AppState.self, from: data)
                guard loaded.schema == 1 else { throw AppError.message("Nieobsługiwana wersja zapisu ustawień.") }
                state = loaded
            } catch {
                operational = false
                lastError = "Nie udało się wczytać ustawień. Oryginalny plik został zachowany: \(error.localizedDescription)"
            }
        }
    }

    func start() {
        system.onEvent = { [weak self] name, pid, id in
            Task { @MainActor in self?.event(name, pid: pid, windowID: id) }
        }
        system.start()
        refresh(full: true)
        guardUntil = Date().addingTimeInterval(3)
        if state.enabled && state.automaticProfiles { handleTopology() }
        else { schedule(delay: 3.1) }
        status = trusted ? (state.enabled ? "Automatyka aktywna" : "Automatyka wstrzymana") : "Nadaj uprawnienie Dostępność"
    }

    func event(_ name: String, pid: Int32?, windowID: UInt32?) {
        events += 1
        if name == "com.apple.screenIsLocked" || name == NSWorkspace.sessionDidResignActiveNotification.rawValue {
            locked = true; generation += 1; births.removeAll(); launching.removeAll(); pending?.cancel()
            topologyTask?.cancel(); status = "Mac zablokowany"; return
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
            if name == kAXWindowCreatedNotification, let windowID { births[windowID] = Date() }
            if name == NSWorkspace.didLaunchApplicationNotification.rawValue, let pid { launching[pid] = Date() }
        }
        if name == kAXUIElementDestroyedNotification, let pid, let windowID {
            chromeBindings["\(pid):\(windowID)"] = nil
            births[windowID] = nil
        }
        if let pid { dirty.insert(pid) }
        if name == NSWorkspace.activeSpaceDidChangeNotification.rawValue { fullRead = true }
        if name == kAXMovedNotification || name == kAXResizedNotification { schedule(delay: 0.8) }
        else { schedule(delay: 0.35) }
    }

    func schedule(delay: TimeInterval = 0.35, full: Bool = false) {
        fullRead = fullRead || full
        pending?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
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
            lastError = "Nie udało się odczytać biurek. Automatyka nie wykona ruchów."
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
        loadChromeProfiles()
        windows = raw.map { item in
            var item = item
            if item.appID == "com.google.Chrome" {
                let key = "\(item.pid):\(item.id)"
                let profile = ChromeResolver.resolve(title: item.title, profiles: chromeProfiles) ?? chromeBindings[key]
                if let profile { chromeBindings[key] = profile; item.group = item.appID + "::" + profile.id; item.profileName = profile.name; item.profileDirectory = profile.id }
            } else { item.group = item.appID }
            return item
        }
        let live = Set(windows.filter { $0.appID == "com.google.Chrome" }.map { "\($0.pid):\($0.id)" })
        chromeBindings = chromeBindings.filter { live.contains($0.key) }
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
        let new = hasBaseline ? windows.filter { births[$0.id] != nil || launching[$0.pid] != nil } : []
        hasBaseline = true
        onChange?()
        guard trusted && operational && state.enabled && !busy && !restoring && Date() > guardUntil else { return }
        guard system.missionControlRoot() == nil else { return }
        // Retry only newly created windows with incomplete AX/profile data,
        // for a bounded eight-second period. There is no steady-state poll.
        let deadline = Date().addingTimeInterval(-8)
        births = births.filter { $0.value > deadline }
        launching = launching.filter { $0.value > deadline }
        for window in new where window.group != nil { births[window.id] = nil }
        for pid in Array(launching.keys) {
            let candidates = new.filter { $0.pid == pid }
            if !candidates.isEmpty && candidates.allSatisfy({ $0.group != nil }) { launching[pid] = nil }
        }
        if !births.isEmpty || !launching.isEmpty { schedule(delay: 1, full: true) }
        if !manual.isEmpty {
            Task { await runOperation {
                var handled = Set<String>()
                for (window, destination) in manual {
                    guard let key = window.group, handled.insert(key).inserted else { continue }
                    self.record(window, on: destination)
                    try await self.moveGroup(key, to: destination)
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
        guard !locked, operationGeneration == generation else { throw AppError.message("Operacja przerwana po zmianie stanu systemu.") }
    }

    func name(_ desktop: Desktop) -> String {
        if let label = state.names[desktop.id], !label.isEmpty { return label }
        let labels = Set(windows.filter { $0.spaceIDs.contains(desktop.systemID) }.map { $0.profileName.map { "Chrome · \($0)" } ?? $0.appName })
        if !labels.isEmpty { return labels.sorted().prefix(2).joined(separator: " + ") }
        let assigned = state.assignments.filter { $0.desktopID == desktop.id }.map(\.label)
        return assigned.isEmpty ? "Biurko \(desktop.ordinal + 1)" : Array(Set(assigned)).sorted().prefix(2).joined(separator: " + ")
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
        state.enabled.toggle(); generation += 1; births.removeAll(); launching.removeAll()
        if !state.enabled { topologyTask?.cancel() }
        refresh(full: true)
        guardUntil = Date().addingTimeInterval(1)
        schedule(delay: 1.1, full: true)
        status = state.enabled ? "Automatyka aktywna · nowe okna" : "Automatyka wstrzymana"
        save()
    }

    func requestAccessibility() {
        checkAccessibility()
        if trusted { status = "Uprawnienie do sterowania oknami jest aktywne"; return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    var permissionName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Sterowanie urządzeniami i dostęp do danych" : "Dostępność"
    }

    func checkAccessibility() {
        refresh(full: true)
        writeRuntimeStatus()
        if !busy {
            status = trusted ? (state.enabled ? "Automatyka aktywna" : "Dostęp przyznany · automatyka wstrzymana") : "Brak dostępu dla tej uruchomionej kopii DeskPilot"
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
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard chromeModified == nil || modified != chromeModified else { return }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: Any] else { return }
        chromeProfiles = ChromeResolver.profiles(from: cache); chromeModified = modified
    }

    func setChromeProfile(windowID: UInt32, profile: ChromeProfile) {
        guard let w = windows.first(where: { $0.id == windowID && $0.appID == "com.google.Chrome" }) else { return }
        chromeBindings["\(w.pid):\(windowID)"] = profile
        refresh(full: true)
        status = "Rozpoznano profil \(profile.name) dla tego okna"
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
        guard let key = window.group else { throw AppError.message("Wskaż profil Chrome dla tego okna.") }
        if let id = temporaryTargets[key], let desktop = desktops.first(where: { $0.id == id && !$0.fullScreen }) { return desktop }
        let rule = state.assignments.first { $0.id == key }
        if let rule, let desktop = Policy.target(for: rule, desktops: desktops, displays: displays) { return desktop }
        let current = desktops.first { window.spaceIDs.contains($0.systemID) }
        guard let displayID = Policy.preferredDisplay(for: rule, current: current?.displayID, displays: displays),
              let display = displays.first(where: { $0.id == displayID }), let occupancy = system.occupancy() else { throw AppError.message("Brak wiarygodnego odczytu monitora lub okien.") }
        let groupWindows = Set(windows.filter { $0.group == key }.map(\.id))
        let reserved = Set(state.assignments.filter { $0.id != key }.map(\.desktopID))
        if let available = desktops.first(where: {
            !$0.fullScreen && $0.displayID == displayID && !reserved.contains($0.id) && (occupancy[$0.systemID] ?? []).subtracting(groupWindows).isEmpty
        }) { return available }
        let before = Set(desktops.map(\.id))
        status = "Tworzę biurko dla \(window.profileName ?? window.appName)…"
        try checkpoint()
        try await system.missionControl(display: display, create: true)
        try checkpoint()
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 150_000_000)
            if let current = system.spaces(displays: displays) {
                desktops = current
                if let created = current.first(where: { $0.displayID == displayID && !$0.fullScreen && !before.contains($0.id) }) { return created }
            }
        }
        throw AppError.message("macOS nie potwierdził utworzenia biurka.")
    }

    func runOperation(_ operation: () async throws -> Void) async {
        guard !busy && !locked && trusted && operational else {
            if !trusted { status = "Nadaj uprawnienie Dostępność" }
            return
        }
        busy = true; lastError = nil; operationGeneration = generation
        defer { operationGeneration = nil; busy = false; lastOwnMovement = Date(); schedule(full: true) }
        do { try await operation(); status = "Gotowe" }
        catch { fail(error) }
    }

    private func routeNew(_ incoming: [WindowInfo]) async {
        await runOperation {
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
            }
        }
    }

    func moveGroup(_ key: String, to desktop: Desktop) async throws {
        try checkpoint()
        let token = operationGeneration
        for window in windows.filter({ $0.group == key }) {
            guard !locked && token == generation else { throw AppError.message("Przerwano po zmianie stanu systemu.") }
            guard window.spaceIDs.count == 1,
                  desktops.contains(where: { $0.systemID == window.spaceIDs[0] && !$0.fullScreen }) else { continue }
            if window.spaceIDs[0] == desktop.systemID { continue }
            if let error = DPBeginMove(window.id, desktop.systemID) { throw AppError.message(error) }
            var confirmed = false
            for _ in 0..<24 {
                try await Task.sleep(nanoseconds: 125_000_000)
                if let actual = DPWindowSpaces(window.id) as? [NSNumber], actual.count == 1, actual[0].uint64Value == desktop.systemID { confirmed = true; break }
                if locked || token != generation { break }
            }
            DPEndMove()
            guard confirmed else {
                state.enabled = false; save()
                throw AppError.message("macOS nie potwierdził ruchu okna. Automatyka została wstrzymana.")
            }
            previous[window.id] = (window.pid, desktop.systemID)
        }
    }

    func assign(_ windowID: UInt32, to desktop: Desktop) {
        guard let w = windows.first(where: { $0.id == windowID }), let key = w.group else { status = "Najpierw rozpoznaj profil Chrome"; return }
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
            try await self.system.missionControl(display: display, select: desktop)
            for _ in 0..<15 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if self.system.spaces(displays: self.displays)?.contains(where: { $0.id == desktop.id && $0.active }) == true { return }
            }
            throw AppError.message("macOS nie potwierdził przejścia na biurko.")
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
        if system.setFrame(frame, windowID: windowID) { status = "Ułożono okno"; schedule(full: true) }
        else { status = "Aplikacja nie pozwoliła zmienić rozmiaru okna" }
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
        let profile = LayoutProfile(name: name.isEmpty ? "Układ \(state.profiles.count + 1)" : name,
                                    displayIDs: displays.map(\.id), assignments: rules, frames: frames, names: state.names)
        state.profiles.append(profile)
        if fallback { state.defaultProfileID = profile.id }
        state.assignments = rules; activeProfileID = profile.id; save(); status = "Zapisano profil „\(profile.name)”"
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
            guard !locked && token == generation else { throw AppError.message("Przywracanie przerwano po zmianie systemu.") }
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
        if missing > 0 { lastError = "Przywrócono dostępne okna. \(missing) zapisanych aplikacji lub profili nie ma otwartych okien." }
    }

    private func handleTopology() {
        generation += 1; guardUntil = Date().addingTimeInterval(5)
        births.removeAll(); launching.removeAll(); previous.removeAll(); temporaryTargets.removeAll()
        topologyTask?.cancel(); status = "Czekam na ustabilizowanie monitorów…"
        topologyTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard let self, !self.locked else { return }
            self.oldDisplaySignature = ""
            self.refresh(full: true)
            guard self.state.enabled, self.state.automaticProfiles else { self.status = "Monitory odczytane"; return }
            if let profile = Policy.profile(for: self.displays.map(\.id), state: self.state) {
                await self.runOperation { try await self.restoreProfile(profile) }
            } else {
                self.status = "Brak zapisanego profilu dla tego zestawu monitorów"
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
