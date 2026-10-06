import Foundation
import CoreGraphics

struct Desktop: Identifiable, Equatable {
    let id: String
    let systemID: UInt64
    let displayID: String
    let ordinal: Int
    let fullScreen: Bool
    let active: Bool
}

struct Display: Identifiable, Equatable {
    let id: String
    let systemID: UInt32
    let name: String
    let builtIn: Bool
    let frame: CGRect
    let visibleFrame: CGRect
}

struct WindowInfo: Identifiable {
    let id: UInt32
    let pid: Int32
    let appID: String
    let appName: String
    let title: String
    var frame: CGRect
    var spaceIDs: [UInt64]
    let minimized: Bool
    var group: String?
    var profileName: String?
    var profileDirectory: String?
    var accessibilityTitles: [String] = []
    var identity: WindowIdentity { WindowIdentity(pid: pid, windowID: id) }
}

struct WindowIdentity: Hashable {
    let pid: Int32
    let windowID: UInt32
}

struct RoutingInbox {
    private(set) var pending: [WindowIdentity: Date] = [:]
    mutating func enqueue(_ identity: WindowIdentity, now: Date = Date()) {
        if pending[identity] == nil { pending[identity] = now.addingTimeInterval(12) }
    }
    mutating func reconcile(live: Set<WindowIdentity>, now: Date = Date()) {
        pending = pending.filter { live.contains($0.key) || $0.value > now }
    }
    func candidates(in windows: [WindowInfo]) -> [WindowInfo] {
        windows.filter { pending[$0.identity] != nil && $0.group != nil && $0.spaceIDs.count == 1 }
    }
    var isEmpty: Bool { pending.isEmpty }
    func needsRetry(now: Date = Date()) -> Bool { pending.values.contains { $0 > now } }
    mutating func complete(_ identities: [WindowIdentity]) { for identity in identities { pending[identity] = nil } }
    mutating func remove(_ identity: WindowIdentity) { pending[identity] = nil }
    mutating func clear() { pending.removeAll() }
}

enum DesktopNaming {
    static func name(for desktop: Desktop, customNames: [String: String], assignments: [Assignment], windows: [WindowInfo]) -> String {
        if let custom = customNames[desktop.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        // Assignments remain authoritative while apps are closed or AX data is delayed.
        let assigned = assignments.filter { $0.desktopID == desktop.id }.map { $0.profileName ?? $0.appName }
        let visible = windows.filter { $0.spaceIDs.contains(desktop.systemID) }.map { $0.profileName ?? $0.appName }
        let labels = Set(assigned.isEmpty ? visible : assigned).sorted()
        return labels.isEmpty ? "Desktop \(desktop.ordinal + 1)" : labels.joined(separator: " + ")
    }
}

struct Assignment: Codable, Identifiable, Equatable {
    var id: String
    var appID: String
    var appName: String
    var profileDirectory: String?
    var profileName: String?
    var desktopID: String
    var displayID: String
    var ordinal: Int
    var label: String { profileName.map { "Chrome · \($0)" } ?? appName }
}

struct RelativeFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    init(_ rect: CGRect, in screen: CGRect) {
        let w = max(screen.width, 1), h = max(screen.height, 1)
        x = (rect.minX - screen.minX) / w
        y = (rect.minY - screen.minY) / h
        width = rect.width / w; height = rect.height / h
    }
    func rect(in screen: CGRect) -> CGRect {
        let w = min(screen.width, max(160, width * screen.width))
        let h = min(screen.height, max(120, height * screen.height))
        return CGRect(x: min(max(screen.minX + x * screen.width, screen.minX), screen.maxX - w),
                      y: min(max(screen.minY + y * screen.height, screen.minY), screen.maxY - h), width: w, height: h)
    }
}

struct SavedWindow: Codable {
    var group: String
    var titleHash: String
    var frame: RelativeFrame
}

struct LayoutProfile: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var displayIDs: [String]
    var assignments: [Assignment]
    var frames: [SavedWindow]
    var names: [String: String]
    var updated = Date()
    var signature: String { displayIDs.sorted().joined(separator: "|") }
}

struct AppState: Codable {
    var schema = 1
    var enabled = false
    var automaticProfiles = true
    var launchMissingApps = false
    var names: [String: String] = [:]
    var assignments: [Assignment] = []
    var profiles: [LayoutProfile] = []
    var defaultProfileID: String?
}

struct ChromeProfile: Identifiable, Equatable {
    var id: String
    var name: String
}

