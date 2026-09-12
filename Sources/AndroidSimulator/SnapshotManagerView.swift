import SwiftUI
import SimulatorKit

struct SnapshotManagerView: View {
    @ObservedObject var session: SessionController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selection: String?
    @State private var confirmation: SnapshotConfirmation?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Snapshots").font(.title2.bold())
                    Text(session.avd.displayName).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { session.performSnapshot(.refresh) }.disabled(!session.canManageSnapshots)
            }
            List(session.snapshots, selection: $selection) { snapshot in
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.name).font(.headline)
                    if !snapshot.details.isEmpty { Text(snapshot.details).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                }.padding(.vertical, 5).tag(snapshot.name)
            }.frame(minHeight: 190)
                .overlay { if session.snapshots.isEmpty && !session.snapshotBusy { Text(session.snapshotUnsupportedReason == nil ? "No loadable snapshots found" : "Snapshots unavailable").foregroundStyle(.secondary) } }
            HStack {
                TextField("New snapshot name", text: $name).textFieldStyle(.roundedBorder)
                Button("Save…") { confirm(.save(name)) }.disabled(!session.canManageSnapshots || !EmulatorSnapshots.isValidName(name))
            }
            Text("Use letters, numbers, underscores, dots, or hyphens. Saving an existing name replaces that snapshot.").font(.caption).foregroundStyle(.secondary)
            if session.snapshotBusy { HStack { ProgressView().controlSize(.small); Text("Snapshot operation in progress…").font(.caption) } }
            if let reason = session.snapshotUnsupportedReason ?? session.error { Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(5).textSelection(.enabled) }
            HStack {
                Button("Load…") { if let selection { confirm(.load(selection)) } }.disabled(selection == nil || !session.canManageSnapshots)
                Button("Delete…", role: .destructive) { if let selection { confirm(.delete(selection)) } }.disabled(selection == nil || !session.canManageSnapshots)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 520)
            .task { session.performSnapshot(.refresh) }
            .onChange(of: session.runtime?.id) { _ in confirmation = nil; selection = nil }
            .alert(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                Button("Cancel", role: .cancel) { confirmation = nil }
                Button("Continue", role: .destructive) { if let confirmation { session.performSnapshot(confirmation.action, expectedRuntimeID: confirmation.runtimeID) }; confirmation = nil }
            } message: { Text(confirmationMessage) }
    }
    private func confirm(_ action: SnapshotAction) {
        guard session.canManageSnapshots, let runtime = session.runtime else { return }
        confirmation = SnapshotConfirmation(action: action, runtimeID: runtime.id)
    }
    private var confirmationTitle: String {
        switch confirmation?.action {
        case .save: return "Save this snapshot?"
        case .load: return "Restore this snapshot?"
        case .delete: return "Delete this snapshot?"
        default: return "Snapshot action"
        }
    }
    private var confirmationMessage: String {
        switch confirmation?.action {
        case .save(let name): return "Save the current Android state as ‘\(name)’. If that name exists, its saved state will be replaced."
        case .load(let name): return "Replace the current Android state with ‘\(name)’. Changes made since that snapshot may be lost."
        case .delete(let name): return "Permanently delete ‘\(name)’ from this device. This cannot be undone."
        default: return ""
        }
    }
}

private struct SnapshotConfirmation {
    let action: SnapshotAction
    let runtimeID: UUID
}
