import SwiftUI

struct VolumePicker: View {
    @Binding var target: String
    @State private var volumes: [MacVolume] = []

    var body: some View {
        HStack {
            Picker("Target macOS", selection: $target) {
                ForEach(volumes) { v in Text("\(v.name) — \(v.path)").tag(v.path) }
            }
            Button { volumes = VolumeScanner.macOSVolumes() } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan volumes")
        }
        .onAppear { if volumes.isEmpty { volumes = VolumeScanner.macOSVolumes() } }
    }
}

// MARK: - Debloat

struct DebloatItem: Identifiable {
    let id = UUID()
    let mb: Int
    let path: String
}

struct DebloatView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var job: ScriptJob

    @State private var target = "/"
    @State private var aggressive = false
    @State private var withTools = false
    @State private var preview: [DebloatItem] = []
    @State private var previewed = false
    @State private var confirmApply = false

    private var baseArgs: [String] {
        var a = ["debloat", "--target", target]
        if aggressive { a.append("--aggressive") }
        return a
    }
    private var totalMB: Int { preview.reduce(0) { $0 + $1.mb } }

    var body: some View {
        PageView(title: "Debloat", subtitle: "Reclaim space on a macOS install: optional apps, caches, logs, snapshots, background services") {
            Card("Target") {
                VolumePicker(target: $target)
                    .onChange(of: target) { _ in previewed = false }
                Toggle("Aggressive: printer drivers, wallpapers, screen savers, sleepimage", isOn: $aggressive)
                    .onChange(of: aggressive) { _ in previewed = false }
                Toggle("Also install the macroot toolkit afterwards (OpenCore, OCLP, VM tools)", isOn: $withTools)
                Text("System apps protected by SIP (Safari, Mail, …) can't be removed and are left alone. Services are disabled with launchctl and can be re-enabled with launchctl enable.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { Task { await runPreview() } } label: { Label("Preview", systemImage: "eye") }
                        .disabled(job.running)
                    Button { confirmApply = true } label: { Label("Apply…", systemImage: "trash") }
                        .buttonStyle(.borderedProminent)
                        .disabled(job.running || !previewed)
                    if job.running && job.owner == "debloat" { ProgressView().controlSize(.small) }
                }
                if !previewed { Text("Run a preview first. Nothing is changed by a preview.").font(.caption).foregroundStyle(.secondary) }
            }
            .confirmationDialog("Apply debloat to \(target)?", isPresented: $confirmApply, titleVisibility: .visible) {
                Button("Delete and apply", role: .destructive) { Task { await apply() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes about \(totalMB) MB of the items previewed below, and (for the running system) disables background services. It can't be undone. Administrator password required.")
            }

            if previewed {
                Card("Preview", subtitle: "About \(totalMB) MB reclaimable. Sizes for protected folders can read low until you apply as administrator.") {
                    if preview.isEmpty { Text("Nothing to remove.").foregroundStyle(.secondary) }
                    ForEach(preview) { i in
                        HStack {
                            Text("\(i.mb) MB").monospacedDigit().frame(width: 80, alignment: .trailing)
                            Text(i.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                        }
                    }
                }
            }
            ConsoleCard(job: job, owner: "debloat")
        }
    }

    private func parse(_ lines: [ScriptJob.Line]) -> [DebloatItem] {
        guard let re = try? NSRegularExpression(pattern: "would remove\\s+(\\d+) MB\\s+(.+)$") else { return [] }
        var out: [DebloatItem] = []
        for l in lines {
            let ns = l.text as NSString
            if let m = re.firstMatch(in: l.text, range: NSRange(location: 0, length: ns.length)),
               let mb = Int(ns.substring(with: m.range(at: 1))) {
                out.append(DebloatItem(mb: mb, path: ns.substring(with: m.range(at: 2))))
            }
        }
        return out
    }

    private func runPreview() async {
        let code = await job.run(owner: "debloat", title: "Debloat preview", args: baseArgs, privileged: false)
        if code == 0 {
            preview = parse(job.lines)
            previewed = true
        } else {
            state.addLog("Debloat preview failed (exit \(code.map { String($0) } ?? "not started")).", .error)
        }
    }

    private func apply() async {
        var args = baseArgs + ["--yes"]
        if withTools { args.append("--with-tools") }
        let code = await job.run(owner: "debloat", title: "Debloat \(target)", args: args, privileged: true)
        state.addLog("Debloat of \(target) finished (exit \(code.map { String($0) } ?? "not started")).", code == 0 ? .info : .error)
        previewed = false
    }
}

// MARK: - Toolkit & VM

struct ToolkitView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var job: ScriptJob

    @State private var target = "/"
    @State private var fetchDir = AppPaths.documents.appendingPathComponent("macROOT-Tools").path
    @State private var iso: URL?
    @State private var vmKind = ""

    var body: some View {
        PageView(title: "Toolkit & VM", subtitle: "Install the macroot helper, OpenCore and OCLP archives, and VM guest tools") {
            Card("Install toolkit", subtitle: "Puts macroot in <target>/usr/local/bin and OpenCore + OCLP in <target>/usr/local/macROOT-Tools") {
                VolumePicker(target: $target)
                HStack {
                    Button { Task { await installToolkit() } } label: { Label("Install toolkit", systemImage: "shippingbox") }
                        .buttonStyle(.borderedProminent)
                        .disabled(job.running)
                    Text("Administrator password required. Downloads the latest OpenCore and OCLP releases from GitHub.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Card("Download OpenCore + OCLP archives", subtitle: "Just the files, into a folder you choose, with SHA256SUMS") {
                HStack {
                    TextField("Folder", text: $fetchDir).textFieldStyle(.roundedBorder)
                    Button("Choose…") { if let u = Panels.pick(message: "Choose a folder", files: false) { fetchDir = u.path } }
                }
                Button { Task { await fetch() } } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .disabled(job.running)
            }

            Card("Virtual machine", subtitle: "Detects VMware / Parallels / VirtualBox / QEMU guests and installs the hypervisor's macOS tools") {
                HStack {
                    Button("Detect") { Task { await detect() } }.disabled(job.running)
                    if !vmKind.isEmpty { Pill(text: vmKind.uppercased(), color: vmKind == "none" ? Color.secondary : Color.blue) }
                }
                HStack {
                    Button("Choose tools ISO…") { iso = Panels.pick(message: "Choose the guest-tools ISO (optional)", directories: false) }
                    Text(iso?.path ?? "none: use the disc already mounted by your hypervisor").font(.caption).foregroundStyle(.secondary)
                    if iso != nil { Button("Clear") { iso = nil } }
                }
                HStack {
                    Button("Install VM tools") { Task { await vm(tune: false) } }.disabled(job.running)
                    Button("Install tools + VM tuning") { Task { await vm(tune: true) } }.disabled(job.running)
                }
                Text("Tuning turns off sleep, Spotlight indexing and Time Machine, which suits a throwaway VM but not a daily-driver Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ConsoleCard(job: job, owner: "toolkit")
        }
    }

    private func installToolkit() async {
        let code = await job.run(owner: "toolkit", title: "Install toolkit to \(target)", args: ["toolkit", "--target", target], privileged: true)
        state.addLog("Toolkit install to \(target) finished (exit \(code.map { String($0) } ?? "not started")).", code == 0 ? .info : .error)
    }

    private func fetch() async {
        try? FileManager.default.createDirectory(atPath: fetchDir, withIntermediateDirectories: true)
        let code = await job.run(owner: "toolkit", title: "Download OpenCore + OCLP", args: ["fetch", fetchDir], privileged: false)
        state.addLog("Fetch into \(fetchDir) finished (exit \(code.map { String($0) } ?? "not started")).", code == 0 ? .info : .error)
    }

    private func detect() async {
        _ = await job.run(owner: "toolkit", title: "Detect virtualization", args: ["vm"], privileged: false)
        // The script prints "Virtualization: <kind>" before it checks for root.
        let text = job.lines.map { $0.text }.first(where: { $0.contains("Virtualization:") }) ?? ""
        vmKind = text.components(separatedBy: "Virtualization:").last?.trimmed ?? ""
    }

    private func vm(tune: Bool) async {
        var args = ["vm"]
        if tune { args.append("--tune") }
        if let iso = iso { args += ["--iso", iso.path] }
        let code = await job.run(owner: "toolkit", title: tune ? "VM tools + tuning" : "VM tools", args: args, privileged: true)
        state.addLog("VM tools run finished (exit \(code.map { String($0) } ?? "not started")).", code == 0 ? .info : .error)
    }
}
