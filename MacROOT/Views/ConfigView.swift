import SwiftUI

struct ConfigView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        PageView(title: "Config Studio", subtitle: "Edit, compare, validate and tidy your OpenCore config.plist") {
            if let doc = state.config {
                ConfigStudio(doc: doc)
            } else {
                Card("No config loaded") {
                    Text("Load the config.plist from the selected EFI, or open any config.plist file.").foregroundStyle(.secondary)
                    HStack {
                        Button("Load from selected EFI") { Task { await state.loadConfigFromEFI() } }
                        Button("Open file…") {
                            if let u = Panels.pick(message: "Choose a config.plist", directories: false) { state.loadConfig(from: u) }
                        }
                    }
                }
            }
        }
    }
}

struct ConfigStudio: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", editor = "Editor", lists = "Lists", review = "Review & validate"
        var id: String { rawValue }
    }

    @ObservedObject var doc: ConfigDocument
    @EnvironmentObject var state: AppState
    @State private var tab: Tab = .overview
    @State private var message = ""

    var body: some View {
        Card("File", subtitle: doc.url.path) {
            HStack {
                if doc.isDirty { Pill(text: "UNSAVED CHANGES", color: Color.orange) }
                Button { doc.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(!doc.canUndo)
                Button { doc.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(!doc.canRedo)
                Spacer()
                Button("Open another…") {
                    if let u = Panels.pick(message: "Choose a config.plist", directories: false) { state.loadConfig(from: u) }
                }
                Button("Reload from disk") { state.loadConfig(from: doc.url) }
                Button("Reveal") { Panels.reveal(doc.url) }
                Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(!doc.isDirty)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }

        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        switch tab {
        case .overview: OverviewTab(doc: doc)
        case .editor: EditorTab(doc: doc)
        case .lists: ListsTab(doc: doc)
        case .review: ReviewTab(doc: doc)
        }
    }

    private func save() async {
        if let err = await doc.save() {
            message = "Save failed: \(err)"
            state.addLog("Saving config failed: \(err)", .error)
        } else {
            message = "Saved. The previous file was backed up to ~/Documents/MacROOT Backups."
            state.addLog("Saved \(doc.url.path)")
            Backups.prune()
        }
    }
}

// MARK: - Overview

struct OverviewTab: View {
    @ObservedObject var doc: ConfigDocument

    private static let toggles: [(String, [Any])] = [
        ("XhciPortLimit: lifts the 15-port USB limit (turn off once you have a USB map)", ["Kernel", "Quirks", "XhciPortLimit"]),
        ("DisableIoMapper: workaround for VT-d being enabled", ["Kernel", "Quirks", "DisableIoMapper"]),
        ("AppleXcpmCfgLock: workaround when CFG-Lock can't be disabled", ["Kernel", "Quirks", "AppleXcpmCfgLock"]),
        ("DisableLinkeditJettison: recommended on macOS 11 and later", ["Kernel", "Quirks", "DisableLinkeditJettison"]),
        ("PowerTimeoutKernelPanic: avoids audio/power timeout panics", ["Kernel", "Quirks", "PowerTimeoutKernelPanic"]),
        ("ShowPicker: always show the boot picker", ["Misc", "Boot", "ShowPicker"]),
        ("HideAuxiliary: hide Recovery/Reset NVRAM entries until Space is pressed", ["Misc", "Boot", "HideAuxiliary"])
    ]

    var body: some View {
        Card("Summary") {
            LabeledContent("SMBIOS model", value: doc.string(["PlatformInfo", "Generic", "SystemProductName"]) ?? "—")
            LabeledContent("SecureBootModel", value: doc.string(["Misc", "Security", "SecureBootModel"]) ?? "—")
            LabeledContent("Vault", value: doc.string(["Misc", "Security", "Vault"]) ?? "—")
            LabeledContent("ScanPolicy", value: doc.value(["Misc", "Security", "ScanPolicy"]).map { "\($0)" } ?? "—")
            LabeledContent("Kexts / drivers / tools", value: "\(count(["Kernel", "Add"])) / \(count(["UEFI", "Drivers"])) / \(count(["Misc", "Tools"]))")
        }
        BootArgsEditor(doc: doc)
        SIPEditor(doc: doc)
        Card("Quick settings") {
            ForEach(Array(Self.toggles.enumerated()), id: \.offset) { _, t in
                Toggle(t.0, isOn: Binding(get: { doc.bool(t.1) }, set: { doc.set(t.1, $0) }))
            }
        }
    }

    private func count(_ path: [Any]) -> Int { ((doc.value(path) as? [Any]) ?? []).count }
}

struct BootArgsEditor: View {
    @ObservedObject var doc: ConfigDocument
    @State private var newToken = ""

    private static let path: [Any] = ["NVRAM", "Add", "7C436110-AB2A-4BBB-A880-FE41995C9F82", "boot-args"]
    private static let presets: [(String, String)] = [
        ("-v", "Verbose boot"),
        ("keepsyms=1", "Keep symbols in panic logs"),
        ("debug=0x100", "Don't reboot automatically on a panic"),
        ("alcid=1", "AppleALC layout ID (use the one for your codec)"),
        ("agdpmod=pikera", "Black-screen fix for some Navi GPUs on macOS 11+"),
        ("-wegnoegpu", "WhateverGreen: disable the discrete GPU"),
        ("-igfxvesa", "WhateverGreen: Intel graphics in VESA mode (debugging)"),
        ("npci=0x2000", "Works around a PCI configuration panic on some boards"),
        ("-lilubetaall", "Let Lilu plugins load on macOS versions they don't know yet"),
        ("amfi_get_out_of_my_way=0x1", "Turn AMFI off (lowers security; AMFIPass.kext is the alternative)")
    ]

    private var tokens: [String] { ((doc.value(Self.path) as? String) ?? "").split(separator: " ").map(String.init) }

    private func write(_ t: [String]) { doc.set(Self.path, t.joined(separator: " ")) }

    var body: some View {
        Card("Boot arguments", subtitle: tokens.isEmpty ? "None set" : tokens.joined(separator: " ")) {
            if !tokens.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { i, t in
                        HStack(spacing: 4) {
                            Text(t).font(.system(.caption, design: .monospaced))
                            Button { var x = tokens; x.remove(at: i); write(x) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
            }
            HStack {
                TextField("Add an argument, e.g. keepsyms=1", text: $newToken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(newToken) }
                Button("Add") { add(newToken) }.disabled(newToken.trimmed.isEmpty)
                Menu("Common…") {
                    ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, p in
                        Button("\(p.0): \(p.1)") { add(p.0) }
                    }
                }
            }
        }
    }

    private func add(_ raw: String) {
        for t in raw.split(separator: " ").map(String.init) where !tokens.contains(t) { write(tokens + [t]) }
        newToken = ""
    }
}

struct SIPFlag: Identifiable {
    let bit: UInt32
    let name: String
    var id: UInt32 { bit }
}

struct SIPEditor: View {
    @ObservedObject var doc: ConfigDocument

    private static let path: [Any] = ["NVRAM", "Add", "7C436110-AB2A-4BBB-A880-FE41995C9F82", "csr-active-config"]
    private static let flags: [SIPFlag] = [
        SIPFlag(bit: 0x1, name: "Allow unsigned kexts"), SIPFlag(bit: 0x2, name: "Allow unrestricted filesystem"),
        SIPFlag(bit: 0x4, name: "Allow task_for_pid"), SIPFlag(bit: 0x8, name: "Allow kernel debugger"),
        SIPFlag(bit: 0x10, name: "Allow Apple internal"), SIPFlag(bit: 0x20, name: "Allow unrestricted DTrace"),
        SIPFlag(bit: 0x40, name: "Allow unrestricted NVRAM"), SIPFlag(bit: 0x80, name: "Allow device configuration"),
        SIPFlag(bit: 0x100, name: "Allow any recovery OS"), SIPFlag(bit: 0x200, name: "Allow unapproved kexts"),
        SIPFlag(bit: 0x400, name: "Allow executable policy override"), SIPFlag(bit: 0x800, name: "Allow unauthenticated root")
    ]
    private static let presets: [(String, UInt32)] = [
        ("Enabled (0x0)", 0x0), ("Catalina-era (0x67)", 0x67), ("Big Sur and later (0x803)", 0x803), ("Fully disabled (0xFEF)", 0xFEF)
    ]

    private var current: UInt32 { (doc.value(Self.path) as? Data)?.leUInt32 ?? 0 }

    var body: some View {
        Card("System Integrity Protection", subtitle: String(format: "csr-active-config = 0x%08X", current)) {
            HStack {
                Menu("Presets…") {
                    ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, p in
                        Button(p.0) { doc.set(Self.path, Data.le32(p.1)) }
                    }
                }
                Text("Every ticked item weakens SIP. Presets are the common ones from Dortania's guide.").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(Self.flags) { f in
                    Toggle(f.name, isOn: Binding(
                        get: { current & f.bit != 0 },
                        set: { on in doc.set(Self.path, Data.le32(on ? (current | f.bit) : (current & ~f.bit))) }))
                }
            }
        }
    }
}

// MARK: - Editor tab

struct EditorTab: View {
    @ObservedObject var doc: ConfigDocument
    @State private var section = "Kernel"
    @State private var filter = ""

    var body: some View {
        let keys = doc.root.keys.sorted()
        Card("Plist editor", subtitle: "Every key in the config. Press Return to commit a value; use the … menu to add, rename, move or delete.") {
            HStack {
                Picker("Section", selection: $section) {
                    ForEach(keys, id: \.self) { k in Text(k).tag(k) }
                }
                .frame(width: 240)
                TextField("Filter keys and values", text: $filter).textFieldStyle(.roundedBorder)
            }
            if let v = doc.value([section]) {
                PlistNodeView(doc: doc, path: [section], label: section, value: v, filter: filter)
            } else {
                Text("That section isn't in this config.").foregroundStyle(.secondary)
            }
        }
        .onAppear { if !keys.contains(section), let first = keys.first { section = first } }
    }
}

// MARK: - Lists tab

struct ListsTab: View {
    enum Which: String, CaseIterable, Identifiable {
        case kexts = "Kernel ▸ Add", acpi = "ACPI ▸ Add", drivers = "UEFI ▸ Drivers", tools = "Misc ▸ Tools", block = "Kernel ▸ Block"
        var id: String { rawValue }
    }
    @ObservedObject var doc: ConfigDocument
    @State private var which: Which = .kexts

    var body: some View {
        Picker("List", selection: $which) {
            ForEach(Which.allCases) { w in Text(w.rawValue).tag(w) }
        }
        .frame(width: 300)
        switch which {
        case .kexts:
            EntryListEditor(doc: doc, title: "Kernel ▸ Add", path: ["Kernel", "Add"],
                            fields: ["BundlePath", "ExecutablePath", "PlistPath", "MinKernel", "MaxKernel", "Comment"],
                            template: ["Arch": "Any", "BundlePath": "", "Comment": "", "Enabled": true, "ExecutablePath": "",
                                       "MaxKernel": "", "MinKernel": "", "PlistPath": "Contents/Info.plist"],
                            showKextVersion: true)
        case .acpi:
            EntryListEditor(doc: doc, title: "ACPI ▸ Add", path: ["ACPI", "Add"], fields: ["Path", "Comment"],
                            template: ["Comment": "", "Enabled": true, "Path": ""])
        case .drivers:
            EntryListEditor(doc: doc, title: "UEFI ▸ Drivers", path: ["UEFI", "Drivers"], fields: ["Path", "Arguments", "Comment"],
                            template: ["Arguments": "", "Comment": "", "Enabled": true, "LoadEarly": false, "Path": ""])
        case .tools:
            EntryListEditor(doc: doc, title: "Misc ▸ Tools", path: ["Misc", "Tools"], fields: ["Path", "Name", "Arguments", "Comment"],
                            template: ["Arguments": "", "Auxiliary": true, "Comment": "", "Enabled": true, "Flavour": "Auto",
                                       "Name": "", "Path": "", "RealPath": false, "TextMode": false])
        case .block:
            EntryListEditor(doc: doc, title: "Kernel ▸ Block", path: ["Kernel", "Block"],
                            fields: ["Identifier", "MinKernel", "MaxKernel", "Comment"],
                            template: ["Arch": "Any", "Comment": "", "Enabled": true, "Identifier": "", "MaxKernel": "", "MinKernel": "", "Strategy": "Disable"])
        }
    }
}

// MARK: - Review tab

struct ReviewTab: View {
    @ObservedObject var doc: ConfigDocument
    @EnvironmentObject var state: AppState
    @State private var issues: [AuditIssue] = []
    @State private var ocv = ""
    @State private var busy = false
    @State private var other: [DiffEntry] = []
    @State private var otherName = ""
    @State private var xml = ""
    @State private var xmlMessage = ""

    var body: some View {
        let changes = doc.diffFromSaved()
        Card("Changes since the last save", subtitle: "\(changes.count) difference(s)") {
            if changes.isEmpty { Text("Nothing changed.").foregroundStyle(.secondary) }
            ForEach(Array(changes.prefix(200))) { d in diffRow(d) }
            if changes.count > 200 { Text("…and \(changes.count - 200) more").font(.caption).foregroundStyle(.secondary) }
        }

        Card("Compare with another file", subtitle: "Another config.plist, a Sample.plist, or a reference EFI's config (read-only)") {
            HStack {
                Button("Choose a plist…") { compare() }
                if !otherName.isEmpty { Text(otherName).font(.caption).foregroundStyle(.secondary) }
            }
            if !otherName.isEmpty && other.isEmpty { Text("Identical.").foregroundStyle(.secondary) }
            ForEach(Array(other.prefix(200))) { d in diffRow(d) }
            if other.count > 200 { Text("…and \(other.count - 200) more").font(.caption).foregroundStyle(.secondary) }
            Text("Shown as what it would take to turn YOUR config into the other file (Added = only in the other file).")
                .font(.caption2).foregroundStyle(.secondary)
        }

        Card("Validate") {
            HStack {
                Button("Consistency check") { issues = ConfigAudit.run(config: doc.root, oc: doc.url.deletingLastPathComponent()) }
                Button { Task { await validate() } } label: { Text("Run ocvalidate") }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if !issues.isEmpty { IssueList(issues: issues) }
            if !ocv.isEmpty { MonoText(text: ocv) }
        }

        Card("Raw XML", subtitle: "The whole file as XML. Apply replaces the open config (undoable).") {
            HStack {
                Button("Load current") { xml = (try? String(data: doc.serialized(), encoding: .utf8)) ?? ""; xmlMessage = "" }
                Button("Apply XML") { applyXML() }.disabled(xml.isEmpty)
                Text(xmlMessage).font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $xml)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        }
    }

    private func diffRow(_ d: DiffEntry) -> some View {
        HStack(alignment: .top) {
            Pill(text: d.kind.rawValue.uppercased(), color: d.kind == .added ? Color.green : (d.kind == .removed ? Color.red : Color.orange))
            Text(d.display).font(.caption).textSelection(.enabled)
            Spacer()
            Text(d.kind == .changed ? "\(d.oldText) → \(d.newText)" : (d.kind == .added ? d.newText : d.oldText))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func compare() {
        guard let u = Panels.pick(message: "Choose a plist to compare with", directories: false),
              let d = try? ConfigIO.readDict(u) else { return }
        otherName = u.lastPathComponent
        other = PlistDiff.diff(doc.root, d)
    }

    private func validate() async {
        busy = true
        defer { busy = false }
        do {
            let pkg = try await OCPackageManager.latest()
            let tmp = AppPaths.cache.appendingPathComponent("validate-config.plist")
            try doc.serialized().write(to: tmp)
            let r = await Shell.run(pkg.ocvalidate.path, [tmp.path])
            ocv = "ocvalidate from OpenCore \(pkg.version):\n" + (r.combined.isEmpty ? "No problems reported." : r.combined)
        } catch {
            ocv = error.localizedDescription
        }
    }

    private func applyXML() {
        guard let data = xml.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { xmlMessage = "That isn't a valid plist dictionary."; return }
        doc.replaceRoot(dict)
        xmlMessage = "Applied."
    }
}
