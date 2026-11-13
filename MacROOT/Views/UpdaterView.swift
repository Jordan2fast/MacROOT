import SwiftUI

struct UpdaterView: View {
    @EnvironmentObject var state: AppState
    @State private var plan: UpdatePlan?
    @State private var items: [UpdateItem] = []
    @State private var status = ""
    @State private var working = false
    @State private var includeKexts = true
    @State private var removeObsolete = false
    @State private var validation = ""

    var body: some View {
        PageView(title: "OpenCore & Kext Updater",
                 subtitle: "Reads your config.plist, then updates OpenCore, drivers, tools and kexts to the latest releases") {
            Card("How it works", subtitle: "Nothing is written until you press Apply, and the whole EFI is backed up first") {
                Text("""
                1. The selected EFI is mounted and EFI/OC/config.plist is read.
                2. The latest OpenCorePkg release is downloaded and compared file-by-file (SHA-256) with your OpenCore.efi, BOOTx64.efi, drivers and tools.
                3. Your config.plist is compared with the new Sample.plist: missing keys are added, old string-style Drivers entries are converted, and nothing you set is overwritten.
                4. Every kext in EFI/OC/Kexts with a known GitHub repo is checked against its latest release.
                5. After applying, the new config is checked with OpenCore's own ocvalidate.
                """)
                .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Toggle("Also check kexts", isOn: $includeKexts)
                    Toggle("Remove keys that are no longer in Sample.plist", isOn: $removeObsolete)
                }
                HStack {
                    Button { Task { validation = ""; await check() } } label: { Label("Check for updates", systemImage: "magnifyingglass") }
                        .disabled(working)
                    Button { Task { await apply() } } label: { Label("Apply selected", systemImage: "arrow.down.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || items.filter { $0.selected && $0.needsUpdate }.isEmpty)
                    if working { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let p = plan {
                Card("OpenCore \(p.package.version) is the latest release") {
                    ForEach(UpdateItem.Kind.allCases, id: \.self) { kind in
                        if items.contains(where: { $0.kind == kind }) {
                            Text(kind.rawValue).font(.subheadline.bold()).padding(.top, 6)
                            ForEach($items) { $item in
                                if item.kind == kind { itemRow($item) }
                            }
                        }
                    }
                    if !p.unmanagedKexts.isEmpty {
                        Text("No update source known for: \(p.unmanagedKexts.joined(separator: ", ")). You can add repos in Settings.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                if !p.changes.isEmpty {
                    Card("config.plist changes", subtitle: "\(p.changes.count) found") {
                        ForEach(Array(p.changes.prefix(60))) { c in
                            HStack(alignment: .top) {
                                Pill(text: c.kind.rawValue.uppercased(), color: c.kind == .obsolete ? .orange : .blue)
                                Text(c.path).textSelection(.enabled)
                                Spacer()
                            }
                            .font(.caption)
                        }
                        if p.changes.count > 60 { Text("…and \(p.changes.count - 60) more").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !validation.isEmpty {
                Card("ocvalidate result") { MonoText(text: validation) }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: Binding<UpdateItem>) -> some View {
        HStack {
            Toggle("", isOn: item.selected).labelsHidden().disabled(!item.wrappedValue.needsUpdate)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.wrappedValue.name)
                Text(item.wrappedValue.note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.wrappedValue.needsUpdate {
                Text("\(item.wrappedValue.installed) → \(item.wrappedValue.latest)").font(.caption.monospaced())
            } else {
                Pill(text: "UP TO DATE", color: .green)
            }
        }
    }

    private func check() async {
        working = true
        defer { working = false }
        guard let part = await state.ensureMounted(), let mp = part.mountPoint else { status = "No mounted EFI."; return }
        let efi = URL(fileURLWithPath: mp).appendingPathComponent("EFI")
        do {
            let config = try ConfigIO.readDict(efi.appendingPathComponent("OC/config.plist"))
            let p = try await UpdatePlanner.plan(efi: efi, config: config, includeKexts: includeKexts, removeObsolete: removeObsolete) { msg in
                Task { @MainActor in status = msg }
            }
            plan = p
            items = p.items
            let n = p.items.filter { $0.needsUpdate }.count
            status = n == 0 ? "Everything is up to date." : "\(n) update(s) available."
            state.addLog("Update check finished: \(n) update(s) available (OpenCore \(p.package.version)).")
        } catch {
            status = "Failed: \(error.localizedDescription)"
            state.addLog("Update check failed: \(error.localizedDescription)", .error)
        }
    }

    private func apply() async {
        guard let p = plan, let efi = state.efiFolder else { return }
        let chosen = items.filter { $0.selected && $0.needsUpdate }
        guard !chosen.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            status = "Backing up EFI…"
            let backup = try await FileOps.backupEFI(efi)
            state.addLog("EFI backed up to \(backup.path)")
            status = "Applying \(chosen.count) update(s)…"
            let privileged = !FileOps.isWritable(efi.appendingPathComponent("OC"))
            let r = await FileOps.runScript(UpdatePlanner.applyScript(chosen), privileged: privileged)
            guard r.ok else {
                status = "Apply failed — your backup is at \(backup.path)"
                state.addLog("Apply failed: \(r.combined)", .error)
                return
            }
            for c in chosen { state.addLog("Updated \(c.kind.rawValue): \(c.name) (\(c.installed) → \(c.latest))") }
            status = "Validating config.plist…"
            let cfgURL = efi.appendingPathComponent("OC/config.plist")
            let v = await Shell.run(p.package.ocvalidate.path, [cfgURL.path])
            validation = v.combined.isEmpty ? "ocvalidate reported nothing." : v.combined
            state.addLog("ocvalidate: " + (v.ok ? "passed" : "reported issues — see the Updater page"), v.ok ? .info : .warning)
            if state.config != nil { state.loadConfig(from: cfgURL) }
            status = "Done. Backup: \(backup.lastPathComponent)"
            await check()
        } catch {
            status = "Failed: \(error.localizedDescription)"
            state.addLog("Apply failed: \(error.localizedDescription)", .error)
        }
    }
}
