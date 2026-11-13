import SwiftUI

/// Live console for a ScriptJob. Only shows when the job belongs to `owner`.
struct ConsoleCard: View {
    @ObservedObject var job: ScriptJob
    let owner: String

    private func color(_ l: LogLevel) -> Color {
        switch l {
        case .error: return .red
        case .warning: return .orange
        case .info: return .primary
        }
    }

    var body: some View {
        if job.owner == owner && (job.running || job.exitCode != nil || !job.lines.isEmpty) {
            Card(job.title, subtitle: job.running ? job.label : nil) {
                if job.running {
                    ProgressView(value: Double(job.percent), total: 100)
                    HStack {
                        Text("\(job.percent)%").monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { Task { await job.cancel() } }
                    }
                } else if let c = job.exitCode {
                    Pill(text: c == 0 ? "FINISHED" : (c == -1 ? "DID NOT RUN" : "EXIT CODE \(c)"),
                         color: c == 0 ? Color.green : Color.red)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(job.lines) { l in
                                Text(l.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(color(l.level))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(l.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 260)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
                    .onChange(of: job.lines.count) { _ in
                        if let last = job.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

// MARK: - macOS Installer

struct InstallerView: View {
    enum ToolsMode: String, CaseIterable, Identifiable {
        case download = "Download latest OpenCore + OCLP"
        case folder = "Use my own folder"
        case none = "Don't bundle tools"
        var id: String { rawValue }
    }

    @EnvironmentObject var state: AppState
    @ObservedObject var job: ScriptJob

    @State private var installers: [InstallerApp] = []
    @State private var selected: String?
    @State private var outDir = AppPaths.documents.appendingPathComponent("macROOT-out").path
    @State private var keepLangs = "en English Base"
    @State private var toolsMode: ToolsMode = .download
    @State private var toolsFolder: URL?
    @State private var confirmBuild = false
    @State private var builtApp: URL?
    @State private var appleList: [AppleInstaller] = []
    @State private var appleRaw = ""
    @State private var listing = false

    private var chosen: InstallerApp? { installers.first(where: { $0.id == selected }) }

    var body: some View {
        PageView(title: "macOS Installer",
                 subtitle: "Strip a 10.9–10.15 installer down to the core system plus a root Terminal, and bundle OpenCore, OCLP and macroot") {
            Card("1 · Installer to strip", subtitle: "Looks in /Applications and Downloads folders") {
                if installers.isEmpty {
                    Text("No “Install macOS/OS X” app found. Download or import one below, or choose one by hand.")
                        .foregroundStyle(.secondary)
                }
                ForEach(installers) { app in
                    HStack(spacing: 10) {
                        Image(systemName: selected == app.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(app.layout == .ready ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.subheadline.bold())
                            Text("\(app.version.map { "v\($0) · " } ?? "")\(app.layoutText) · \(app.url.deletingLastPathComponent().path)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Pill(text: app.layout == .ready ? "READY" : "CAN'T BUILD", color: app.layout == .ready ? Color.green : Color.orange)
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                    .onTapGesture { if app.layout == .ready { selected = app.id } }
                }
                HStack {
                    Button("Choose installer…") {
                        if let u = Panels.pick(message: "Choose an Install macOS / Install OS X app", files: true) {
                            let app = InstallerScanner.inspect(u)
                            if !installers.contains(where: { $0.id == app.id }) { installers.append(app) }
                            if app.layout == .ready { selected = app.id }
                        }
                    }
                    Button("Rescan") { rescan() }
                }
            }

            Card("2 · Options") {
                HStack {
                    Text("Output folder").frame(width: 110, alignment: .leading)
                    TextField("", text: $outDir).textFieldStyle(.roundedBorder)
                    Button("Choose…") { if let u = Panels.pick(message: "Choose the output folder", files: false) { outDir = u.path } }
                }
                HStack {
                    Text("Keep languages").frame(width: 110, alignment: .leading)
                    TextField("en English Base", text: $keepLangs).textFieldStyle(.roundedBorder)
                }
                Picker("Bundled tools", selection: $toolsMode) {
                    ForEach(ToolsMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                if toolsMode == .folder {
                    HStack {
                        Button("Choose tools folder…") { toolsFolder = Panels.pick(message: "Folder with OpenCore / OCLP archives", files: false) }
                        Text(toolsFolder?.path ?? "none chosen").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let c = chosen, c.esdBytes > 0 {
                    Text("Needs about \(ByteCountFormatter.string(fromByteCount: c.neededBytes, countStyle: .file)) free in the output folder and can take a long time. Administrator password required.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button { confirmBuild = true } label: { Label("Build stripped installer", systemImage: "hammer.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(chosen == nil || job.running || (toolsMode == .folder && toolsFolder == nil))
                    if job.running && job.owner == "installer" { ProgressView().controlSize(.small) }
                }
            }
            .confirmationDialog("Build a stripped copy of \(chosen?.name ?? "the installer")?", isPresented: $confirmBuild, titleVisibility: .visible) {
                Button("Build") { Task { await build() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The original installer is not modified. The copy's code signature becomes invalid and BaseSystem.chunklist no longer matches, so test it before relying on it.")
            }

            ConsoleCard(job: job, owner: "installer")

            if let app = builtApp {
                Card("Result", subtitle: app.path) {
                    HStack {
                        Button("Reveal in Finder") { Panels.reveal(app) }
                        Button("Copy createinstallmedia command") { Panels.copy(usbCommand(app)) }
                    }
                    Text(usbCommand(app)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Replace /Volumes/YOURUSB with your USB drive. That command erases the drive, so MacROOT doesn't run it for you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Card("Get an installer", subtitle: "Ask Apple what it still offers, or import an old InstallOS.dmg / InstallMacOSX.dmg") {
                HStack {
                    Button { Task { await listApple() } } label: { Label("List installers from Apple", systemImage: "list.bullet") }
                        .disabled(listing || job.running)
                    if listing { ProgressView().controlSize(.small) }
                    Button("Open Apple's older-installer page") {
                        if let u = URL(string: "https://support.apple.com/en-us/HT211683") { NSWorkspace.shared.open(u) }
                    }
                    Button("Import .dmg…") { Task { await importDMG() } }
                        .disabled(job.running)
                }
                ForEach(appleList) { a in
                    HStack {
                        Text("\(a.title) \(a.version)")
                        Text(a.sizeText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !a.buildable { Pill(text: "macOS 11+: CAN'T STRIP", color: Color.orange) }
                        Button("Download") { Task { await download(a) } }.disabled(job.running)
                    }
                }
                if appleList.isEmpty && !appleRaw.isEmpty { MonoText(text: appleRaw) }
            }
        }
        .task { if installers.isEmpty { rescan() } }
    }

    private func rescan() {
        installers = InstallerScanner.scan()
        if chosen == nil { selected = installers.first(where: { $0.layout == .ready })?.id }
    }

    private func usbCommand(_ app: URL) -> String {
        "sudo \"\(app.path)/Contents/Resources/createinstallmedia\" --volume /Volumes/YOURUSB --applicationpath \"\(app.path)\""
    }

    private func build() async {
        guard let app = chosen else { return }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var args = ["build", "--installer", app.url.path, "--out", outDir, "--keep-langs", keepLangs]
        switch toolsMode {
        case .none: args.append("--no-tools")
        case .folder: if let f = toolsFolder { args += ["--tools-dir", f.path] }
        case .download: break
        }
        builtApp = nil
        // The script runs as root, so hand the results back to the current user afterwards.
        let post = "/usr/sbin/chown -R \(getuid()):\(getgid()) \(Shell.quote(outDir))"
        let code = await job.run(owner: "installer", title: "Build stripped installer", args: args, privileged: true, post: post)
        if code == 0 {
            builtApp = URL(fileURLWithPath: outDir).appendingPathComponent("macROOT-" + app.name)
            state.addLog("Built stripped installer: \(builtApp?.path ?? "")")
        } else {
            state.addLog("Installer build did not finish (exit \(code.map { String($0) } ?? "not started")).", .error)
        }
    }

    private func listApple() async {
        listing = true
        defer { listing = false }
        let r = await AppleInstallerList.fetch()
        appleList = r.items
        appleRaw = r.items.isEmpty ? r.raw : ""
        state.addLog("softwareupdate lists \(r.items.count) full installer(s).")
    }

    private func download(_ a: AppleInstaller) async {
        let cmd = "/usr/sbin/softwareupdate --fetch-full-installer --full-installer-version \(Shell.quote(a.version))"
        let code = await job.run(owner: "installer", title: "Download \(a.title) \(a.version)", args: [], privileged: true, command: cmd)
        state.addLog("Download of \(a.title) \(a.version) finished (exit \(code.map { String($0) } ?? "not started")).", code == 0 ? .info : .error)
        rescan()
    }

    private func importDMG() async {
        guard let u = Panels.pick(message: "Choose InstallOS.dmg / InstallMacOSX.dmg", directories: false) else { return }
        let code = await job.run(owner: "installer", title: "Import \(u.lastPathComponent)", args: ["import", u.path], privileged: true)
        state.addLog("Import of \(u.lastPathComponent) finished (exit \(code.map { String($0) } ?? "not started")).", code == 0 ? .info : .error)
        rescan()
    }
}
