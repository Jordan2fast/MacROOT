import SwiftUI

extension MacOSVersion: Identifiable {
    var id: String { text }
}

struct UpgradeView: View {
    @EnvironmentObject var state: AppState

    @State private var fromText = ""
    @State private var toText = "26"
    @State private var useOCS = true
    @State private var updateOC = true
    @State private var updateKexts = true
    @State private var migrate = true
    @State private var removeObsolete = false
    @State private var thisMac = true
    @State private var rules: [UpgradeRule] = []
    @State private var ocs: [String: OCSKext] = [:]
    @State private var result: UpgradeResult?
    @State private var items: [UpdateItem] = []
    @State private var status = ""
    @State private var working = false
    @State private var validation = ""
    @State private var confirmApply = false

    // OpCore Simplify
    @State private var ocsStatus = ""
    @State private var ocsBusy = false
    @State private var refConfig: URL?
    @State private var refRoot: [String: Any]?
    @State private var mergeEntries: [DiffEntry] = []
    @State private var mergeSelected: Set<UUID> = []
    @State private var mergeSections: Set<String> = ["Kernel ▸ Quirks", "Booter ▸ Quirks", "UEFI ▸ Quirks", "NVRAM ▸ Add"]
    @State private var mergeMessage = ""

    private static let sections: [(String, [String])] = [
        ("Kernel ▸ Quirks", ["Kernel", "Quirks"]), ("Booter ▸ Quirks", ["Booter", "Quirks"]),
        ("UEFI ▸ Quirks", ["UEFI", "Quirks"]), ("NVRAM ▸ Add", ["NVRAM", "Add"]),
        ("Misc ▸ Security", ["Misc", "Security"]), ("Kernel ▸ Add (needs the kext files)", ["Kernel", "Add"]),
        ("Kernel ▸ Patch / Block / Force", ["Kernel", "Patch"]), ("ACPI (needs the .aml files)", ["ACPI"]),
        ("DeviceProperties", ["DeviceProperties"]), ("PlatformInfo (SMBIOS: serial, MLB, ROM)", ["PlatformInfo"])
    ]

    private var from: MacOSVersion? { MacOSVersion(fromText) }
    private var to: MacOSVersion? { MacOSVersion(toText) }

    var body: some View {
        PageView(title: "macOS Upgrade Assistant",
                 subtitle: "Make an OpenCore config and EFI work for a newer macOS (for example a 13.5 config → 26.7.5)") {
            versionsCard
            optionsCard
            if !rules.isEmpty { rulesCard }
            if let res = result { planCard(res) }
            if !validation.isEmpty { Card("ocvalidate result") { MonoText(text: validation) } }
            ocsCard
            mergeCard
        }
        .task { await prefill() }
    }

    // MARK: Cards

