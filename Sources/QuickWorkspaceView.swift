import SwiftUI

@MainActor final class QuickWorkspaceState: ObservableObject {
    @Published var working = false
    @Published var actionError: String?
}

@MainActor struct QuickWorkspaceView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var ui: QuickWorkspaceState
    let destination: Desktop
    let summon: (Desktop) async -> Bool
    let sendBack: (UInt32) async -> Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring a window here").font(.title2.bold())
            Text("Destination: \(engine.number(destination)) · \(engine.name(destination))").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(engine.numberedDesktops.enumerated()), id: \.element.id) { index, desktop in
                        let unavailable = engine.summonUnavailableReason(from: desktop, to: destination)
                        sourceButton(desktop, number: index + 1, reason: unavailable)
                    }
                    let borrowed = engine.windows.filter { engine.borrowed($0) != nil && $0.spaceIDs == [destination.systemID] }
                    if !borrowed.isEmpty {
                        Divider()
                        Text("Return a window home").font(.headline)
                        ForEach(borrowed) { window in
                            Button { perform { await sendBack(window.id) } } label: {
                                HStack {
                                    Text(window.profileName ?? window.appName).lineLimit(1)
                                    Spacer()
                                    Text("Return home").foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(6)
                            }.help(window.title).disabled(ui.working || engine.busy || !engine.trusted)
                        }
                    }
                }
            }
            if ui.working || engine.busy {
                HStack { ProgressView().controlSize(.small); Text("Moving window…") }.font(.callout)
            }
            if let actionError = ui.actionError {
                Text(actionError).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Refresh windows") { engine.refresh(full: true) }.disabled(ui.working || engine.busy)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 460, height: 560)
    }

    private func sourceButton(_ desktop: Desktop, number: Int, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if number <= 9 {
                sourceAction(desktop, number: number, reason: reason)
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [])
            } else {
                sourceAction(desktop, number: number, reason: reason)
            }
            if let reason { Text(reason).font(.caption).foregroundStyle(.secondary).padding(.leading, 8) }
        }
    }

    private func sourceAction(_ desktop: Desktop, number: Int, reason: String?) -> some View {
        Button { perform { await summon(desktop) } } label: {
                HStack {
                    Text(String(number)).monospacedDigit().frame(width: 24)
                    Text(engine.name(desktop)).lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.down.left")
                }.frame(maxWidth: .infinity).padding(6)
        }.disabled(reason != nil || ui.working || engine.busy || !engine.trusted)
    }

    private func perform(_ action: @escaping () async -> Bool) {
        guard !ui.working, !engine.busy else { return }
        ui.working = true; ui.actionError = nil
        Task { @MainActor in
            let succeeded = await action()
            ui.working = false
            if succeeded { close() }
            else { ui.actionError = engine.busy ? "Another window operation is running. Please try again when it finishes." : (engine.lastError ?? engine.status) }
        }
    }
}
