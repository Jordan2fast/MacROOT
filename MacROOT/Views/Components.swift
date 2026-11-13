import SwiftUI
import AppKit

struct PageView<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let content: Content
    let actions: Actions

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.largeTitle.bold())
                    Text(subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension PageView where Actions == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, content: content, actions: { EmptyView() })
    }
}

struct Card<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let s = subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct IssueList: View {
    let issues: [AuditIssue]

    private func icon(_ s: AuditIssue.Severity) -> String {
        switch s {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "checkmark.circle.fill"
        }
    }
    private func color(_ s: AuditIssue.Severity) -> Color {
        switch s {
        case .error: return .red
        case .warning: return .orange
        case .info: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(issues) { i in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(i.severity)).foregroundStyle(color(i.severity))
                    Text(i.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct MonoText: View {
    let text: String
    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: 80, maxHeight: 260)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
    }
}

enum Panels {
    @MainActor
    static func pick(message: String, directories: Bool = true, files: Bool = true) -> URL? {
        let p = NSOpenPanel()
        p.message = message
        p.canChooseFiles = files
        p.canChooseDirectories = directories
        p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
