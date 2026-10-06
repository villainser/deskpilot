import Foundation

@main struct CoreTests {
    static func main() throws {
        var total = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            total += 1
            guard condition() else { fatalError("FAILED: \(message)") }
        }
        let profiles = ChromeResolver.profiles(from: [
            "Default": ["name": "Work"], "Profile 1": ["name": "Home"],
            "Profile 2": ["name": "Adam", "gaia_given_name": "Adam", "is_using_default_name": true]
        ])
        check(ChromeResolver.resolve(title: "Document — Google Chrome — Work", profiles: profiles)?.id == "Default", "Profile suffix")
        check(ChromeResolver.resolve(title: "Work — Google Chrome", profiles: profiles) == nil, "Never infer a profile from a page title")
        check(ChromeResolver.resolve(title: "Google Chrome — Work — Google Chrome", profiles: profiles) == nil, "Only final browser marker counts")
        check(ChromeResolver.resolve(title: "Google Chrome — Unknown", profiles: profiles) == nil, "Unknown profile stays unresolved")
        check(ChromeResolver.resolve(title: "Google Chrome - Home", profiles: profiles)?.id == "Profile 1", "ASCII separator")
        check(ChromeResolver.resolve(title: "Google Chrome : Adam", profiles: profiles)?.id == "Profile 2", "Colon separator")
        let duplicates = [ChromeProfile(id: "A", name: "Work"), ChromeProfile(id: "B", name: "Work")]
        check(ChromeResolver.resolve(title: "Google Chrome — Work", profiles: duplicates) == nil, "Duplicate names never choose arbitrarily")
        let gaia = ChromeResolver.profiles(from: ["A": ["name": "Company", "gaia_given_name": "Ola", "is_using_default_name": false]])
        check(gaia.first?.name == "Ola (Company)", "Chrome composed profile names")
        check(ChromeResolver.resolve(title: "Google Chrome — Ola", profiles: gaia) == nil, "Gaia name is not an alias")
        let corporate = ChromeResolver.profiles(from: ["A": ["name": "Person 1", "enterprise_label": "Company", "gaia_name": "Ala", "is_using_default_name": true]])
        check(corporate.first?.name == "Ala (Company)", "Enterprise profile label")
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
        let solo = [ChromeProfile(id: "Default", name: "Personal")]
        check(ChromeResolver.resolve(title: "A page - Google Chrome", profiles: solo)?.id == "Default", "Single-profile Chrome omits its profile suffix")
        check(ChromeResolver.resolve(title: "A page - Google Chrome (Incognito)", profiles: solo) == nil, "Incognito must not inherit the sole regular profile")
        check(ChromeResolver.resolve(title: "A page - Google Chrome (Guest)", profiles: solo) == nil, "Guest must not inherit the sole regular profile")
        check(ChromeResolver.resolve(titles: ["Page - Google Chrome", "Page - Google Chrome (Incognito)"], profiles: solo) == nil, "A richer private-window title overrides a short title")
        check(ChromeResolver.resolve(titles: ["Page - Google Chrome", "Page - Google Chrome - Unknown"], profiles: solo) == nil, "Unknown explicit identity blocks a single-profile guess")
        check(ChromeResolver.resolve(title: "Personal", profiles: solo) == nil, "A page title alone is not profile evidence")
        check(ChromeResolver.resolve(title: "Page - Google Chrome - \u{2068}Work\u{2069}", profiles: profiles)?.id == "Default", "Normalize Unicode direction markers")
        check(ChromeResolver.resolve(title: "Page - Google Chrome - Ola\u{00a0}(Company)", profiles: gaia)?.id == "A", "Normalize profile whitespace")
        check(ChromeResolver.resolve(titles: ["Page", "Page - Google Chrome - Home"], profiles: profiles)?.id == "Profile 1", "Use the native root accessible window title")
        check(ChromeResolver.resolve(titles: ["Page - Google Chrome - Home", "Page - Google Chrome - Work"], profiles: profiles) == nil, "Conflicting accessible titles remain unresolved")
        var inbox = RoutingInbox()
        let now = Date(timeIntervalSince1970: 100)
        let identity = WindowIdentity(pid: 42, windowID: 1)
        inbox.enqueue(identity, now: now)
        check(inbox.needsRetry(now: now), "A new window is retried while its metadata arrives")
        inbox.reconcile(live: [identity], now: now.addingTimeInterval(30))
        check(!inbox.needsRetry(now: now.addingTimeInterval(30)) && !inbox.isEmpty, "Idle polling stops but late profile recognition remains possible")
        var pending = WindowInfo(id: 1, pid: 42, appID: "test", appName: "Editor", title: "Page", frame: .zero, spaceIDs: [], minimized: false)
        pending.group = "test"
        check(inbox.candidates(in: [pending]).isEmpty, "A window waits for a confirmed native Space")
        pending.spaceIDs = [9]
        check(inbox.candidates(in: [pending]).count == 1, "A pending window becomes eligible when native metadata arrives")
        check(inbox.candidates(in: [pending]).count == 1, "Reading candidates does not consume unconfirmed work")
        inbox.complete([identity])
        check(inbox.candidates(in: [pending]).isEmpty, "Only a completed route leaves the inbox")
        inbox.enqueue(identity, now: now)
        inbox.reconcile(live: [WindowIdentity(pid: 99, windowID: 1)], now: now.addingTimeInterval(30))
        check(inbox.isEmpty, "Reused window IDs from another process do not inherit a route")
        var chromeRule = rule; chromeRule.profileName = "Work"; chromeRule.appName = "Google Chrome"
        check(DesktopNaming.name(for: moved, customNames: [:], assignments: [chromeRule], windows: []) == "Work", "Desktop uses the Chrome profile name even after windows close")
        check(DesktopNaming.name(for: moved, customNames: [:], assignments: [rule], windows: []) == "App", "Desktop uses its assigned application name")
        check(DesktopNaming.name(for: moved, customNames: ["stable": "My desk"], assignments: [rule], windows: []) == "My desk", "Manual names take priority")
        check(DesktopNaming.name(for: moved, customNames: ["stable": "  "], assignments: [chromeRule], windows: []) == "Work", "Clearing a custom name restores automatic naming")
        final class Node {
            var role: String
            var title: String
            var children: [Node]
            init(_ role: String, _ title: String = "", _ children: [Node] = []) { self.role = role; self.title = title; self.children = children }
        }
        let browserRoot = Node("AXApplication")
        let nativeTitle = Node("AXGroup", "Page – Google Chrome – Work")
        let page = Node("AXWebArea", "Page – Google Chrome – Home", [Node("AXGroup", "Wrong profile")])
        let chromeWindow = Node("AXWindow", "Page", [Node("AXGroup", "", [Node("AXGroup", "", [nativeTitle])]), page])
        var nativeMode = false
        let exposed = ChromeAccessibility.windows(application: browserRoot, role: { node in nativeMode = true; return node.role }, read: { _ in nativeMode ? [chromeWindow] : nil })
        check(exposed?.count == 1, "Chrome application role is read before its windows to initialize native accessibility")
        var visitedWebContent = false
        let nativeTitles = ChromeAccessibility.windowTitles(window: chromeWindow, role: { $0.role }, strings: { node in
            if node.role == "AXWebArea" { visitedWebContent = true }; return [node.title]
        }, children: { node in
            if node.role == "AXWebArea" { visitedWebContent = true }; return node.children
        })
        check(ChromeResolver.resolve(titles: nativeTitles, profiles: profiles)?.id == "Default", "Nested native Chrome root supplies the actual profile title")
        check(!visitedWebContent && !nativeTitles.contains("Wrong profile"), "Chrome identity scan never enters page content")
        let cycle = Node("AXGroup"); cycle.children = [cycle]
        var reads = 0
        _ = ChromeAccessibility.windowTitles(window: cycle, role: { $0.role }, strings: { _ in reads += 1; return [] }, children: { $0.children })
        check(reads <= 5, "Native Chrome traversal is bounded even for a cyclic AX tree")
        let thumbnail = CGRect(x: 1100, y: 40, width: 180, height: 110)
        let badge = MissionControlLabelPolicy.frame(thumbnail: thumbnail, screen: CGRect(x: 1000, y: -200, width: 1500, height: 1000), primaryHeight: 800)
        check(badge?.minY == 654 && badge?.midX == 1190, "Mission Control badge converts AX coordinates on an offset external display")
        check(MissionControlLabelPolicy.frame(thumbnail: .zero, screen: display.frame, primaryHeight: 800) == nil, "Missing thumbnail geometry does not produce a guessed name position")
        let fullscreen = Desktop(id: "full", systemID: 10, displayID: "laptop", ordinal: 2, fullScreen: true, active: false)
        let pairs = MissionControlLabelPolicy.paired(desktops: [moved, fullscreen], frames: [.zero, thumbnail], displayID: "laptop")
        check(pairs.count == 1 && pairs[0].0.id == "stable" && pairs[0].1 == thumbnail, "Fullscreen thumbnail preserves ordinal alignment without receiving a desktop badge")
        check(MissionControlLabelPolicy.paired(desktops: [moved, fullscreen], frames: [thumbnail], displayID: "laptop").isEmpty, "Changing Mission Control list does not label the wrong desktop")
        final class MCNode {
            let id: String
            var screen: UInt32?
            var frame: CGRect?
            var children: [MCNode]
            init(_ id: String, screen: UInt32? = nil, frame: CGRect? = nil, children: [MCNode] = []) {
                self.id = id; self.screen = screen; self.frame = frame; self.children = children
            }
        }
        let emptyDock = MCNode("Dock", children: [MCNode("mc")])
        let mcScreen = MCNode("mc.display", screen: 1, frame: display.frame, children: [MCNode("mc.spaces", children: [MCNode("mc.spaces.list"), MCNode("mc.spaces.add")])])
        let windowManager = MCNode("WindowManager", children: [mcScreen])
        let mcRoot = MissionControlAccessibility.liveRoot(in: [emptyDock, windowManager], identifier: { $0.id }, children: { $0.children })
        check(mcRoot === windowManager, "An empty Dock mc stub is skipped in favor of WindowManager's live display tree")
        check(MissionControlAccessibility.liveRoot(in: [emptyDock], identifier: { $0.id }, children: { $0.children }) == nil, "An empty mc stub does not indefinitely block automatic routing")
        let legacyDock = MCNode("Dock", children: [MCNode("mc", children: [mcScreen])])
        check(MissionControlAccessibility.liveRoot(in: [legacyDock], identifier: { $0.id }, children: { $0.children }) === legacyDock, "The older Dock-hosted Mission Control tree remains supported")
        let incomplete = MCNode("WindowManager", children: [MCNode("mc.display")])
        check(MissionControlAccessibility.liveRoot(in: [incomplete], identifier: { $0.id }, children: { $0.children }) == nil, "A display without its Spaces controls is not ready for actions")
        let noID = MCNode("mc.display", frame: external.frame)
        func matched(_ candidates: [MCNode], _ target: Display) -> MCNode? {
            MissionControlAccessibility.display(in: candidates, targetID: target.systemID, targetFrame: target.frame, displayID: { $0.screen }, frame: { $0.frame })
        }
        check(matched([mcScreen, noID], display) === mcScreen, "The native display ID selects the correct Mission Control container")
        check(matched([mcScreen, noID], external) === noID, "Missing AXDisplayID falls back to the full display frame including menu bar and Dock")
        let wrongID = MCNode("mc.display", screen: 99, frame: external.frame)
        check(matched([wrongID], external) == nil, "Geometry never overrides a conflicting known display ID")
        check(matched([noID, MCNode("mc.display", frame: external.frame)], external) == nil, "Ambiguous display geometry does not select a monitor by guessing")
        let duplicateID = MCNode("mc.display", screen: 1, frame: external.frame)
        check(matched([mcScreen, duplicateID], display) == nil, "Duplicate display IDs during a transition do not choose arbitrarily")
        let shortFrame = MCNode("mc.display", frame: external.visibleFrame)
        check(matched([shortFrame], external) == nil, "A visible-frame-only match cannot misidentify a full display")
        let cycleMC = MCNode("cycle"); cycleMC.children = [cycleMC]
        var mcReads = 0
        _ = MissionControlAccessibility.displays(in: cycleMC, identifier: { $0.id }, children: { node in mcReads += 1; return node.children })
        check(mcReads <= 7, "Mission Control discovery terminates on a cyclic tree")
        print("PASS: \(total) core checks")
    }
}
