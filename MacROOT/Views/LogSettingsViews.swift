import SwiftUI

struct LogView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        PageView(title: "Logs", subtitle: "Everything MacROOT has done this session") {
            if state.log.isEmpty {
                Text("Nothing logged yet.").foregroundStyle(.secondary)
            }
            ForEach(state.log.reversed()) { e in
                HStack(alignment: .top, spacing: 10) {
                    Text(e.date, style: .time).foregroundStyle(.secondary).monospacedDigit()
                    Text(e.text).textSelection(.enabled)
                        .foregroundStyle(e.level == .error ? Color.red : (e.level == .warning ? Color.orange : Color.primary))
                    Spacer()
                }
                .font(.callout)
            }
        } actions: {
            HStack {
                Button("Copy all") {
                    Panels.copy(state.log.map { "[\($0.date.formatted(date: .omitted, time: .standard))] \($0.text)" }.joined(separator: "\n"))
                }
                Button("Clear") { state.log.removeAll() }
            }
        }
    }
}
