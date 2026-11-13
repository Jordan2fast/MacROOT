import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @State private var info: SystemInfo?

    var body: some View {
        PageView(title: "Dashboard", subtitle: "What this Hackintosh looks like right now") {
            if let i = info {
                Card("System") {
                    LabeledContent("Model identifier", value: i.model)
                    LabeledContent("CPU", value: i.cpu)
                    LabeledContent("Memory", value: i.memory)
                    LabeledContent("macOS", value: i.macOS)
                    LabeledContent("GPU(s)", value: i.gpus.isEmpty ? "—" : i.gpus.joined(separator: ", "))
                }
                Card("Boot & security") {
                    LabeledContent("OpenCore", value: i.openCore)
                    LabeledContent("SIP", value: i.sip)
                    LabeledContent("boot-args", value: i.bootArgs)
                }
                Card("Apple identity", subtitle: "What macOS currently reports to Apple services") {
                    LabeledContent("Serial", value: i.serial)
                    LabeledContent("Board ID", value: i.boardID)
                    LabeledContent("Platform UUID", value: i.uuid)
                }
                Card("Third-party kexts loaded", subtitle: "\(i.thirdPartyKexts.count) loaded") {
                    if i.thirdPartyKexts.isEmpty {
                        Text("None reported by kextstat.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(i.thirdPartyKexts.enumerated()), id: \.offset) { _, k in
                            HStack {
                                Text(k.name).textSelection(.enabled)
                                Spacer()
                                Text(k.version).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                ProgressView("Reading system…")
            }
        } actions: {
            HStack {
                Button { Task { await copyReport() } } label: { Label("Copy support report", systemImage: "doc.on.clipboard") }
                    .disabled(info == nil)
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .task { if info == nil { await load() } }
    }

    /// Plain-text summary for forum posts. Serial, MLB, UUID and ROM are never included.
    private func copyReport() async {
        guard let i = info else { return }
        let pci = await PCIScanner.scan()
        var t = "MacROOT \(AppInfo.version) support report\n"
        t += "Model: \(i.model)\nCPU: \(i.cpu)\nMemory: \(i.memory)\nmacOS: \(i.macOS)\n"
        t += "OpenCore: \(i.openCore)\nSIP: \(i.sip)\nboot-args: \(i.bootArgs)\n"
        t += "GPU(s): \(i.gpus.joined(separator: ", "))\n\nLoaded third-party kexts:\n"
        t += i.thirdPartyKexts.map { "  \($0.name) \($0.version)" }.joined(separator: "\n")
        t += "\n\nPCI devices:\n"
        t += pci.filter { $0.baseClass != 0x06 }.map { "  \($0.idString) \($0.vendorName) · \($0.kind) · \($0.name) · driver: \($0.driverClass ?? "none")" }.joined(separator: "\n")
        if let doc = state.config {
            t += "\n\nconfig.plist: \(doc.url.path)\n"
            t += "SMBIOS model: \(doc.string(["PlatformInfo", "Generic", "SystemProductName"]) ?? "-")\n"
            t += "SecureBootModel: \(doc.string(["Misc", "Security", "SecureBootModel"]) ?? "-")\n"
            let kexts = (doc.value(["Kernel", "Add"]) as? [[String: Any]]) ?? []
            t += "Enabled kexts: " + kexts.filter { PlistTree.isTrue($0["Enabled"]) }.compactMap { $0["BundlePath"] as? String }.joined(separator: ", ")
        }
        Panels.copy(t)
        state.addLog("Support report copied to the clipboard (serial, MLB, UUID and ROM are left out).")
    }

    private func load() async {
        info = nil
        info = await SystemInfoService.gather()
    }
}
