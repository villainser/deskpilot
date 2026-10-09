import SwiftUI

struct QuickWorkspaceView: View {
    @ObservedObject var engine: Engine
    let destination: Desktop
    let summon: (Desktop) -> Void
    let sendBack: (UInt32) -> Void
    let cancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bring a window here").font(.title2.bold())
                Text("Choose its desktop. Each selection brings the next window.").foregroundStyle(.secondary)
                ForEach(Array(engine.numberedDesktops.enumerated()), id: \.element.id) { index, desktop in
                    let available = desktop.id != destination.id && engine.windows.contains {
                        $0.group != nil && $0.spaceIDs == [desktop.systemID] && engine.borrowed($0) == nil
                    }
                    if index < 9 {
                        sourceButton(desktop, number: index + 1).keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: []).disabled(!available)
                    } else {
                        sourceButton(desktop, number: index + 1).disabled(!available)
                    }
                }
                let borrowed = engine.windows.filter { engine.borrowed($0) != nil && $0.spaceIDs == [destination.systemID] }
                if !borrowed.isEmpty {
                    Divider()
                    Text("Return a window home").font(.headline)
                    ForEach(borrowed) { window in
                        Button { sendBack(window.id) } label: {
                            HStack {
                                Text(window.profileName ?? window.appName).lineLimit(1)
                                Spacer()
                                Text("Return home").foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(6)
                        }.help(window.title)
                    }
                }
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }.padding(20)
        }.frame(width: 440, height: 500)
    }

    private func sourceButton(_ desktop: Desktop, number: Int) -> some View {
        Button { summon(desktop) } label: {
            HStack {
                Text(String(number)).monospacedDigit().frame(width: 24)
                Text(engine.name(desktop)).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.down.left")
            }.frame(maxWidth: .infinity).padding(6)
        }
    }
}
