import SwiftUI
import ServiceManagement

final class PanelState: ObservableObject {
    @Published var section = "Biurka"
    @Published var saveSheet = false
    @Published var profileName = ""
    @Published var fallback = false
    @Published var renaming: Desktop?
    @Published var newName = ""
}

struct RootView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var ui: PanelState

    let sections = [("Biurka", "rectangle.3.group"), ("Przypisania", "pin"), ("Profile", "display.2"), ("Ustawienia", "slider.horizontal.3"), ("Diagnostyka", "waveform.path.ecg")]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    if let icon = NSImage(named: "AppIcon") {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "rectangle.3.group.fill").font(.title).foregroundStyle(.teal)
                    }
                    VStack(alignment: .leading) { Text("DeskPilot").font(.title3.bold()); Text("NATIVE · 0.1.2").font(.caption2.monospaced()).foregroundStyle(.secondary) }
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
                HStack { Circle().fill(engine.state.enabled ? Color.green : .orange).frame(width: 7, height: 7); Text(engine.state.enabled ? "Automatyka aktywna" : "Automatyka wstrzymana").font(.caption) }
                Button(engine.state.enabled ? "Wstrzymaj" : "Włącz automatykę") { engine.toggleEnabled() }.frame(maxWidth: .infinity)
                Text("⌃⌥ spacja · otwórz panel").font(.caption2).foregroundStyle(.secondary)
                Divider()
                Text("„X” chowa panel. Zakończenie wyłącza całą aplikację.").font(.caption2).foregroundStyle(.secondary)
                Button("Zakończ DeskPilot", systemImage: "power") { NSApp.terminate(nil) }.frame(maxWidth: .infinity)
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
                    if ui.section == "Biurka" || ui.section == "Profile" {
                        Button("Zapisz profil", systemImage: "square.and.arrow.down") { ui.profileName = ""; ui.saveSheet = true }.disabled(!engine.trusted || engine.busy)
                    }
                }.padding(26)
                if !engine.trusted {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Pozwól DeskPilot zarządzać oknami").bold()
                            Text("Prywatność i ochrona → \(engine.permissionName). Włącz DeskPilot Native i wróć do panelu.").font(.caption)
                            Text("Jeśli przełącznik już jest włączony: po aktualizacji usuń stary wpis i dodaj tę kopię aplikacji ponownie.").font(.caption).foregroundStyle(.secondary)
                            Button("Pokaż tę kopię w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }.font(.caption)
                        }
                        Spacer()
                        Button("Nadaj dostęp") { engine.requestAccessibility() }
                        Button("Sprawdź dostęp") { engine.checkAccessibility() }
                    }.padding(15).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 26).padding(.bottom, 15)
                }
                if let error = engine.lastError {
                    HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle"); Text(error).font(.callout); Spacer(); Button { engine.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .padding(13).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 26).padding(.bottom, 12)
                }
                ScrollView {
                    Group {
                        switch ui.section {
                        case "Biurka": desktopPage
                        case "Przypisania": assignmentPage
                        case "Profile": profilePage
                        case "Ustawienia": settingsPage
                        default: diagnosticPage
                        }
                    }.padding(.horizontal, 26).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack { Text(engine.status).lineLimit(1); Spacer(); Text("\(engine.displays.count) ekran(y) · \(engine.desktops.filter { !$0.fullScreen }.count) biurek").foregroundStyle(.secondary) }
                    .font(.caption).padding(.horizontal, 22).padding(.vertical, 12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        }
        .sheet(isPresented: $ui.saveSheet) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Zapisz układ pracy").font(.title2.bold())
                Text("Zapamiętaj biurka aplikacji, profile Chrome i rozmiary okien dla podłączonych monitorów.").foregroundStyle(.secondary)
                TextField("Np. Biuro albo Sam laptop", text: $ui.profileName).textFieldStyle(.roundedBorder)
                Toggle("Użyj jako układu domyślnego przy jednym ekranie", isOn: $ui.fallback)
                HStack { Spacer(); Button("Anuluj") { ui.saveSheet = false }; Button("Zapisz") { engine.saveProfile(name: ui.profileName, fallback: ui.fallback); ui.saveSheet = false }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 440)
        }
        .sheet(item: $ui.renaming) { desktop in
            VStack(alignment: .leading, spacing: 18) {
                Text("Nazwa biurka").font(.title2.bold())
                TextField("Zostaw puste, aby nazwać według aplikacji", text: $ui.newName).textFieldStyle(.roundedBorder)
                Text("Nazwa pojawi się w DeskPilot i na pasku menu. Biurko zachowuje tożsamość po ręcznej zmianie kolejności.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Anuluj") { ui.renaming = nil }; Button("Zapisz") { engine.rename(desktop, to: ui.newName); ui.renaming = nil }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 430)
        }
        .frame(minWidth: 920, minHeight: 650)
    }

    var subtitle: String {
        switch ui.section {
        case "Biurka": return "Twoje prawdziwe biurka macOS, uporządkowane według ekranów."
        case "Przypisania": return "Aplikacje mają swoje miejsca. Ręczna zmiana ma pierwszeństwo."
        case "Profile": return "Inny układ w biurze, inny na samym laptopie."
        case "Ustawienia": return "Ustal, kiedy DeskPilot ma działać."
        default: return "Odczyty wywoływane zdarzeniami, bez stałego skanowania."
        }
    }

    var desktopPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Nowe aplikacje mogą otrzymywać własne biurka. Istniejący układ uporządkujesz tym przyciskiem.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Organizuj teraz", systemImage: "sparkles") { engine.organize() }.disabled(!engine.trusted || engine.busy)
            }
            ForEach(engine.displays) { display in
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Image(systemName: display.builtIn ? "laptopcomputer" : "display").foregroundStyle(.teal); Text(display.name).font(.headline); Spacer(); Text(display.builtIn ? "Wbudowany" : "Zewnętrzny").font(.caption).foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 265), spacing: 14)], spacing: 14) {
                        ForEach(engine.desktops.filter { $0.displayID == display.id }) { desktop in desktopCard(desktop) }
                    }
                }
            }
            if engine.desktops.isEmpty { empty("Nie odczytano jeszcze biurek", "Nadaj uprawnienie Dostępność i odśwież odczyt.", "rectangle.3.group") }
        }
    }

    func desktopCard(_ desktop: Desktop) -> some View {
        let rows = engine.windows.filter { $0.spaceIDs.contains(desktop.systemID) }
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(String(desktop.ordinal + 1)).font(.system(.caption, design: .monospaced).bold()).padding(6).background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text(engine.name(desktop)).font(.headline).lineLimit(1)
                Spacer()
                if desktop.active { Circle().fill(.teal).frame(width: 7, height: 7) }
                Button { ui.newName = engine.state.names[desktop.id] ?? ""; ui.renaming = desktop } label: { Image(systemName: "pencil") }.buttonStyle(.plain).disabled(desktop.fullScreen)
            }
            if rows.isEmpty { Text(!engine.trusted ? "Okna widoczne po nadaniu dostępu" : (desktop.fullScreen ? "Pełny ekran macOS" : "Brak rozpoznanych okien")).foregroundStyle(.tertiary).font(.callout).frame(height: 66) }
            ForEach(rows.prefix(5)) { w in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: w.appID == "com.google.Chrome" ? "globe" : "macwindow").foregroundStyle(.secondary).frame(width: 17)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.profileName.map { "Chrome · \($0)" } ?? w.appName).font(.callout.weight(.medium)).lineLimit(1)
                        if w.appID == "com.google.Chrome" && w.group == nil {
                            Menu("Wskaż profil…") { ForEach(engine.chromeProfiles) { p in Button(p.name) { engine.setChromeProfile(windowID: w.id, profile: p) } } }.font(.caption)
                        } else { Text(w.title.isEmpty ? "Okno aplikacji" : w.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Lewa połowa") { engine.tile(windowID: w.id, side: "left") }
                        Button("Prawa połowa") { engine.tile(windowID: w.id, side: "right") }
                        Button("Wypełnij ekran") { engine.tile(windowID: w.id, side: "fill") }
                        Divider()
                        ForEach(engine.desktops.filter { !$0.fullScreen }) { d in
                            Button("Przenieś na \(engine.name(d))") { engine.assign(w.id, to: d) }
                        }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20).disabled(engine.busy)
                }
            }
            if rows.count > 5 { Text("+ \(rows.count - 5) kolejnych okien").font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("Przejdź") { engine.switchTo(desktop) }.disabled(!engine.trusted || engine.busy || desktop.active)
                Spacer()
                Menu("Dodaj aplikację") {
                    ForEach(uniqueWindows) { window in
                        Button(window.profileName.map { "Chrome · \($0)" } ?? window.appName) { engine.assign(window.id, to: desktop) }
                    }
                }.disabled(engine.busy || desktop.fullScreen || uniqueWindows.isEmpty)
            }.controlSize(.small)
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(desktop.active ? Color.teal.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1))
    }

    var uniqueWindows: [WindowInfo] {
        var seen = Set<String>()
        return engine.windows.filter { w in guard let group = w.group else { return false }; return seen.insert(group).inserted }.sorted { $0.appName < $1.appName }
    }

    var assignmentPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if engine.state.assignments.isEmpty { empty("Przypisania pojawią się tutaj", "Wybierz „Organizuj teraz” lub dodaj aplikację do wybranego biurka.", "pin") }
            ForEach(engine.state.assignments) { rule in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.label).font(.headline)
                        let desktop = engine.desktops.first { $0.id == rule.desktopID }
                        Text(desktop.map { engine.name($0) } ?? "Zapisane biurko chwilowo niedostępne").font(.callout).foregroundStyle(.secondary)
                        Text(engine.displays.first { $0.id == rule.displayID }?.name ?? "Monitor odłączony").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Zmień biurko") {
                        ForEach(engine.desktops.filter { !$0.fullScreen }) { d in
                            Button(engine.name(d)) {
                                if let w = engine.windows.first(where: { $0.group == rule.id }) { engine.assign(w.id, to: d) }
                                else if let index = engine.state.assignments.firstIndex(where: { $0.id == rule.id }) {
                                    engine.state.assignments[index].desktopID = d.id; engine.state.assignments[index].displayID = d.displayID; engine.state.assignments[index].ordinal = d.ordinal; engine.save()
                                }
                            }
                        }
                    }.frame(width: 145)
                    Button { engine.state.assignments.removeAll { $0.id == rule.id }; engine.save() } label: { Image(systemName: "pin.slash") }.help("Usuń przypisanie")
                }.padding(17).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Przypisanie dotyczy całej aplikacji albo jednego profilu Chrome. Kilka aplikacji może współdzielić biurko. Zmiana kolejności całych biurek w Mission Control nie zmienia ich przypisań.").font(.callout).foregroundStyle(.secondary)
        }
    }

    var profilePage: some View {
        VStack(alignment: .leading, spacing: 15) {
            if engine.state.profiles.isEmpty { empty("Zapisz pierwszy profil", "Ułóż okna i kliknij „Zapisz profil”. Możesz zachować osobny układ dla każdego zestawu monitorów.", "display.2") }
            ForEach(engine.state.profiles) { profile in
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(profile.name).font(.title3.bold()); if engine.activeProfileID == profile.id { Text("AKTYWNY").font(.caption2.bold()).foregroundStyle(.teal) }; Spacer(); Text(profile.updated, style: .date).foregroundStyle(.secondary).font(.caption) }
                    Text("\(profile.displayIDs.count) ekran(y) · \(profile.assignments.count) aplikacji i profili · \(profile.frames.count) okien").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Przywróć układ") { engine.restore(profile) }.disabled(engine.busy || !engine.trusted)
                        Button(engine.state.defaultProfileID == profile.id ? "Domyślny przy jednym ekranie ✓" : "Ustaw jako domyślny") { engine.state.defaultProfileID = profile.id; engine.save() }
                        Spacer()
                        Button(role: .destructive) { engine.removeProfile(profile.id) } label: { Image(systemName: "trash") }.help("Usuń zapisany profil")
                    }
                }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            }
            Toggle("Automatycznie przywracaj profil po zmianie monitorów", isOn: Binding(get: { engine.state.automaticProfiles }, set: { engine.state.automaticProfiles = $0; engine.save() }))
            Text("Dla identycznego zestawu ekranów wybierany jest ostatnio zapisany profil. Gdy pozostaje jeden ekran, używany jest dopasowany profil, a w jego braku profil domyślny. Przywracanie czeka, aż monitory się ustabilizują.").font(.callout).foregroundStyle(.secondary)
        }
    }

    var settingsPage: some View {
        VStack(alignment: .leading, spacing: 25) {
            GroupBox("Zachowanie") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Przypisuj nowe aplikacje i profile do biurek", isOn: Binding(get: { engine.state.enabled }, set: { _ in engine.toggleEnabled() }))
                    Toggle("Przy odtwarzaniu profilu uruchamiaj brakujące aplikacje", isOn: Binding(get: { engine.state.launchMissingApps }, set: { engine.state.launchMissingApps = $0; engine.save() }))
                    Text("Otwarcie programu nie gwarantuje odtworzenia zamkniętych dokumentów lub kart przeglądarki.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Uruchamiaj DeskPilot przy logowaniu", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { engine.setLogin($0) }))
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Proste skróty") {
                VStack(spacing: 13) {
                    shortcut("Pokaż / schowaj panel", "⌃⌥ spacja")
                    shortcut("Przejdź na biurko 1–9", "⌃⌥ 1…9")
                    shortcut("Przenieś aplikację na biurko 1–9", "⌃⌥⇧ 1…9")
                    shortcut("Lewa / prawa połowa okna", "⌃⌥ ← / →")
                    shortcut("Wstrzymaj / wznów", "⌃⌥ P")
                }.padding(14)
            }
            GroupBox("Integracja z macOS") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Mission Control i gesty macOS pozostają dostępne. Nazwy DeskPilot są widoczne w panelu i na pasku menu; systemowe etykiety „Biurko 1” pozostają etykietami macOS.")
                    Text("W Ustawieniach systemowych → Biurko i Dock wyłącz „Automatycznie porządkuj przestrzenie według czasu ostatniego użycia” i włącz „Monitory mają osobne przestrzenie”.")
                    Button("Otwórz Biurko i Dock") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!) }
                    Text("Równoczesne uruchomienie starego DeskPilot w Hammerspoonie może powodować sprzeczne ruchy. Wstrzymaj starą automatykę przed włączeniem nowej.").foregroundStyle(.secondary)
                }.font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var diagnosticPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 15) { metric("Odczyty", String(engine.refreshes)); metric("Zdarzenia", String(engine.events)); metric("Ostatni odczyt", String(format: "%.1f ms", engine.lastReadMilliseconds)) }
            GroupBox("Stan integracji") {
                VStack(spacing: 13) {
                    shortcut("Dostęp do sterowania oknami", engine.trusted ? "Przyznany" : "Wymagany")
                    shortcut("Mechanizm ruchu okien", engine.system.canMove ? "Dostępny · wymaga testu ruchu" : "Niedostępny")
                    shortcut("Rozpoznane profile Chrome", String(engine.chromeProfiles.count))
                    shortcut("Stałe odpytywanie w bezczynności", "Wyłączone")
                    shortcut("Podglądy ekranu / WebKit", "Nieużywane")
                }.padding(15)
            }
            Text("Licznik odczytów powinien zatrzymać się, kiedy nic się nie zmienia. Wartość „Dostępny” potwierdza obecność funkcji systemowej, nie wykonanie ruchu. Każdy ruch jest osobno sprawdzany.").foregroundStyle(.secondary)
            Button("Odśwież i sprawdź uprawnienia") { engine.checkAccessibility() }
            Text("Uruchomiona kopia: \(Bundle.main.bundleURL.path)").font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
            Text("Wersja 0.1.2 · dane pozostają na tym Macu").font(.caption).foregroundStyle(.secondary)
        }
    }

    func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)) }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
    func shortcut(_ label: String, _ value: String) -> some View { HStack { Text(label); Spacer(); Text(value).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary) } }
    func empty(_ title: String, _ detail: String, _ icon: String) -> some View { VStack(spacing: 13) { Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.teal); Text(title).font(.title3.bold()); Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420) }.padding(45).frame(maxWidth: .infinity) }
}
