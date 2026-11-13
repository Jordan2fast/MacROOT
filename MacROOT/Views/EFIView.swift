import SwiftUI

struct EFIView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        PageView(title: "EFI Mounter", subtitle: "Mount, inspect and back up EFI system partitions") {
            if state.partitions.isEmpty {
                Card("No EFI partitions found") {
                    Text("diskutil didn't report any partition with the EFI type. Press Refresh to try again.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(state.partitions) { p in
                row(p)
            }
            if let p = state.selectedPartition, p.isMounted, let efi = state.efiFolder {
                Card("Contents of \(p.id)", subtitle: p.mountPoint) {
                    ForEach(Array(summary(efi).enumerated()), id: \.offset) { _, item in
                        HStack {
                            Image(systemName: item.1 ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(item.1 ? Color.green : Color.secondary)
                            Text(item.0)
                        }
                    }
                    HStack {
                        Button("Load config.plist") { Task { await state.loadConfigFromEFI(); state.section = .config } }
                        Button("Back up EFI") { Task { await backup(efi) } }
                        Button("Reveal in Finder") { Panels.reveal(efi) }
                    }
                }
            }
        } actions: {
            HStack {
                Button("Mount boot EFI") { Task { await mountBoot() } }
                    .disabled(state.bootEFIUUID == nil)
                Button { Task { await state.refreshPartitions() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
    }

    @ViewBuilder
    private func row(_ p: EFIPartition) -> some View {
        let selected = state.selectedEFIID == p.id
        HStack(spacing: 12) {
            Image(systemName: p.isInternal ? "internaldrive" : "externaldrive")
                .font(.title2).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(p.id) — \(p.parentName)").font(.headline)
                    if state.isBootEFI(p) { Pill(text: "BOOTED FROM", color: .blue) }
                    if p.isMounted { Pill(text: "MOUNTED", color: .green) }
                }
                Text("\(p.sizeText) · \(p.isInternal ? "Internal" : "External")" + (p.mountPoint.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if p.isMounted {
                Button("Unmount") { Task { await unmount(p) } }
            } else {
                Button("Mount") { state.selectedEFIID = p.id; Task { _ = await state.ensureMounted() } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { state.selectedEFIID = p.id }
    }

    private func summary(_ efi: URL) -> [(String, Bool)] {
        let fm = FileManager.default
        func has(_ rel: String) -> Bool { fm.fileExists(atPath: efi.appendingPathComponent(rel).path) }
        let kexts = ((try? fm.contentsOfDirectory(atPath: efi.appendingPathComponent("OC/Kexts").path)) ?? []).filter { $0.hasSuffix(".kext") }.count
        return [
            ("EFI/BOOT/BOOTx64.efi", has("BOOT/BOOTx64.efi")),
            ("EFI/OC/OpenCore.efi", has("OC/OpenCore.efi")),
            ("EFI/OC/config.plist", has("OC/config.plist")),
            ("EFI/OC/Kexts — \(kexts) kext(s)", kexts > 0),
            ("EFI/Microsoft (Windows boot files)", has("Microsoft"))
        ]
    }

    private func mountBoot() async {
        if let p = state.partitions.first(where: { state.isBootEFI($0) }) {
            state.selectedEFIID = p.id
            _ = await state.ensureMounted()
        }
    }

    private func unmount(_ p: EFIPartition) async {
        state.busyMessage = "Unmounting \(p.id)…"
        let r = await DiskService.unmount(p.id)
        state.busyMessage = nil
        state.addLog(r.message.isEmpty ? "Unmount \(p.id): \(r.ok ? "ok" : "failed")" : r.message, r.ok ? .info : .error)
        await state.refreshPartitions()
    }

    private func backup(_ efi: URL) async {
        state.busyMessage = "Backing up EFI…"
        defer { state.busyMessage = nil }
        do {
            let dest = try await FileOps.backupEFI(efi)
            state.addLog("EFI backed up to \(dest.path)")
            Panels.reveal(dest)
        } catch {
            state.addLog("Backup failed: \(error.localizedDescription)", .error)
        }
    }
}
