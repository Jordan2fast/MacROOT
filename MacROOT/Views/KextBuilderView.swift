import SwiftUI

extension AppState {
    /// Copies a kext into the selected EFI and registers it in config.plist.
    func installKextIntoEFI(_ kext: URL) async -> String {
        guard await ensureMounted() != nil, let oc = ocFolder else { return "No mounted EFI." }
        if config?.url.path != oc.appendingPathComponent("config.plist").path { await loadConfigFromEFI() }
        let r = await KextInstaller.install(kext: kext, efiOC: oc, config: config)
        addLog(r.message, r.ok ? .info : .error)
        return r.message
    }
}

@MainActor
final class KextBuilderModel: ObservableObject {
    @Published var devices: [PCIDevice] = []
    @Published var selectedID: String?
    @Published var scanning = false
    @Published var onlyUnsupported = true

    var visible: [PCIDevice] {
        devices.filter { $0.baseClass != 0x06 && (!onlyUnsupported || !$0.hasDriver) }
    }
    var selected: PCIDevice? { devices.first(where: { $0.id == selectedID }) }

    func scan() async {
        scanning = true
        defer { scanning = false }
        devices = await PCIScanner.scan()
        if selected == nil || !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
    }
}

enum BuilderMode: String, CaseIterable, Identifiable {
    case spoofKext = "Spoof: injector kext"
    case spoofProps = "Spoof: DeviceProperties"
    case ai = "AI driver generator"
    var id: String { rawValue }
}

struct KextBuilderView: View {
    @StateObject private var vm = KextBuilderModel()
    @State private var mode: BuilderMode = .spoofKext