    private var versionsCard: some View {
        Card("1 · Versions", subtitle: "Uses the config.plist on the selected EFI (\(state.selectedPartition?.id ?? "none"))") {
            HStack {
                Text("Config works for macOS").frame(width: 170, alignment: .leading)
                TextField("13.5", text: $fromText).textFieldStyle(.roundedBorder).frame(width: 110)
                Menu("Presets") { ForEach(MacOSVersion.presets) { v in Button(v.display) { fromText = v.text } } }.frame(width: 90)
                if let f = from { Pill(text: "\(f.name) · Darwin \(f.darwinMajor)", color: Color.secondary) }
            }
            HStack {
                Text("Upgrade to macOS").frame(width: 170, alignment: .leading)
                TextField("26.7.5", text: $toText).textFieldStyle(.roundedBorder).frame(width: 110)
                Menu("Presets") { ForEach(MacOSVersion.presets) { v in Button(v.display) { toText = v.text } } }.frame(width: 90)
                if let t = to {
                    Pill(text: "\(t.name) · Darwin \(t.darwinMajor)", color: t.supportsIntel ? Color.blue : Color.red)
                } else {
                    Pill(text: "NOT A VERSION", color: Color.red)
                }
            }
            if let t = to, !t.supportsIntel {
                Text("macOS \(t.major) is Apple silicon only, so no Intel Hackintosh can run it. macOS 26 Tahoe is the last release for Intel.")
                    .font(.callout).foregroundStyle(.red)
            }
            if state.config?.isDirty == true {
                Text("The Config Studio has unsaved changes. Save or discard them first so the assistant reads the right file.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var optionsCard: some View {
        Card("2 · What to do") {
            Toggle("Use OpCore Simplify's kext data for per-macOS compatibility checks", isOn: $useOCS)
            Toggle("Update OpenCore, drivers and tools to the latest release", isOn: $updateOC)
            Toggle("Update kexts to their latest releases", isOn: $updateKexts)
            Toggle("Migrate config.plist to the new Sample.plist (adds missing keys, converts old Drivers entries)", isOn: $migrate)
            Toggle("Also remove keys that are no longer in Sample.plist", isOn: $removeObsolete).disabled(!migrate)
            Toggle("This config is for this Mac (lets the assistant read its CPU features)", isOn: $thisMac)
            HStack {
                Button { Task { await analyze() } } label: { Label("Analyze", systemImage: "magnifyingglass") }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || to == nil || from == nil || !(to?.supportsIntel ?? false) || state.config?.isDirty == true)
                if working { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var rulesCard: some View {
        Card("3 · Findings", subtitle: "Tick what you want applied. Nothing changes until step 4 and 5.") {
            ForEach(UpgradeRule.Category.allCases, id: \.self) { cat in
                let group = rules.indices.filter { rules[$0].category == cat }
                if !group.isEmpty {
                    Text(cat.rawValue).font(.subheadline.bold()).padding(.top, 4)
                    ForEach(group, id: \.self) { i in ruleRow($rules[i]) }
                }
            }
            HStack {
                Button { Task { await buildPlan() } } label: { Label("Build update plan", systemImage: "list.clipboard") }
                    .disabled(working)
                Text("Downloads what's needed and shows the exact config changes first.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: Binding<UpgradeRule>) -> some View {
        let r = rule.wrappedValue
        HStack(alignment: .top, spacing: 8) {
            if r.isActionable {
                Toggle("", isOn: rule.selected).labelsHidden()
            } else {
                Image(systemName: r.category == .blocker ? "xmark.octagon.fill" : "info.circle").foregroundStyle(r.category == .blocker ? Color.red : Color.secondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(r.title).font(.callout.weight(.semibold))
                    Pill(text: r.risk.rawValue, color: r.risk == .risky ? Color.red : (r.risk == .review ? Color.orange : (r.risk == .safe ? Color.green : Color.secondary)))
                }
                Text(r.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func planCard(_ res: UpgradeResult) -> some View {
        Card("4 · Review", subtitle: "OpenCore \(res.package.version) package · \(res.diff.count) config change(s)") {
            ForEach(UpdateItem.Kind.allCases, id: \.self) { kind in
                if items.contains(where: { $0.kind == kind }) {
                    Text(kind.rawValue).font(.subheadline.bold()).padding(.top, 4)
                    ForEach($items) { $item in
                        if item.kind == kind {
                            HStack {
                                Toggle("", isOn: $item.selected).labelsHidden().disabled(!item.needsUpdate)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                    Text(item.note).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.needsUpdate { Text("\(item.installed) → \(item.latest)").font(.caption.monospaced()) }
                                else { Pill(text: "UP TO DATE", color: Color.green) }
                            }
                        }
                    }
                }
            }
            if !res.diff.isEmpty {
                Text("config.plist changes").font(.subheadline.bold()).padding(.top, 6)
                ForEach(Array(res.diff.prefix(80))) { d in
                    HStack(alignment: .top) {
                        Pill(text: d.kind.rawValue.uppercased(), color: d.kind == .added ? Color.green : (d.kind == .removed ? Color.red : Color.orange))
                        Text(d.display).font(.caption).textSelection(.enabled)
                        Spacer()
                        if d.kind == .changed { Text("\(d.oldText) → \(d.newText)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        else if d.kind == .added { Text(d.newText).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                }
                if res.diff.count > 80 { Text("…and \(res.diff.count - 80) more").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(res.notes, id: \.self) { n in Text("• \(n)").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button { confirmApply = true } label: { Label("5 · Apply", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || items.filter { $0.selected && $0.needsUpdate }.isEmpty)
                Text("The whole EFI is backed up first, then ocvalidate checks the result.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Apply the upgrade to \(state.selectedPartition?.id ?? "the EFI")?", isPresented: $confirmApply, titleVisibility: .visible) {
            Button("Apply", role: .destructive) { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files on the EFI partition are replaced and config.plist is rewritten. A full backup goes to ~/Documents/MacROOT Backups first. Boot a spare entry or drive to test before trusting it.")
        }
    }

    private var ocsCard: some View {
        Card("OpCore Simplify", subtitle: "Backend for kext compatibility data, and the best way to generate a brand-new EFI for a new macOS") {
            Text("MacROOT reads OpCore Simplify's kext dataset (the per-macOS min/max versions, requirements and download sources) for the analysis above. To build a fresh EFI for the target macOS, download and run OpCore Simplify itself (it needs a hardware report from Hardware Sniffer), then merge its result below.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { Task { await refreshOCSData() } } label: { Label("Refresh kext data", systemImage: "arrow.clockwise") }.disabled(ocsBusy)
                Button { Task { await downloadOCS() } } label: { Label("Download / update OpCore Simplify", systemImage: "arrow.down.circle") }.disabled(ocsBusy)
                Button("Run in Terminal") { NSWorkspace.shared.open(OCSBackend.launcher) }
                    .disabled(!FileManager.default.fileExists(atPath: OCSBackend.launcher.path))
                Button("Reveal") { Panels.reveal(OCSBackend.toolFolder) }
                    .disabled(!FileManager.default.fileExists(atPath: OCSBackend.toolFolder.path))
                Button("GitHub") { if let u = URL(string: OCSBackend.repoPage) { NSWorkspace.shared.open(u) } }
                if ocsBusy { ProgressView().controlSize(.small) }
            }
            if !ocsStatus.isEmpty { Text(ocsStatus).font(.caption).foregroundStyle(.secondary) }
            Text("OpCore Simplify © lzhoang2801, BSD 3-Clause licence. Its authors warn that Hackintosh information from AI/LLM sources is often wrong. Verify anything important against Dortania's guide.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var mergeCard: some View {
        Card("Merge from an OpCore Simplify EFI", subtitle: "Compare its generated config.plist with yours and copy selected parts over") {
            HStack {
                Button("Choose its EFI or config.plist…") { chooseReference() }
                Text(refConfig?.path ?? "none chosen").font(.caption).foregroundStyle(.secondary)
            }
            if refRoot != nil {
                ForEach(Array(Self.sections.enumerated()), id: \.offset) { _, sec in
                    Toggle(sec.0, isOn: Binding(get: { mergeSections.contains(sec.0) },
                                                set: { on in if on { mergeSections.insert(sec.0) } else { mergeSections.remove(sec.0) } }))
                }
                HStack {
                    Button("Compare") { compare() }.disabled(state.config == nil)
                    if state.config == nil { Text("Load your config in the Config Studio first.").font(.caption).foregroundStyle(.orange) }
                }
            }
            ForEach(Array(mergeEntries.prefix(150))) { e in
                HStack(alignment: .top) {
                    Toggle("", isOn: Binding(get: { mergeSelected.contains(e.id) },
                                             set: { on in if on { mergeSelected.insert(e.id) } else { mergeSelected.remove(e.id) } })).labelsHidden()
                    Pill(text: e.kind.rawValue.uppercased(), color: e.kind == .added ? Color.green : Color.orange)
                    Text(e.display).font(.caption).textSelection(.enabled)
                    Spacer()
                    Text(e.kind == .changed ? "\(e.oldText) → \(e.newText)" : e.newText).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            if !mergeEntries.isEmpty {
                HStack {
                    Button("Merge selected into the open config") { mergeApply() }
                        .buttonStyle(.borderedProminent).disabled(mergeSelected.isEmpty)
                    Text("Applied in memory and undoable. Save it from the Config Studio.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !mergeMessage.isEmpty { Text(mergeMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Actions

    private func prefill() async {
        if fromText.isEmpty {
            let r = await Shell.run("/usr/bin/sw_vers", ["-productVersion"])
            fromText = r.ok ? r.out.trimmed : "13.5"
        }
    }

    private func analyze() async {
        guard let f = from, let t = to else { return }
        working = true
        defer { working = false }
        result = nil
        validation = ""
        guard let part = await state.ensureMounted(), let mp = part.mountPoint else { status = "No mounted EFI."; return }
        let efi = URL(fileURLWithPath: mp).appendingPathComponent("EFI")
        do {
            status = "Reading config.plist…"
            let cfg = try ConfigIO.readDict(efi.appendingPathComponent("OC/config.plist"))
            var table: [String: OCSKext] = [:]
            if useOCS {
                status = "Loading OpCore Simplify data…"
                do { table = try await OCSBackend.loadKextData() }
                catch { state.addLog("OpCore Simplify data unavailable: \(error.localizedDescription)", .warning) }
            }
            let kextDir = efi.appendingPathComponent("OC/Kexts")
            let onDisk = Set(((try? FileManager.default.contentsOfDirectory(atPath: kextDir.path)) ?? []).filter { $0.hasSuffix(".kext") }.map { String($0.dropLast(5)) })
            let oc = await SystemInfoService.openCoreVersion()
            var avx: Bool?
            if thisMac { avx = await SystemInfoService.cpuHasAVX2() }
            ocs = table
            rules = UpgradeAnalyzer.analyze(UpgradeContext(config: cfg, from: f, to: t, ocs: table, kextsOnDisk: onDisk, installedOpenCore: oc, cpuHasAVX2: avx))
            status = "\(rules.filter { $0.isActionable }.count) change(s) proposed."
            state.addLog("Upgrade analysis \(f.text) → \(t.text): \(rules.count) finding(s).")
        } catch {
            status = "Failed: \(error.localizedDescription)"
            state.addLog("Upgrade analysis failed: \(error.localizedDescription)", .error)
        }
    }

    private func buildPlan() async {
        guard let efi = state.efiFolder else { return }
        working = true
        defer { working = false }
        do {
            let cfg = try ConfigIO.readDict(efi.appendingPathComponent("OC/config.plist"))
            let res = try await UpgradeEngine.prepare(efi: efi, config: cfg, rules: rules, ocs: ocs,
                                                      updateOpenCore: updateOC, updateKexts: updateKexts,
                                                      migrate: migrate, removeObsolete: removeObsolete) { msg in
                Task { @MainActor in status = msg }
            }
            result = res
            items = res.items
            status = "Plan ready: \(res.items.filter { $0.needsUpdate }.count) file change(s), \(res.diff.count) config change(s)."
        } catch {
            status = "Failed: \(error.localizedDescription)"
            state.addLog("Building the upgrade plan failed: \(error.localizedDescription)", .error)
        }
    }

    private func apply() async {
        guard let res = result, let efi = state.efiFolder else { return }
        let chosen = items.filter { $0.selected && $0.needsUpdate }
        guard !chosen.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            status = "Backing up EFI…"
            let backup = try await FileOps.backupEFI(efi)
            Backups.prune()
            state.addLog("EFI backed up to \(backup.path)")
            status = "Applying \(chosen.count) change(s)…"
            let priv = !FileOps.isWritable(efi.appendingPathComponent("OC"))
            let r = await FileOps.runScript(UpdatePlanner.applyScript(chosen), privileged: priv)
            guard r.ok else {
                status = "Apply failed. Your backup is at \(backup.path)"
                state.addLog("Upgrade apply failed: \(r.combined)", .error)
                return
            }
            for c in chosen { state.addLog("Upgrade: \(c.kind.rawValue) \(c.name)") }
            let cfgURL = efi.appendingPathComponent("OC/config.plist")
            status = "Validating with ocvalidate…"
            let v = await Shell.run(res.package.ocvalidate.path, [cfgURL.path])
            validation = v.combined.isEmpty ? "ocvalidate reported nothing." : v.combined
            state.addLog("ocvalidate: " + (v.ok ? "passed" : "reported issues"), v.ok ? .info : .warning)
            state.loadConfig(from: cfgURL)
            result = nil
            rules = []
            status = "Done. Backup: \(backup.lastPathComponent)"
        } catch {
            status = "Failed: \(error.localizedDescription)"
            state.addLog("Upgrade apply failed: \(error.localizedDescription)", .error)
        }
    }

    private func refreshOCSData() async {
        ocsBusy = true
        defer { ocsBusy = false }
        do {
            let t = try await OCSBackend.loadKextData(forceRefresh: true)
            ocsStatus = "Loaded \(t.count) kexts from OpCore Simplify's dataset."
        } catch {
            ocsStatus = "Failed: \(error.localizedDescription)"
        }
    }

    private func downloadOCS() async {
        ocsBusy = true
        defer { ocsBusy = false }
        do {
            let f = try await OCSBackend.downloadTool()
            ocsStatus = "OpCore Simplify is in \(f.path). “Run in Terminal” starts it (it needs Python 3)."
            state.addLog("Downloaded OpCore Simplify to \(f.path)")
        } catch {
            ocsStatus = "Failed: \(error.localizedDescription)"
        }
    }

    private func chooseReference() {
        guard let u = Panels.pick(message: "Choose OpCore Simplify's EFI folder or its config.plist") else { return }
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        var cfg: URL?
        if !isDir.boolValue { cfg = u }
        else {
            for rel in ["config.plist", "OC/config.plist", "EFI/OC/config.plist"] {
                let c = u.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: c.path) { cfg = c; break }
            }
        }
        guard let c = cfg, let d = try? ConfigIO.readDict(c) else { mergeMessage = "Couldn't find a readable config.plist there."; return }
        refConfig = c
        refRoot = d
        mergeEntries = []
        mergeMessage = ""
    }

    private func compare() {
        guard let doc = state.config, let ref = refRoot else { return }
        let prefixes = Self.sections.filter { mergeSections.contains($0.0) }.map { $0.1 }
        let all = PlistDiff.diff(doc.root, ref)
        mergeEntries = all.filter { e in
            e.kind != .removed && prefixes.contains { p in
                e.path.count >= p.count && zip(p, e.path).allSatisfy { ($1 as? String) == $0 }
            }
        }
        mergeSelected = Set(mergeEntries.map { $0.id })
        let removed = all.filter { $0.kind == .removed }.count
        mergeMessage = "\(mergeEntries.count) difference(s) in the chosen sections. \(removed) item(s) exist only in your config and are never removed by a merge."
    }

    private func mergeApply() {
        guard let doc = state.config else { return }
        let chosen = mergeEntries.filter { mergeSelected.contains($0.id) }
        doc.replaceRoot(PlistDiff.apply(chosen, to: doc.root))
        state.addLog("Merged \(chosen.count) change(s) from \(refConfig?.lastPathComponent ?? "reference") into the open config (unsaved).")
        mergeMessage = "Merged \(chosen.count) change(s) into the open config. Review and save it in the Config Studio."
        mergeEntries = []
    }
}
