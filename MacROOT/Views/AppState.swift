import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case efi = "EFI Mounter"
    case upgrade = "Upgrade Assistant"
    case updater = "OpenCore & Kexts"
    case config = "Config Studio"
    case smbios = "SMBIOS"
    case iservices = "iServices"
    case usb = "USB Mapping"
    case kextBuilder = "Kext Builder"
    case installer = "macOS Installer"
    case debloat = "Debloat"
    case toolkit = "Toolkit & VM"
    case tools = "Tools"
    case backups = "Backups"
    case logs = "Logs"
    case settings = "Settings"
    case about = "About & Credits"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "chart.bar"
        case .efi: return "externaldrive"
        case .upgrade: return "arrow.up.forward.app"
        case .updater: return "arrow.triangle.2.circlepath"
        case .config: return "doc.text"
        case .smbios: return "number"
        case .iservices: return "message"
        case .usb: return "cable.connector"
        case .kextBuilder: return "puzzlepiece.extension"
        case .installer: return "opticaldiscdrive"
        case .debloat: return "scissors"
        case .toolkit: return "shippingbox"
        case .tools: return "wrench.and.screwdriver"
        case .backups: return "clock.arrow.circlepath"
        case .logs: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct SidebarGroup: Identifiable {
    let title: String
    let items: [SidebarItem]
    var id: String { title }

    static let all: [SidebarGroup] = [
        SidebarGroup(title: "Overview", items: [.dashboard]),
        SidebarGroup(title: "OpenCore", items: [.efi, .upgrade, .updater, .config, .smbios, .iservices, .usb, .kextBuilder]),
        SidebarGroup(title: "macOS", items: [.installer, .debloat, .toolkit]),
        SidebarGroup(title: "Utilities", items: [.tools, .backups, .logs]),
        SidebarGroup(title: "App", items: [.settings, .about])
    ]
}

enum LogLevel { case info, warning, error }

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    let level: LogLevel
}

@MainActor
final class AppState: ObservableObject {
    @Published var section: SidebarItem? = .dashboard
    @Published var partitions: [EFIPartition] = []
    @Published var bootEFIUUID: String?
    @Published var selectedEFIID: String?
    @Published var config: ConfigDocument?
    @Published var log: [LogEntry] = []
    @Published var busyMessage: String?
    /// One macROOT.sh run at a time, shared by the Installer, Debloat and Toolkit pages.
    let script = ScriptJob()

    var selectedPartition: EFIPartition? { partitions.first(where: { $0.id == selectedEFIID }) }
    var efiFolder: URL? {
        selectedPartition?.mountPoint.map { URL(fileURLWithPath: $0).appendingPathComponent("EFI") }
    }
    var ocFolder: URL? { efiFolder?.appendingPathComponent("OC") }

    func isBootEFI(_ p: EFIPartition) -> Bool {
        guard let a = p.diskUUID?.uppercased(), let b = bootEFIUUID?.uppercased() else { return false }
        return a == b
    }

    func addLog(_ text: String, _ level: LogLevel = .info) {
        log.append(LogEntry(text: text, level: level))
    }

    func refreshPartitions() async {
        let parts = await DiskService.listEFI()
        let boot = await DiskService.bootEFIUUID()
        partitions = parts
        bootEFIUUID = boot
        if selectedEFIID == nil || !parts.contains(where: { $0.id == selectedEFIID }) {
            selectedEFIID = parts.first(where: { isBootEFI($0) })?.id ?? parts.first?.id
        }
    }

    /// Mounts the selected EFI if needed and returns it (nil on failure).
    func ensureMounted() async -> EFIPartition? {
        guard let sel = selectedPartition else {
            addLog("No EFI partition found or selected.", .warning)
            return nil
        }
        if sel.isMounted { return sel }
        busyMessage = "Mounting \(sel.id)…"
        defer { busyMessage = nil }
        let r = await DiskService.mount(sel.id)
        addLog(r.message.isEmpty ? "Mount \(sel.id): \(r.ok ? "ok" : "failed")" : r.message, r.ok ? .info : .error)
        await refreshPartitions()
        if let p = selectedPartition, p.isMounted { return p }
        return nil
    }

    func loadConfig(from url: URL) {
        do {
            config = try ConfigDocument.load(url)
            addLog("Loaded \(url.path)")
        } catch {
            addLog("Could not read \(url.path): \(error.localizedDescription)", .error)
        }
    }

    func loadConfigFromEFI() async {
        guard let p = await ensureMounted(), let mp = p.mountPoint else { return }
        loadConfig(from: URL(fileURLWithPath: mp).appendingPathComponent("EFI/OC/config.plist"))
    }
}
