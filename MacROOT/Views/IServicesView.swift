import SwiftUI

struct IServicesView: View {
    struct PatchPlan {
        var mode: AMLMode
        var hits: [URL]
        var newMAC: [UInt8]
    }

    @EnvironmentObject var state: AppState
    @ObservedObject var job: ScriptJob

    @State private var live: [AuditIssue] = []
    @State private var checking = false
    @State private var en0Hex = ""
    @State private var macMessage = ""
    @State private var plan: PatchPlan?
    @State private var confirmPatch = false
    @State private var nvram: NVRAMTestState = .notStarted
    @State private var nvramMessage = ""
    @State private var diagnosis: DiagnosisResult?
    @State private var diagFile: URL?

    var body: some View {
        PageView(title: "iServices", subtitle: "iMessage, FaceTime and App Store sign-in on a Hackintosh") {
            smbiosCard
            if !live.isEmpty { Card("Live checks") { IssueList(issues: live) } }
            macCard
            nvramCard
            diagnoseCard
            ConsoleCard(job: job, owner: "iservices")
            if let d = diagnosis { diagnosisCards(d) }
            guideCard
        } actions: {
            HStack {
                if checking { ProgressView().controlSize(.small) }
                Button { Task { await runChecks() } } label: { Label("Run all checks", systemImage: "checkmark.shield") }
                    .disabled(checking)
            }
        }
        .task { await refreshMAC() }
    }

    // MARK: Cards