    var body: some View {
        PageView(title: "Kext Builder",
                 subtitle: "Get unsupported hardware working — by spoofing a supported driver, or by having AI draft one") {
            Card("Read this first") {
                Text("""
                Spoofing and AI-generated drivers are best-effort and may simply not work. Many drivers check device IDs in code, and hardware that needs proprietary firmware (most Wi-Fi/Bluetooth chips) can't be fixed by either method. Kernel code can hang or panic the machine, so keep a known-good EFI backup and test with a spare boot entry first.
                """)
                .font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                deviceList.frame(width: 340)
                VStack(alignment: .leading, spacing: 16) {
                    if let d = vm.selected {
                        header(d)
                        Picker("Method", selection: $mode) {
                            ForEach(BuilderMode.allCases) { m in Text(m.rawValue).tag(m) }
                        }
                        .pickerStyle(.segmented)
                        switch mode {
                        case .spoofKext: SpoofKextPanel(device: d).id(d.id)
                        case .spoofProps: SpoofPropsPanel(device: d).id(d.id)
                        case .ai: AIKextPanel(device: d).id(d.id)
                        }
                    } else {
                        Text(vm.scanning ? "Scanning PCI devices…" : "Select a device on the left.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            Button { Task { await vm.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
        }
        .task { if vm.devices.isEmpty { await vm.scan() } }
    }

    private var deviceList: some View {
        Card("PCI devices") {
            Toggle("Only devices with no driver attached", isOn: $vm.onlyUnsupported)
                .onChange(of: vm.onlyUnsupported) { _ in
                    if !vm.visible.contains(where: { $0.id == vm.selectedID }) { vm.selectedID = vm.visible.first?.id }
                }
            if vm.visible.isEmpty {
                Text(vm.scanning ? "Scanning…" : "Nothing to show. Untick the filter to list every device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(vm.visible) { d in
                Button { vm.selectedID = d.id } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.subheadline.bold())
                            Text("\(d.vendorName) · \(d.idString) · \(d.kind)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Pill(text: d.hasDriver ? "DRIVER" : "NO DRIVER", color: d.hasDriver ? .green : .orange)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(vm.selectedID == d.id ? Color.accentColor.opacity(0.15) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func header(_ d: PCIDevice) -> some View {
        Card(d.name, subtitle: "\(d.vendorName) · \(d.kind)") {
            LabeledContent("PCI ID", value: d.idString)
            LabeledContent("Subsystem", value: d.subsystemString)
            LabeledContent("IOPCIMatch", value: d.ioPCIMatch)
            LabeledContent("Device path", value: d.ocPath ?? "unavailable")
            LabeledContent("Attached driver", value: d.driverClass ?? "none")
        }
    }
}

// MARK: - Spoof: injector kext

struct SpoofKextPanel: View {
    let device: PCIDevice
    @EnvironmentObject var state: AppState
    @State private var donor: DonorKext?
    @State private var personalityID = ""
    @State private var name = ""
    @State private var built: URL?
    @State private var message = ""

    var body: some View {
        Card("Injector kext", subtitle: "Re-targets an existing driver at \(device.idString) — no compiler needed") {
            Text("Choose a kext that already drives a similar chip (for example IntelMausi.kext for an Intel NIC). MacROOT clones one of its personalities and points it at this device's PCI ID. It only works if that driver doesn't hard-code device IDs.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Choose donor kext…") { choose() }
                if let d = donor { Text("\(d.url.lastPathComponent) · \(d.bundleID) \(d.version)").font(.caption).foregroundStyle(.secondary) }
            }
            if let d = donor {
                Picker("Personality", selection: $personalityID) {
                    ForEach(d.personalities) { p in Text("\(p.id) — \(p.ioClass) on \(p.providerClass)").tag(p.id) }
                }
                TextField("Injector name", text: $name).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Build injector") { build(d) }.disabled(personalityID.isEmpty || name.trimmed.isEmpty)
                    if let b = built {
                        Button("Install into EFI + config.plist") { Task { message = await state.installKextIntoEFI(b) } }
                        Button("Reveal") { Panels.reveal(b) }
                    }
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { if name.isEmpty { name = "Spoof\(String(format: "%04X%04X", UInt32(device.vendor), UInt32(device.device)))" } }
    }

    private func choose() {
        guard let u = Panels.pick(message: "Choose the donor .kext") else { return }
        do {
            let d = try SpoofBuilder.loadDonor(u)
            donor = d
            personalityID = d.personalities.first?.id ?? ""
            built = nil
            message = ""
        } catch {
            message = error.localizedDescription
        }
    }

    private func build(_ d: DonorKext) {
        guard let p = d.personalities.first(where: { $0.id == personalityID }) else { return }
        do {
            let k = try SpoofBuilder.buildInjector(name: name, device: device, donor: d, personality: p)
            built = k
            message = "Built \(k.path)"
            state.addLog("Built injector \(k.lastPathComponent) for \(device.idString) using \(d.bundleID)/\(p.id).")
        } catch {
            message = error.localizedDescription
            state.addLog("Injector build failed: \(error.localizedDescription)", .error)
        }
    }
}

// MARK: - Spoof: DeviceProperties

struct SpoofPropsPanel: View {
    let device: PCIDevice
    @EnvironmentObject var state: AppState
    @State private var spoofDevice = ""
    @State private var spoofVendor = ""
    @State private var compatible = ""
    @State private var message = ""

    private func hex(_ s: String) -> UInt16? {
        let t = s.trimmed.replacingOccurrences(of: "0x", with: "")
        return t.isEmpty ? nil : UInt16(t, radix: 16)
    }
    private var props: [String: Any] {
        SpoofBuilder.deviceProperties(deviceID: hex(spoofDevice), vendorID: hex(spoofVendor), compatible: compatible)
    }

    var body: some View {
        Card("DeviceProperties spoof", subtitle: "Makes macOS see a different ID — the classic fix for GPUs, NVMe and some NICs") {
            Text("Enter the ID of a supported sibling chip (hex, e.g. 3E92). OpenCore injects the properties at boot, so the device shows up as that chip. This edits config.plist, not a kext.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("device-id (hex)", text: $spoofDevice).frame(width: 140)
                TextField("vendor-id (optional)", text: $spoofVendor).frame(width: 160)
                TextField("compatible (optional, e.g. pci8086,3e92)", text: $compatible)
            }
            .textFieldStyle(.roundedBorder)
            if let path = device.ocPath {
                LabeledContent("Target", value: path)
                if !props.isEmpty { MonoText(text: SpoofBuilder.xmlSnippet(devicePath: path, props: props)) }
                HStack {
                    Button("Copy snippet") { Panels.copy(SpoofBuilder.xmlSnippet(devicePath: path, props: props)) }
                        .disabled(props.isEmpty)
                    Button("Add to config.plist") { Task { await apply(path) } }
                        .disabled(props.isEmpty)
                }
            } else {
                Text("Couldn't work out this device's OpenCore path from the IORegistry (no acpi-path). Use Hackintool's PCI tab to get it.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func apply(_ path: String) async {
        if state.config == nil { await state.loadConfigFromEFI() }
        guard let doc = state.config else { message = "No config.plist loaded."; return }
        doc.mergeDeviceProperties(devicePath: path, props: props)
        if let err = await doc.save() {
            message = "Save failed: \(err)"
            state.addLog("Saving DeviceProperties failed: \(err)", .error)
        } else {
            message = "Added to \(doc.url.path) (previous file backed up)."
            state.addLog("Added DeviceProperties spoof for \(path) to config.plist.")
        }
    }
}

// MARK: - AI generator

struct AIKextPanel: View {
    let device: PCIDevice
    @EnvironmentObject var state: AppState
    @State private var name = ""
    @State private var bundleID = ""
    @State private var notes = ""
    @State private var working = false
    @State private var project: AIKextProject?
    @State private var raw = ""
    @State private var projectDir: URL?
    @State private var buildLog = ""
    @State private var built: URL?
    @State private var message = ""

    var body: some View {
        Card("AI driver generator", subtitle: "Experimental — sends the device's IDs (not your files) to the Anthropic API using your key from Settings") {
            Text("Claude drafts a kext for this device and says how confident it is. It will decline when a real driver would need firmware or documentation it doesn't have. Always read the generated code before loading it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Kext name", text: $name)
                TextField("Bundle identifier", text: $bundleID)
            }
            .textFieldStyle(.roundedBorder)
            TextField("Notes for the AI (what the device is, what works, what you want)", text: $notes, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button { Task { await generate() } } label: { Label("Generate with AI", systemImage: "sparkles") }
                    .disabled(working || name.trimmed.isEmpty)
                Button { Task { await buildProject() } } label: { Label("Write files & compile", systemImage: "hammer") }
                    .disabled(working || (project?.files.isEmpty ?? true))
                if working { ProgressView().controlSize(.small) }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }

            if let p = project {
                Divider()
                HStack {
                    Text("Result").font(.subheadline.bold())
                    if let c = p.confidence { Pill(text: "CONFIDENCE: \(c.uppercased())", color: c.lowercased() == "high" ? .green : (c.lowercased() == "medium" ? .orange : .red)) }
                }
                Text(p.summary).textSelection(.enabled)
                if let a = p.approach, !a.isEmpty { Text(a).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if let n = p.notes, !n.isEmpty {
                    ForEach(Array(n.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)").font(.caption).textSelection(.enabled)
                    }
                }
                if p.files.isEmpty {
                    Text("No files were produced — the model judged that a driver isn't realistic here.").font(.caption).foregroundStyle(.orange)
                } else {
                    Text(p.files.map { "\($0.path) (\($0.content.count) chars)" }.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                }
            }
            if !raw.isEmpty {
                DisclosureGroup("Raw model reply") { MonoText(text: raw) }
            }
            if !buildLog.isEmpty { DisclosureGroup("Build log") { MonoText(text: buildLog) } }
            if let dir = projectDir {
                HStack {
                    Button("Reveal project") { Panels.reveal(dir) }
                    if let b = built {
                        Button("Install into EFI + config.plist") { Task { message = await state.installKextIntoEFI(b) } }
                    }
                }
            }
        }
        .onAppear {
            if name.isEmpty {
                name = "MacROOT\(String(format: "%04X%04X", UInt32(device.vendor), UInt32(device.device)))"
                bundleID = "com.macroot.\(name)"
            }
        }
    }

    private func generate() async {
        working = true
        defer { working = false }
        message = "Asking the model… this can take a minute or two."
        built = nil
        buildLog = ""
        let v = await Shell.run("/usr/bin/sw_vers", ["-productVersion"])
        do {
            let r = try await AIKextClient.generate(device: device, kextName: SpoofBuilder.safeName(name), bundleID: bundleID,
                                                    notes: notes, macOS: v.out.trimmed)
            project = r.project
            raw = r.raw
            message = r.project == nil ? "The reply wasn't valid JSON — see the raw reply below." : "Done."
            state.addLog("AI generator finished for \(device.idString) (\(r.project?.files.count ?? 0) file(s)).")
        } catch {
            message = error.localizedDescription
            state.addLog("AI generator failed: \(error.localizedDescription)", .error)
        }
    }

    private func buildProject() async {
        guard let p = project else { return }
        working = true
        defer { working = false }
        do {
            let dir = try AIKextClient.write(p, name: name)
            projectDir = dir
            let n = SpoofBuilder.safeName(name)
            let r = await KextCompiler.build(projectDir: dir, name: n, bundleID: bundleID)
            buildLog = r.log
            built = r.kext
            message = r.ok ? "Built \(n).kext." : "Build failed — generated code often needs fixes. See the build log."
            state.addLog("Kext compile \(r.ok ? "succeeded" : "failed") for \(n).", r.ok ? .info : .warning)
        } catch {
            message = error.localizedDescription
            state.addLog("Writing AI project failed: \(error.localizedDescription)", .error)
        }
    }
}
