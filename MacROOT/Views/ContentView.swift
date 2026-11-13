import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.section) {
                ForEach(SidebarGroup.all) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            Label(item.rawValue, systemImage: item.icon).tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected EFI").font(.caption2).foregroundStyle(.secondary)
                    if let p = state.selectedPartition {
                        Text("\(p.id) · \(p.isMounted ? "mounted" : "not mounted")").font(.caption)
                    } else {
                        Text("none found").font(.caption)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            ZStack(alignment: .bottom) {
                detail
                if let msg = state.busyMessage {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(msg) }
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 16)
                }
            }
        }
        .task { await state.refreshPartitions() }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.section ?? .dashboard {
        case .dashboard: DashboardView()
        case .efi: EFIView()
        case .updater: UpdaterView()
        case .upgrade: UpgradeView()
        case .config: ConfigView()
        case .iservices: IServicesView(job: state.script)
        case .backups: BackupsView()
        case .settings: PageView(title: "Settings", subtitle: "Also available from the app menu (⌘,)") { SettingsView().frame(minHeight: 560) }
        case .about: PageView(title: "About & Credits", subtitle: "The tools this app uses and learned from") { CreditsContent() }
        case .smbios: SMBIOSView()
        case .usb: USBView()
        case .kextBuilder: KextBuilderView()
        case .installer: InstallerView(job: state.script)
        case .debloat: DebloatView(job: state.script)
        case .toolkit: ToolkitView(job: state.script)
        case .tools: ToolsView()
        case .logs: LogView()
        }
    }
}