    @ViewBuilder
    private var smbiosCard: some View {
        if let doc = state.config {
            let rep = IServices.smbiosReport(doc.root)
            Card("SMBIOS in your config", subtitle: doc.url.path) {
                ForEach(Array(rep.rows.enumerated()), id: \.offset) { _, row in LabeledContent(row.0, value: row.1) }
                IssueList(issues: rep.issues)
                HStack {
                    Button("Generate / replace SMBIOS…") { state.section = .smbios }
                    Button("Open Apple's coverage page") {
                        if let u = URL(string: "https://checkcoverage.apple.com/") { NSWorkspace.shared.open(u) }
                    }
                }
                Text("A good serial should NOT show a purchase date or model on Apple's coverage page. If it does, it belongs to a real Mac, so generate another.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Card("SMBIOS in your config") {
                Text("Load the config.plist so MacROOT can check PlatformInfo.").foregroundStyle(.secondary)
                Button("Load from selected EFI") { Task { await state.loadConfigFromEFI() } }
            }
        }
    }

    private var macCard: some View {
        Card("en0 MAC and ROM", subtitle: "iMessage wants en0 to be built-in with a valid unicast MAC, and ROM to match it") {
            LabeledContent("en0 MAC", value: en0Hex.isEmpty ? "not found" : IServices.pretty([UInt8](Data(hexString: en0Hex) ?? Data())))
            if !en0Hex.isEmpty {
                HStack {
                    Pill(text: IServices.isUnicast(en0Hex) ? "UNICAST" : "MULTICAST BIT SET", color: IServices.isUnicast(en0Hex) ? Color.green : Color.red)
                    Pill(text: IServices.isAppleOUI(en0Hex) ? "APPLE OUI" : "NOT AN APPLE OUI", color: IServices.isAppleOUI(en0Hex) ? Color.green : Color.orange)
                }
            }
            HStack {
                Button("Set ROM to the en0 MAC") { Task { await setROMToMAC() } }
                    .disabled(en0Hex.isEmpty || state.config == nil)
                Button("Give en0 a new Apple-style MAC…") { Task { await findPatchTargets() } }
                    .disabled(en0Hex.isEmpty)
                Button("Refresh") { Task { await refreshMAC() } }
            }
            if let p = plan {
                Divider()
                if p.hits.isEmpty {
                    Text("Couldn't find the en0 MAC in any .aml under EFI/OC/ACPI. NullEthernet may generate it at boot, or it lives in another SSDT/kext. Set the MAC bytes in your SSDT-RMNE to \(IServices.pretty(p.newMAC)) and keep ROM equal to it.")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Text("These files contain the MAC and will be patched to \(IServices.pretty(p.newMAC)) (ACPI checksum recomputed, whole EFI backed up first):").font(.callout)
                    ForEach(p.hits, id: \.self) { u in Text(u.lastPathComponent).font(.system(.caption, design: .monospaced)) }
                    Button("Patch and set ROM…") { confirmPatch = true }.buttonStyle(.borderedProminent)
                }
            }
            if !macMessage.isEmpty { Text(macMessage).font(.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog("Patch the SSDT and set ROM?", isPresented: $confirmPatch, titleVisibility: .visible) {
            Button("Patch", role: .destructive) { Task { await applyPatch() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The EFI is backed up first. The new MAC takes effect after a reboot, and iMessage may ask you to sign in again.")
        }
    }

    private var nvramCard: some View {
        Card("NVRAM persistence", subtitle: "iMessage keeps its keys in NVRAM. If they vanish on reboot you get sign-in loops") {
            HStack {
                Button("Check status") { Task { nvram = await IServices.nvramTestStatus(); nvramMessage = describe(nvram) } }
                Button("Start test…") { Task { await startNVRAM() } }
                switch nvram {
                case .waiting: Pill(text: "WAITING FOR REBOOT", color: Color.blue)
                case .passed: Pill(text: "PERSISTED", color: Color.green)
                case .failed: Pill(text: "DID NOT PERSIST", color: Color.red)
                case .notStarted: EmptyView()
                }
            }
            Text("Start sets a harmless test variable (administrator password). Reboot once, then press Check status.").font(.caption).foregroundStyle(.secondary)
            if !nvramMessage.isEmpty { Text(nvramMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var diagnoseCard: some View {
        Card("Diagnose a sign-in failure", subtitle: "Records 90 seconds of iMessage and account logs, then picks out the errors") {
            Text("Press Record, then switch to Messages and try to sign in. Needs your administrator password (macOS only lets root read these logs).")
                .font(.callout).foregroundStyle(.secondary)
            Button { Task { await diagnose() } } label: { Label("Record 90 seconds", systemImage: "record.circle") }
                .disabled(job.running)
        }
    }

    @ViewBuilder
    private func diagnosisCards(_ d: DiagnosisResult) -> some View {
        Card("Error and fault entries", subtitle: "These are the real errors") {
            MonoText(text: d.errors.isEmpty ? "None." : d.errors.joined(separator: "\n"))
        }
        Card("Sign-out, auth and token lines") {
            MonoText(text: d.authLines.isEmpty ? "None." : d.authLines.joined(separator: "\n"))
        }
        Card("What Messages logged on the way out") {
            MonoText(text: d.messagesLines.isEmpty ? "None." : d.messagesLines.joined(separator: "\n"))
        }
        if !d.crashes.isEmpty {
            Card("Recent crash reports") {
                ForEach(Array(d.crashes.enumerated()), id: \.offset) { _, c in
                    Text(c.file).font(.caption.bold()).textSelection(.enabled)
                    MonoText(text: c.lines.joined(separator: "\n"))
                }
            }
        }
        HStack {
            if let f = diagFile { Button("Reveal full log") { Panels.reveal(f) } }
            Button("Copy summary") { Panels.copy(summary(d)) }
            Text("Share the three sections above when asking for help.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var guideCard: some View {
        Card("Checklist", subtitle: "What Apple's servers look at, in the order to fix it") {
            Text("""
            1. A real-looking, unique SMBIOS: serial, MLB, UUID and ROM all set, Automatic on, and the serial not registered to a real Mac.
            2. en0 is built-in and has a valid, unicast MAC. With no supported NIC, use NullEthernet.kext + SSDT-RMNE.
            3. ROM equals the en0 MAC.
            4. NVRAM works and persists (WriteFlash on, emulated NVRAM set up if the board needs it).
            5. albert.apple.com, identity.ess.apple.com and gsa.apple.com are reachable and presented with Apple certificates (no proxy, VPN or filtering).
            6. Reboot after any change, then sign in to iMessage/FaceTime. If it still fails, record a diagnosis and use the output when asking for help.
            """)
            .font(.callout)
            Text("This tab is a native port of iservices-helper.sh (kept in Scripts/). SMBIOS values are generated with macserial from OpenCorePkg, the engine GenSMBIOS also uses.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func describe(_ s: NVRAMTestState) -> String {
        switch s {
        case .notStarted: return "No test in progress."
        case .waiting: return "The test variable is set. Reboot, then check again."
        case .passed: return "NVRAM kept the variable across a reboot. iMessage keys can be stored."
        case .failed: return "The variable did not survive the reboot, so NVRAM isn't persisting. Check WriteFlash, emulated NVRAM and the BIOS."
        }
    }

    private func runChecks() async {
        checking = true
        defer { checking = false }
        var items = await IServices.liveChecks(config: state.config?.root)
        let v = await Shell.run("/usr/bin/sw_vers", ["-productVersion"])
        let major = Int(v.out.trimmed.split(separator: ".").first ?? "") ?? 0
        let model = (state.config.flatMap { PlistTree.get($0.root, ["PlatformInfo", "Generic", "SystemProductName"]) as? String }) ?? ""
        if let t = IServices.tahoeIssue(model: model, runningMajor: major) { items.insert(t, at: 0) }
        live = items
        await refreshMAC()
        state.addLog("iServices checks finished: \(items.filter { $0.severity == .error }.count) error(s), \(items.filter { $0.severity == .warning }.count) warning(s).")
    }

    private func refreshMAC() async {
        if let m = await SMBIOSService.en0MAC() { en0Hex = m.hex } else { en0Hex = "" }
    }

    private func setROMToMAC() async {
        guard let doc = state.config, let mac = Data(hexString: en0Hex) else { return }
        doc.set(["PlatformInfo", "Generic", "ROM"], mac)
        if let err = await doc.save() { macMessage = "Save failed: \(err)" }
        else { macMessage = "ROM set to \(en0Hex) and saved. Reboot for it to take effect."; state.addLog("ROM set to the en0 MAC in \(doc.url.path).") }
    }

    private func findPatchTargets() async {
        guard let cur = Data(hexString: en0Hex) else { return }
        guard await state.ensureMounted() != nil, let oc = state.ocFolder else { macMessage = "No mounted EFI."; return }
        let found = IServices.findAMLHits(in: oc.appendingPathComponent("ACPI"), currentMAC: [UInt8](cur))
        plan = PatchPlan(mode: found.mode, hits: found.hits, newMAC: IServices.randomAppleMAC())
        macMessage = ""
    }

    private func applyPatch() async {
        guard let p = plan, let efi = state.efiFolder, let oc = state.ocFolder else { return }
        do {
            let backup = try await FileOps.backupEFI(efi)
            state.addLog("EFI backed up to \(backup.path)")
            for u in p.hits {
                let data = try Data(contentsOf: u)
                let (new, n) = IServices.patch(data, mode: p.mode, new: p.newMAC)
                if let err = await FileOps.write(new, to: u) { macMessage = "Writing \(u.lastPathComponent) failed: \(err)"; return }
                state.addLog("Patched \(u.lastPathComponent) (\(n) change(s), ACPI checksum recomputed).")
            }
            if state.config?.url.path != oc.appendingPathComponent("config.plist").path { await state.loadConfigFromEFI() }
            if let doc = state.config {
                doc.set(["PlatformInfo", "Generic", "ROM"], Data(p.newMAC))
                if let err = await doc.save() { macMessage = "SSDT patched, but saving the config failed: \(err)"; return }
            }
            macMessage = "Done. After a reboot, `ifconfig en0 | grep ether` should show \(IServices.pretty(p.newMAC)). Backup: \(backup.lastPathComponent)"
            plan = nil
        } catch {
            macMessage = "Failed: \(error.localizedDescription)"
        }
    }

    private func startNVRAM() async {
        if await IServices.startNVRAMTest() {
            nvram = .waiting
            nvramMessage = "Test variable set. Reboot, then press Check status."
        } else {
            nvramMessage = "Couldn't set the test variable (cancelled, or NVRAM is read-only)."
        }
    }

    private func diagnose() async {
        let dir = AppPaths.documents.appendingPathComponent("MacROOT Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("iservices-\(AppPaths.timestamp()).txt")
        let v = await Shell.run("/usr/bin/sw_vers", [])
        // The header deliberately leaves out serial, MLB, UUID, ROM and the MAC so the file is safe to share.
        var header = "== \(v.out.trimmed.replacingOccurrences(of: "\n", with: " | "))\n"
        if let doc = state.config, let model = doc.string(["PlatformInfo", "Generic", "SystemProductName"]) {
            header += "== model: \(model)\n"
        }
        header += "== live log\n"
        try? header.write(to: out, atomically: true, encoding: .utf8)
        diagFile = out
        diagnosis = nil
        let code = await job.run(owner: "iservices", title: "Recording iMessage logs", args: [], privileged: true,
                                 command: IServices.diagnoseCommand(output: out))
        if code != nil { diagnosis = IServices.analyze(logFile: out) }
        state.addLog("iServices diagnosis saved to \(out.path)")
    }

    private func summary(_ d: DiagnosisResult) -> String {
        "== Errors ==\n\(d.errors.joined(separator: "\n"))\n\n== Auth/sign-out ==\n\(d.authLines.joined(separator: "\n"))\n\n== Messages ==\n\(d.messagesLines.joined(separator: "\n"))"
    }
}

extension Data {
    /// Parses "AABBCC…" (no separators) into bytes.
    init?(hexString: String) {
        let t = hexString.replacingOccurrences(of: ":", with: "")
        guard !t.isEmpty, t.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var i = t.startIndex
        while i < t.endIndex {
            let j = t.index(i, offsetBy: 2)
            guard let b = UInt8(t[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes)
    }
}
