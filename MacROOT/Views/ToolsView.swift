import SwiftUI

struct ToolAction: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let script: String
    let privileged: Bool
    let confirm: String?
}

struct ToolsView: View {
    @EnvironmentObject var state: AppState
    @State private var pending: ToolAction?
    @State private var output = ""
    @State private var checks: [AuditIssue] = []
    @State private var checking = false

    private let actions: [ToolAction] = [
        ToolAction(title: "Rebuild kext cache",
                   detail: "Rebuilds the kernel/kext caches after changing /Library/Extensions.",
                   script: "/usr/sbin/kextcache -i /", privileged: true, confirm: nil),
        ToolAction(title: "Restart Core Audio",
                   detail: "Restarts coreaudiod — handy after changing AppleALC layout-id.",
                   script: "/usr/bin/killall coreaudiod", privileged: true, confirm: nil),
        ToolAction(title: "Apply hackintosh sleep settings",
                   detail: "pmset: hibernatemode 0, standby 0, powernap 0, proximitywake 0, tcpkeepalive 0, autopoweroff 0. The usual fix for sleep/wake problems.",
                   script: "/usr/bin/pmset -a hibernatemode 0 standby 0 powernap 0 proximitywake 0 tcpkeepalive 0 autopoweroff 0",
                   privileged: true, confirm: "This changes power-management defaults for every power source."),
        ToolAction(title: "Show current power settings",
                   detail: "Runs pmset -g to show what is active.",
                   script: "/usr/bin/pmset -g", privileged: false, confirm: nil),
        ToolAction(title: "Show NVRAM boot variables",
                   detail: "boot-args, csr-active-config and the OpenCore version string.",
                   script: "/usr/sbin/nvram -p | grep -E 'boot-args|csr-active-config|opencore|boot-path' || true",
                   privileged: false, confirm: nil),
        ToolAction(title: "Reset NVRAM from macOS",
                   detail: "nvram -c. OpenCore's own 'Reset NVRAM' picker entry is the safer way if you have it.",
                   script: "/usr/sbin/nvram -c", privileged: true,
                   confirm: "This deletes NVRAM variables, including boot-args set from macOS. You may need to reboot afterwards.")
    ]

    var body: some View {
        PageView(title: "Tools", subtitle: "Quick fixes and sanity checks for Hackintosh systems") {
            Card("Apple services check", subtitle: "Looks at the things iMessage/FaceTime/App Store registration depend on") {
                HStack {
                    Button { Task { await runChecks() } } label: { Label("Run check", systemImage: "checkmark.shield") }
                        .disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                }
                if !checks.isEmpty { IssueList(issues: checks) }
            }

            Card("Quick actions") {
                ForEach(actions) { a in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(.subheadline.bold())
                            Text(a.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if a.privileged { Pill(text: "ADMIN", color: .orange) }
                        Button("Run") {
                            if a.confirm != nil { pending = a } else { Task { await run(a) } }
                        }
                    }
                    Divider()
                }
            }

            if !output.isEmpty {
                Card("Output") { MonoText(text: output) }
            }
        }
        .confirmationDialog("Run \(pending?.title ?? "")?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Run", role: .destructive) { if let a = pending { Task { await run(a) } } }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.confirm ?? "")
        }
    }

    private func run(_ a: ToolAction) async {
        pending = nil
        state.busyMessage = "\(a.title)…"
        defer { state.busyMessage = nil }
        let r = a.privileged ? await Shell.runPrivileged(a.script) : await Shell.sh(a.script)
        output = "$ \(a.script)\n\(r.combined)"
        state.addLog("\(a.title): \(r.ok ? "ok" : "failed (\(r.status))")", r.ok ? .info : .error)
    }

    private func runChecks() async {
        checking = true
        defer { checking = false }
        checks = await ServiceCheck.run(config: state.config?.root)
    }
}
