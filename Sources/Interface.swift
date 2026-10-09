import SwiftUI
import ServiceManagement

final class PanelState: ObservableObject {
    @Published var section = "Desktops"
    @Published var saveSheet = false
    @Published var profileName = ""
    @Published var fallback = false
    @Published var renaming: Desktop?
    @Published var newName = ""
}

struct RootView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var ui: PanelState

    let sections = [("Desktops", "rectangle.3.group"), ("Assignments", "pin"), ("Layouts", "display.2"), ("Settings", "slider.horizontal.3"), ("Diagnostics", "waveform.path.ecg")]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    if let icon = NSImage(named: "AppIcon") {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "rectangle.3.group.fill").font(.title).foregroundStyle(.teal)
                    }
                    VStack(alignment: .leading) { Text("DeskPilot").font(.title3.bold()); Text("VERSION \(appVersion)").font(.caption2.monospaced()).foregroundStyle(.secondary) }
                }.padding(.top, 22)
                VStack(spacing: 5) {
                    ForEach(sections, id: \.0) { item in
                        Button { ui.section = item.0 } label: {
                            Label(item.0, systemImage: item.1).font(.system(size: 14, weight: ui.section == item.0 ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                                .background(ui.section == item.0 ? Color.teal.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                HStack { Circle().fill(engine.state.enabled ? Color.green : .orange).frame(width: 7, height: 7); Text(engine.state.enabled ? "Automation enabled" : "Automation paused").font(.caption) }
                Button(engine.state.enabled ? "Pause" : "Enable automation") { engine.toggleEnabled() }.frame(maxWidth: .infinity)
                Text("⌃⌥ Space · show panel").font(.caption2).foregroundStyle(.secondary)
                Divider()
                Text("Closing the window keeps DeskPilot running. Quit stops the app.").font(.caption2).foregroundStyle(.secondary)
                Button("Quit DeskPilot", systemImage: "power") { NSApp.terminate(nil) }.frame(maxWidth: .infinity)
            }.padding(16).frame(width: 220).frame(maxHeight: .infinity).background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            Group {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ui.section).font(.system(size: 27, weight: .bold))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if engine.busy { ProgressView().controlSize(.small) }
                    if ui.section == "Desktops" || ui.section == "Layouts" {
                        Button("Save layout", systemImage: "square.and.arrow.down") { ui.profileName = ""; ui.saveSheet = true }.disabled(!engine.trusted || engine.busy)
                    }
                }.padding(26)
                if !engine.trusted {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Allow DeskPilot to manage windows").bold()
                            Text("Privacy & Security → \(engine.permissionName). Enable DeskPilot, then return here.").font(.caption)
                            Text("If access is enabled but unavailable after an update, remove the existing entry and add this application again.").font(.caption).foregroundStyle(.secondary)
                            Button("Show this app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }.font(.caption)
                        }
                        Spacer()
                        Button("Grant access") { engine.requestAccessibility() }
                        Button("Check access") { engine.checkAccessibility() }
                    }.padding(15).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 26).padding(.bottom, 15)
                }
                if let error = engine.lastError {
                    HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle"); Text(error).font(.callout); Spacer(); Button { engine.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .padding(13).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 26).padding(.bottom, 12)
                }
                if !engine.state.enabled, let reason = engine.state.automationPauseReason, reason != engine.lastError {
                    Text("Automation paused: \(reason)").font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(13)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 26).padding(.bottom, 12)
                }
                ScrollView {
                    Group {
                        switch ui.section {
                        case "Desktops": desktopPage
                        case "Assignments": assignmentPage
                        case "Layouts": profilePage
                        case "Settings": settingsPage
                        default: diagnosticPage
                        }
                    }.padding(.horizontal, 26).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack { Text(engine.status).lineLimit(1); Spacer(); Text("\(engine.displays.count) displays · \(engine.desktops.filter { !$0.fullScreen }.count) desktops").foregroundStyle(.secondary) }
                    .font(.caption).padding(.horizontal, 22).padding(.vertical, 12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        }
        .sheet(isPresented: $ui.saveSheet) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Save your layout").font(.title2.bold())
                Text("Save app assignments, Chrome profiles and window sizes for the connected displays.").foregroundStyle(.secondary)
                TextField("For example, Office or Laptop", text: $ui.profileName).textFieldStyle(.roundedBorder)
                Toggle("Use as the default layout with one display", isOn: $ui.fallback)
                HStack { Spacer(); Button("Cancel") { ui.saveSheet = false }; Button("Save") { engine.saveProfile(name: ui.profileName, fallback: ui.fallback); ui.saveSheet = false }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 440)
        }
        .sheet(item: $ui.renaming) { desktop in
            VStack(alignment: .leading, spacing: 18) {
                Text("Desktop name").font(.title2.bold())
                TextField("Leave empty to name automatically", text: $ui.newName).textFieldStyle(.roundedBorder)
                Text("The name appears in DeskPilot, the menu bar and Mission Control badges when enabled. Reordering desktops preserves their names.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Cancel") { ui.renaming = nil }; Button("Save") { engine.rename(desktop, to: ui.newName); ui.renaming = nil }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 430)
        }
        .frame(minWidth: 920, minHeight: 650)
    }

    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }

    var subtitle: String {
        switch ui.section {
        case "Desktops": return "Your macOS desktops, organized by display."
        case "Assignments": return "Keep apps in their assigned places. Manual changes take priority."
        case "Layouts": return "Save layouts for your desk and your laptop."
        case "Settings": return "Choose how DeskPilot works."
        default: return "System events trigger updates when something changes."
        }
    }

    var desktopPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            if engine.chromeProfiles.isEmpty && engine.windows.contains(where: { $0.appID == "com.google.Chrome" }) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect Chrome profiles to recognize these windows").bold()
                        Text(engine.chromeCatalogStatus).font(.caption).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Connect Chrome profiles…") { engine.connectChromeProfiles() }.disabled(engine.choosingChromeCatalog)
                }.padding(14).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Text("New apps and Chrome profiles get their own desktops. Organize existing windows here.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Organize now", systemImage: "sparkles") { engine.organize() }.disabled(!engine.trusted || engine.busy)
            }
            Text("Press ⌃ Space to choose a desktop and bring one window here. Press a number or click its row. Open the same picker to return individual windows home.").font(.callout).foregroundStyle(.secondary)
            if !(engine.state.borrowedWindows ?? []).isEmpty {
                GroupBox("Summoned windows") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(engine.windows.filter { engine.borrowed($0) != nil }) { w in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(w.profileName.map { "Chrome · \($0)" } ?? w.appName).bold()
                                    Text(w.title.isEmpty ? "Application window" : w.title).lineLimit(1).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Return home") { engine.sendBack(w.id) }.disabled(engine.busy)
                            }
                        }
                        Text("Each window keeps its original desktop and size, including after restarting DeskPilot. Automation and layout restoration leave it here until you return it.").font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
            }
            ForEach(engine.displays) { display in
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Image(systemName: display.builtIn ? "laptopcomputer" : "display").foregroundStyle(.teal); Text(display.name).font(.headline); Spacer(); Text(display.builtIn ? "Built-in" : "External").font(.caption).foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 265), spacing: 14)], spacing: 14) {
                        ForEach(engine.desktops.filter { $0.displayID == display.id }) { desktop in desktopCard(desktop) }
                    }
                }
            }
            if engine.desktops.isEmpty { empty("No desktops available", "Grant window management access and refresh.", "rectangle.3.group") }
        }
    }

    func desktopCard(_ desktop: Desktop) -> some View {
        let rows = engine.windows.filter { $0.spaceIDs.contains(desktop.systemID) }
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(engine.number(desktop)).font(.system(.caption, design: .monospaced).bold()).padding(6).background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text(engine.name(desktop)).font(.headline).lineLimit(1).help(engine.name(desktop))
                Spacer()
                if desktop.active { Circle().fill(.teal).frame(width: 7, height: 7) }
                Button { ui.newName = engine.state.names[desktop.id] ?? ""; ui.renaming = desktop } label: { Image(systemName: "pencil") }.buttonStyle(.plain).disabled(desktop.fullScreen).help("Rename desktop")
            }
            if rows.isEmpty { Text(!engine.trusted ? "Grant access to see windows" : (desktop.fullScreen ? "macOS full screen" : "No recognized windows")).foregroundStyle(.tertiary).font(.callout).frame(height: 66) }
            ForEach(rows.prefix(5)) { w in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: w.appID == "com.google.Chrome" ? "globe" : "macwindow").foregroundStyle(.secondary).frame(width: 17)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.profileName.map { "Chrome · \($0)" } ?? w.appName).font(.callout.weight(.medium)).lineLimit(1)
                        if w.appID == "com.google.Chrome" && w.group == nil {
                            Menu("Choose profile…") { ForEach(engine.chromeProfiles) { p in Button(p.name) { engine.setChromeProfile(windowID: w.id, profile: p) } } }.font(.caption)
                        } else { Text(w.title.isEmpty ? "Application window" : w.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    Menu {
                        if engine.borrowed(w) != nil {
                            Button("Return home") { engine.sendBack(w.id) }
                            Divider()
                        }
                        Button("Left half") { engine.tile(windowID: w.id, side: "left") }
                        Button("Right half") { engine.tile(windowID: w.id, side: "right") }
                        Button("Fill display") { engine.tile(windowID: w.id, side: "fill") }
                        Divider()
                        ForEach(engine.desktops.filter { !$0.fullScreen }) { d in
                            Button("\(engine.hasOtherGroups(on: d, than: w.group ?? "") ? "Share" : "Move to") \(engine.name(d))") { engine.assign(w.id, to: d, allowSharing: true) }
                        }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20).disabled(engine.busy)
                }
            }
            if rows.count > 5 { Text("+ \(rows.count - 5) more windows").font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("Go to") { engine.switchTo(desktop) }.disabled(!engine.trusted || engine.busy || desktop.active)
                Button("Summon next") { engine.summon(desktop) }.disabled(!engine.trusted || engine.busy || desktop.fullScreen)
                Spacer()
                Menu("Share desktop") {
                    ForEach(uniqueWindows) { window in
                        Button(window.profileName.map { "Chrome · \($0)" } ?? window.appName) { engine.assign(window.id, to: desktop, allowSharing: true) }
                    }
                }.disabled(engine.busy || desktop.fullScreen || uniqueWindows.isEmpty)
            }.controlSize(.small)
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(desktop.active ? Color.teal.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1))
            .contextMenu {
                Button("Rename desktop…") { ui.newName = engine.state.names[desktop.id] ?? ""; ui.renaming = desktop }.disabled(desktop.fullScreen)
                Button("Use automatic name") { engine.rename(desktop, to: "") }.disabled(desktop.fullScreen || engine.state.names[desktop.id] == nil)
            }
    }

    var uniqueWindows: [WindowInfo] {
        var seen = Set<String>()
        return engine.windows.filter { w in guard let group = w.group else { return false }; return seen.insert(group).inserted }.sorted { $0.appName < $1.appName }
    }

    var assignmentPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if engine.state.assignments.isEmpty { empty("Your assignments appear here", "Choose Organize now or add an app to a desktop.", "pin") }
            ForEach(engine.state.assignments) { rule in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.label).font(.headline)
                        let desktop = engine.desktops.first { $0.id == rule.desktopID }
                        Text(desktop.map { engine.name($0) } ?? "Assigned desktop is unavailable").font(.callout).foregroundStyle(.secondary)
                        Text(engine.displays.first { $0.id == rule.displayID }?.name ?? "Display disconnected").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Change desktop") {
                        ForEach(engine.desktops.filter { !$0.fullScreen }) { d in
                            Button("\(engine.hasOtherGroups(on: d, than: rule.id) ? "Share " : "")\(engine.name(d))") {
                                if let w = engine.windows.first(where: { $0.group == rule.id }) { engine.assign(w.id, to: d, allowSharing: true) }
                                else { engine.assignSavedGroup(rule.id, to: d) }
                            }
                        }
                    }.frame(width: 145)
                    Button { engine.state.assignments.removeAll { $0.id == rule.id }; engine.save() } label: { Image(systemName: "pin.slash") }.help("Remove assignment")
                }.padding(17).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Apps stay on their assigned desktops. Use Share desktop to place apps together. Dragging an individual window does not change its assignment; reordering whole desktops in Mission Control preserves it.").font(.callout).foregroundStyle(.secondary)
        }
    }

    var profilePage: some View {
        VStack(alignment: .leading, spacing: 15) {
            if engine.state.profiles.isEmpty { empty("Save your first layout", "Arrange your windows and choose Save layout. Keep a separate layout for each display setup.", "display.2") }
            ForEach(engine.state.profiles) { profile in
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(profile.name).font(.title3.bold()); if engine.activeProfileID == profile.id { Text("ACTIVE").font(.caption2.bold()).foregroundStyle(.teal) }; Spacer(); Text(profile.updated, style: .date).foregroundStyle(.secondary).font(.caption) }
                    Text("\(profile.displayIDs.count) displays · \(profile.assignments.count) apps and profiles · \(profile.frames.count) windows").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Restore layout") { engine.restore(profile) }.disabled(engine.busy || !engine.trusted)
                        Button(engine.state.defaultProfileID == profile.id ? "Single-display default ✓" : "Set as default") { engine.state.defaultProfileID = profile.id; engine.save() }
                        Spacer()
                        Button(role: .destructive) { engine.removeProfile(profile.id) } label: { Image(systemName: "trash") }.help("Delete saved layout")
                    }
                }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            }
            Toggle("Restore a layout when displays change", isOn: Binding(get: { engine.state.automaticProfiles }, set: { engine.state.automaticProfiles = $0; engine.save() }))
            Text("DeskPilot selects the most recently saved layout for matching displays. With one display, it uses a matching layout or your default. Restoration waits for displays to settle.").font(.callout).foregroundStyle(.secondary)
        }
    }

    var settingsPage: some View {
        VStack(alignment: .leading, spacing: 25) {
            GroupBox("Behavior") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Automatically assign apps and profiles", isOn: Binding(get: { engine.state.enabled }, set: { _ in engine.toggleEnabled() }))
                    Text("Enabling automation organizes open windows and handles new ones as they appear.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Activate windows under the pointer", isOn: Binding(get: { engine.state.focusFollowsMouse ?? true }, set: { engine.state.focusFollowsMouse = $0; engine.save() }))
                    Text("Hover briefly over a window to activate it before clicking. Paused while dragging, holding modifier keys or using DeskPilot's panel.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Arrange shared windows side by side", isOn: Binding(get: { engine.state.autoTileSharedWindows ?? true }, set: { engine.state.autoTileSharedWindows = $0; engine.save() }))
                    Text("After sharing or summoning, two visible windows from different apps or profiles split the display. Additional windows keep their positions.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Launch missing apps when restoring a layout", isOn: Binding(get: { engine.state.launchMissingApps }, set: { engine.state.launchMissingApps = $0; engine.save() }))
                    Text("Launching an app does not restore closed documents or browser tabs.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Start DeskPilot at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { engine.setLogin($0) }))
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Keyboard shortcuts") {
                VStack(spacing: 13) {
                    shortcut("Bring or return a window", "⌃ Space, then choose")
                    shortcut("Show / hide panel", "⌃⌥ Space")
                    shortcut("Switch to desktop 1–9", "⌃⌥ 1…9")
                    shortcut("Move app to desktop 1–9", "⌃⌥⇧ 1…9")
                    shortcut("Summon next window from desktop 1–9", "⌃⌥⌘ 1…9")
                    shortcut("Return focused window home", "⌃⌥⌘ Delete")
                    shortcut("Left / right half", "⌃⌥ ← / →")
                    shortcut("Pause / resume", "⌃⌥ P")
                }.padding(14)
            }
            GroupBox("macOS integration") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("In System Settings → Desktop & Dock, turn off automatic Space reordering and enable Displays have separate Spaces.")
                    Button("Open Desktop & Dock") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!) }
                }.font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var diagnosticPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 15) { metric("Refreshes", String(engine.refreshes)); metric("Events", String(engine.events)); metric("Last read", String(format: "%.1f ms", engine.lastReadMilliseconds)) }
            GroupBox("System access") {
                VStack(spacing: 13) {
                    shortcut("Window management access", engine.trusted ? "Granted" : "Required")
                    shortcut("Window movement", engine.system.canMove ? "Available · verified on each move" : "Unavailable")
                    shortcut("Chrome profiles in catalog", engine.chromeCatalogCountLabel)
                    Text(engine.chromeCatalogStatus).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Connect Chrome profiles…") { engine.connectChromeProfiles() }.disabled(engine.choosingChromeCatalog)
                    Text(engine.chromeConnectionStatus).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    shortcut("Chrome windows found", String(engine.windows.filter { $0.appID == "com.google.Chrome" }.count))
                    shortcut("Chrome windows with a known profile", String(engine.windows.filter { $0.appID == "com.google.Chrome" && $0.group != nil }.count))
                    shortcut("Window routing idle polling", "Off")
                    shortcut("Mission Control overlays", "Off")
                    shortcut("Screen previews", "Not used")
                }.padding(15)
            }
            Text("The read counter should stop when nothing changes. Available means the system function exists. Every window move is confirmed separately.").foregroundStyle(.secondary)
            Button("Refresh and check access") { engine.checkAccessibility(retryChromeCatalog: true) }
            Text("Application: \(Bundle.main.bundleURL.path)").font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
            Text("Version \(appVersion) · data stays on this Mac").font(.caption).foregroundStyle(.secondary)
        }
    }

    func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)) }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
    func shortcut(_ label: String, _ value: String) -> some View { HStack { Text(label); Spacer(); Text(value).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary) } }
    func empty(_ title: String, _ detail: String, _ icon: String) -> some View { VStack(spacing: 13) { Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.teal); Text(title).font(.title3.bold()); Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420) }.padding(45).frame(maxWidth: .infinity) }
}
