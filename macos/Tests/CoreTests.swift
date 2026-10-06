import Foundation

@main struct CoreTests {
    static func main() throws {
        var total = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            total += 1
            guard condition() else { fatalError("FAILED: \(message)") }
        }
        let profiles = ChromeResolver.profiles(from: [
            "Default": ["name": "Praca"], "Profile 1": ["name": "Dom"],
            "Profile 2": ["name": "Adam", "gaia_given_name": "Adam", "is_using_default_name": true]
        ])
        check(ChromeResolver.resolve(title: "Dokument — Google Chrome — Praca", profiles: profiles)?.id == "Default", "Profile suffix")
        check(ChromeResolver.resolve(title: "Praca — Google Chrome", profiles: profiles) == nil, "Never infer a profile from a page title")
        check(ChromeResolver.resolve(title: "Google Chrome — Praca — Google Chrome", profiles: profiles) == nil, "Only final browser marker counts")
        check(ChromeResolver.resolve(title: "Google Chrome — Nieznany", profiles: profiles) == nil, "Unknown profile stays unresolved")
        check(ChromeResolver.resolve(title: "Google Chrome - Dom", profiles: profiles)?.id == "Profile 1", "ASCII separator")
        check(ChromeResolver.resolve(title: "Google Chrome : Adam", profiles: profiles)?.id == "Profile 2", "Colon separator")
        let duplicates = [ChromeProfile(id: "A", name: "Praca"), ChromeProfile(id: "B", name: "Praca")]
        check(ChromeResolver.resolve(title: "Google Chrome — Praca", profiles: duplicates) == nil, "Duplicate names never choose arbitrarily")
        let gaia = ChromeResolver.profiles(from: ["A": ["name": "Firma", "gaia_given_name": "Ola", "is_using_default_name": false]])
        check(gaia.first?.name == "Ola (Firma)", "Chrome composed profile names")
        check(ChromeResolver.resolve(title: "Google Chrome — Ola", profiles: gaia) == nil, "Gaia name is not an alias")
        let corporate = ChromeResolver.profiles(from: ["A": ["name": "Person 1", "enterprise_label": "Firma", "gaia_name": "Ala", "is_using_default_name": true]])
        check(corporate.first?.name == "Ala (Firma)", "Enterprise profile label")
        let display = Display(id: "laptop", systemID: 1, name: "Laptop", builtIn: true, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 30, width: 1000, height: 740))
        let external = Display(id: "external", systemID: 2, name: "External", builtIn: false, frame: CGRect(x: 1000, y: 0, width: 1500, height: 1000), visibleFrame: CGRect(x: 1000, y: 30, width: 1500, height: 940))
        let rule = Assignment(id: "app", appID: "app", appName: "App", desktopID: "stable", displayID: "external", ordinal: 0)
        let moved = Desktop(id: "stable", systemID: 9, displayID: "laptop", ordinal: 3, fullScreen: false, active: false)
        check(Policy.target(for: rule, desktops: [moved], displays: [display, external])?.systemID == 9, "Identity survives cross-display move and reordering")
        let unrelated = Desktop(id: "other", systemID: 1, displayID: "external", ordinal: 0, fullScreen: false, active: false)
        check(Policy.target(for: rule, desktops: [unrelated], displays: [display, external]) == nil, "Do not use stale ordinal")
        check(Policy.preferredDisplay(for: rule, current: nil, displays: [display]) == "laptop", "Disconnected display fallback")
        check(Policy.preferredDisplay(for: rule, current: "laptop", displays: [display, external]) == "external", "Reconnect honors home display")
        check(Policy.preferredDisplay(for: nil, current: "external", displays: [display, external]) == "external", "New app respects current display")
        let rect = RelativeFrame(CGRect(x: -2000, y: 0, width: 6000, height: 5000), in: display.visibleFrame).rect(in: external.visibleFrame)
        check(external.visibleFrame.contains(rect), "Restored frame is clamped to available monitor")
        let saved = RelativeFrame(CGRect(x: 0, y: 30, width: 500, height: 740), in: display.visibleFrame)
        check(saved.rect(in: external.visibleFrame).width == 750, "Geometry scales to a different resolution")
        var state = AppState()
        let fallback = LayoutProfile(name: "Laptop", displayIDs: ["laptop"], assignments: [rule], frames: [], names: [:])
        var matching = LayoutProfile(name: "Office", displayIDs: ["external", "laptop"], assignments: [], frames: [], names: [:])
        matching.updated = Date().addingTimeInterval(1)
        state.profiles = [fallback, matching]; state.defaultProfileID = fallback.id
        check(Policy.profile(for: ["laptop", "external"], state: state)?.id == matching.id, "Topology independent of enumeration order")
        check(Policy.profile(for: ["replacement"], state: state)?.id == fallback.id, "Default profile on one display")
        check(Policy.profile(for: ["unknown1", "unknown2"], state: state) == nil, "Unknown multi-display setup is not guessed")
        let roundtrip = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        check(roundtrip.profiles.count == 2 && roundtrip.defaultProfileID == fallback.id, "Persistence roundtrip")
        check(!AppState().enabled, "First launch must not rearrange existing work")
        print("PASS: \(total) core checks")
    }
}