enum ChromeResolver {
    static func profiles(from cache: [String: Any]) -> [ChromeProfile] {
        struct Entry { let dir: String; let local: String; let gaia: String; let enterprise: String; let defaultName: Bool }
        let entries = cache.compactMap { directory, value -> Entry? in
            guard let data = value as? [String: Any] else { return nil }
            let enterprise = data["enterprise_label"] as? String ?? ""
            let local = enterprise.isEmpty ? data["name"] as? String ?? "" : enterprise
            let gaia = ["gaia_given_name", "gaia_name", "oidc_identity_name"].compactMap { data[$0] as? String }.first { !$0.isEmpty } ?? ""
            guard !directory.isEmpty, !local.isEmpty else { return nil }
            return Entry(dir: directory, local: local, gaia: gaia, enterprise: enterprise, defaultName: data["is_using_default_name"] as? Bool == true)
        }
        return entries.map { e in
            var name = e.local
            if !e.gaia.isEmpty {
                if e.gaia.lowercased() == e.local.lowercased() { name = e.gaia }
                else {
                    let collision = entries.contains { $0.dir != e.dir && $0.gaia == e.gaia && ($0.defaultName || $0.gaia.lowercased() == $0.local.lowercased()) }
                    name = (!e.defaultName || !e.enterprise.isEmpty || collision) ? "\(e.gaia) (\(e.local))" : e.gaia
                }
            }
            return ChromeProfile(id: e.dir, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func resolve(title: String, profiles: [ChromeProfile]) -> ChromeProfile? {
        let title = normalized(title)
        guard let marker = title.range(of: "Google Chrome", options: .backwards) else { return nil }
        let tail = title[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        // Chromium omits the profile suffix when exactly one regular profile exists.
        // Incognito/Guest add a suffix, so they must never use this fallback.
        if tail.isEmpty { return profiles.count == 1 ? profiles[0] : nil }
        guard let first = tail.first, "-–—|:".contains(first) else { return nil }
        let name = tail.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = profiles.filter { normalized($0.name) == name }
        return matches.count == 1 ? matches[0] : nil
    }

    static func hasIdentitySuffix(_ title: String) -> Bool {
        let clean = normalized(title)
        guard let marker = clean.range(of: "Google Chrome", options: .backwards) else { return false }
        return !clean[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func resolve(titles: [String], profiles: [ChromeProfile]) -> ChromeProfile? {
        let annotated = titles.filter(hasIdentitySuffix)
        let candidates = annotated.isEmpty ? titles : annotated
        let matches = candidates.compactMap { resolve(title: $0, profiles: profiles) }
        // A richer native title (including Guest/Incognito/unknown identity)
        // must override the single-profile fallback from a shorter title.
        if !annotated.isEmpty && matches.count != annotated.count { return nil }
        return Set(matches.map(\.id)).count == 1 ? matches.first : nil
    }

    private static func normalized(_ text: String) -> String {
        let formatting = CharacterSet(charactersIn: "\u{200e}\u{200f}\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}\u{2066}\u{2067}\u{2068}\u{2069}")
        let clean = String(text.unicodeScalars.filter { !formatting.contains($0) }).precomposedStringWithCanonicalMapping
        return clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum Policy {
    static func profile(for displayIDs: [String], state: AppState) -> LayoutProfile? {
        let signature = displayIDs.sorted().joined(separator: "|")
        let matching = state.profiles.filter { $0.signature == signature }.sorted { $0.updated > $1.updated }
        if let exact = matching.first { return exact }
        if displayIDs.count == 1 { return state.profiles.first { $0.id == state.defaultProfileID } }
        return nil
    }

    static func target(for rule: Assignment, desktops: [Desktop], displays: [Display]) -> Desktop? {
        // Identity wins over monitor and position: a manual move of a whole
        // desktop must not be undone merely because its display changed.
        if let exact = desktops.first(where: { $0.id == rule.desktopID && !$0.fullScreen }) { return exact }
        return nil // Never select a possibly occupied desktop by a stale ordinal.
    }

    static func preferredDisplay(for rule: Assignment?, current: String?, displays: [Display]) -> String? {
        if let home = rule?.displayID, displays.contains(where: { $0.id == home }) { return home }
        if rule == nil, let current, displays.contains(where: { $0.id == current }) { return current }
        return displays.first(where: { $0.builtIn })?.id ?? displays.first?.id
    }
}
