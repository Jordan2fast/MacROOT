import SwiftUI

struct BackupsView: View {
    @EnvironmentObject var state: AppState
    @State private var entries: [BackupEntry] = []
    @State private var message = ""
    @State private var restoring: BackupEntry?

    var body: some View {
        PageView(title: "Backups", subtitle: "Everything MacROOT backed up before it changed something") {
            if entries.isEmpty {
                Card("No backups yet") {
                    Text("MacROOT backs up the EFI before updates and upgrades, and config.plist before each save. They land in ~/Documents/MacROOT Backups.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(entries) { e in row(e) }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
            Text("Restoring an EFI copies the backed-up files over the mounted EFI (files added since are kept). The current EFI is backed up first. Retention is set in Settings (now: newest \(Backups.keepCount) of each kind).")
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            HStack {
                Button("Open folder") { NSWorkspace.shared.open(AppPaths.backups) }
                Button("Prune now") { Backups.prune(force: true); entries = Backups.list(); message = "Pruned to the newest \(Backups.keepCount) of each kind." }
                Button { entries = Backups.list() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .task { entries = Backups.list() }
        .confirmationDialog("Restore \(restoring?.url.lastPathComponent ?? "")?",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) { if let r = restoring { Task { await restore(r) } } }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: {
            Text("The current version is backed up first.")
        }
    }

    private func row(_ e: BackupEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: e.kind == .efi ? "externaldrive" : (e.kind == .config ? "doc.text" : "doc")).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.url.lastPathComponent).font(.callout.weight(.semibold))
                Text("\(e.date.formatted(date: .abbreviated, time: .shortened)) · \(e.sizeText)").font(.caption).foregroundStyle(.secondary)
            }
            Pill(text: e.kind.rawValue.uppercased(), color: e.kind == .efi ? Color.blue : Color.green)
            Spacer()
            if e.kind != .other { Button("Restore…") { restoring = e } }
            Button("Reveal") { Panels.reveal(e.url) }
            Button("Delete", role: .destructive) {
                try? FileManager.default.removeItem(at: e.url)
                entries = Backups.list()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func restore(_ e: BackupEntry) async {
        restoring = nil
        guard await state.ensureMounted() != nil, let efi = state.efiFolder else { message = "No mounted EFI to restore to."; return }
        var err: String?
        switch e.kind {
        case .efi:
            err = await Backups.restoreEFI(e.url, to: efi)
        case .config:
            let dest = state.config?.url ?? efi.appendingPathComponent("OC/config.plist")
            err = await Backups.restoreConfig(e.url, to: dest)
            if err == nil { state.loadConfig(from: dest) }
        case .other:
            err = "Nothing to restore."
        }
        message = err.map { "Restore failed: \($0)" } ?? "Restored \(e.url.lastPathComponent)."
        state.addLog(message, err == nil ? .info : .error)
        entries = Backups.list()
    }
}
