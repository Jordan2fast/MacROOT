import SwiftUI

@MainActor
final class USBModel: ObservableObject {
    @Published var ports: [USBPort] = []
    @Published var included: Set<String> = []
    @Published var scanning = false
    @Published var model = ""

    func refresh() async {
        scanning = true
        defer { scanning = false }
        let found = await USBService.scan()
        if model.isEmpty {
            let r = await Shell.run("/usr/sbin/sysctl", ["-n", "hw.model"])
            model = r.out.trimmed
        }
        var merged = Dictionary(uniqueKeysWithValues: ports.map { ($0.id, $0) })
        for p in found {
            var port = p
            if let old = merged[p.id] { port.connector = old.connector }
            // A port that currently has a device is one the user actually uses: include it.
            if p.hasDevice { included.insert(p.id) }
            merged[p.id] = port
        }
        ports = merged.values.sorted { ($0.controller, $0.portNumber) < ($1.controller, $1.portNumber) }
    }

    var selectedPorts: [USBPort] { ports.filter { included.contains($0.id) } }
}

struct USBView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = USBModel()
    @State private var message = ""
    @State private var built: URL?

    var body: some View {
        PageView(title: "USB Mapping", subtitle: "Build a USBMap.kext from the ports you actually use") {
            Card("Workflow", subtitle: "Experimental — compare the result with USBToolBox or Hackintool before relying on it") {
                Text("""
                1. Plug a USB 2 device and a USB 3 device into each physical port, pressing Refresh after each one. Ports that see a device are ticked automatically and stay ticked.
                2. Set the connector type of every ticked port (Type-A, Type-C, or Internal for things like Bluetooth).
                3. Keep 15 ports or fewer per controller, then build the kext and install it. Afterwards turn XhciPortLimit off in the Config tab.
                """).font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("SMBIOS model", text: $vm.model).frame(width: 160)
                    Button { Task { await vm.refresh() } } label: { Label("Refresh ports", systemImage: "arrow.clockwise") }
                    if vm.scanning { ProgressView().controlSize(.small) }
                }
            }

            if vm.ports.isEmpty {
                Text("No ports scanned yet. Press Refresh ports.").foregroundStyle(.secondary)
            }

            ForEach(Dictionary(grouping: vm.ports, by: { $0.controller }).keys.sorted(), id: \.self) { ctrl in
                let group = vm.ports.filter { $0.controller == ctrl }
                let count = group.filter { vm.included.contains($0.id) }.count
                Card("Controller \(ctrl)", subtitle: "\(count) port(s) selected" + (count > 15 ? " — over the 15-port limit!" : "")) {
                    ForEach(group) { p in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { vm.included.contains(p.id) },
                                set: { on in if on { vm.included.insert(p.id) } else { vm.included.remove(p.id) } }))
                                .labelsHidden()
                            Text(p.name).font(.system(.body, design: .monospaced)).frame(width: 60, alignment: .leading)
                            Text("port \(p.portNumber)").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { vm.ports.first(where: { $0.id == p.id })?.connector ?? p.connector },
                                set: { v in if let i = vm.ports.firstIndex(where: { $0.id == p.id }) { vm.ports[i].connector = v } })) {
                                ForEach(USBService.connectorTypes) { t in Text(t.label).tag(t.value) }
                            }
                            .labelsHidden().frame(width: 190)
                            Spacer()
                            if let d = p.deviceName { Pill(text: d, color: .blue) }
                        }
                    }
                }
            }

            if !vm.ports.isEmpty {
                Card("Build") {
                    HStack {
                        Button("Build USBMap.kext") { build() }
                            .disabled(vm.selectedPorts.isEmpty || vm.model.isEmpty)
                        Button("Install into EFI + config.plist") { Task { await install() } }
                            .disabled(built == nil)
                        if let b = built { Button("Reveal") { Panels.reveal(b) } }
                    }
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .task { if vm.ports.isEmpty { await vm.refresh() } }
    }

    private func build() {
        do {
            built = try USBMapBuilder.build(ports: vm.selectedPorts, model: vm.model)
            message = "Built \(built!.path)"
            state.addLog("Built USBMap.kext with \(vm.selectedPorts.count) port(s) for \(vm.model).")
        } catch {
            message = error.localizedDescription
            state.addLog("USBMap build failed: \(error.localizedDescription)", .error)
        }
    }

    private func install() async {
        guard let kext = built, await state.ensureMounted() != nil, let oc = state.ocFolder else { message = "No mounted EFI."; return }
        if state.config?.url.path != oc.appendingPathComponent("config.plist").path { await state.loadConfigFromEFI() }
        let r = await KextInstaller.install(kext: kext, efiOC: oc, config: state.config)
        message = r.message
        state.addLog(r.message, r.ok ? .info : .error)
    }
}
