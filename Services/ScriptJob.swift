import Foundation

/// Runs the embedded macROOT.sh (optionally as root) and streams its output.
///
/// Root runs go through the normal macOS admin prompt. Because that route can't stream,
/// the script's output goes to a log file which is polled while it runs.
@MainActor
final class ScriptJob: ObservableObject {
    struct Line: Identifiable {
        let id: Int
        let text: String
        let level: LogLevel
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var percent = 0
    @Published private(set) var label = ""
    @Published private(set) var running = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var owner = ""
    @Published private(set) var title = ""

    private var nextID = 0
    private var pending = ""
    private var pidFile: URL?
    private var ranPrivileged = false

    private final class Flag: @unchecked Sendable { var done = false }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")
    private static let progress = try! NSRegularExpression(pattern: "^\\[\\s*(\\d+)%\\]\\s*(.*)$")
    private static let exitMarker = "__MACROOT_EXIT__:"

    func append(_ text: String, _ level: LogLevel = .info) {
        lines.append(Line(id: nextID, text: text, level: level))
        nextID += 1
        if lines.count > 1500 { lines.removeFirst(300) }
    }

    /// Runs `macROOT.sh <args>`, or the shell `command` instead when one is given (used for
    /// things the script doesn't cover, like softwareupdate). Returns the exit code, or nil if
    /// it never started (for example the admin prompt was cancelled). `post` is a shell snippet
    /// that runs with the same privileges, only if the run succeeded.
    func run(owner: String, title: String, args: [String], privileged: Bool, post: String? = nil, command: String? = nil) async -> Int32? {
        guard !running else { return nil }
        running = true
        defer { running = false }
        self.owner = owner
        self.title = title
        label = title
        lines = []
        percent = 0
        exitCode = nil
        pending = ""
        nextID = 0
        ranPrivileged = privileged

        let userCopy = AppPaths.support.appendingPathComponent("macROOT.sh")
        if command == nil {
            do {
                try EmbeddedScript.text.write(to: userCopy, atomically: true, encoding: .utf8)
            } catch {
                append("Could not write the script: \(error.localizedDescription)", .error)
                exitCode = -1
                return nil
            }
        }

        let id = UUID().uuidString
        let log = AppPaths.cache.appendingPathComponent("job-\(id).log")
        let pid = AppPaths.cache.appendingPathComponent("job-\(id).pid")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        pidFile = pid

        let q = Shell.quote
        var sh = ""
        let target: String
        if let command = command {
            sh += "D=\n"
            target = "/bin/sh -c \(q("exec " + command))"
        } else if privileged {
            // Copy the script to a root-owned temp dir first, so what runs as root can't be swapped out.
            sh += "D=$(/usr/bin/mktemp -d /private/tmp/macroot-run.XXXXXX) || exit 1\n"
            sh += "/usr/bin/install -m 755 -o root -g wheel \(q(userCopy.path)) \"$D/macROOT.sh\" || exit 1\n"
            target = "/bin/bash \"$D/macROOT.sh\" \(args.map(q).joined(separator: " "))"
        } else {
            sh += "D=\n"
            target = "/bin/bash \(q(userCopy.path)) \(args.map(q).joined(separator: " "))"
        }
        sh += "\(target) < /dev/null >> \(q(log.path)) 2>&1 &\n"
        sh += "CHILD=$!\n"
        sh += "echo $CHILD > \(q(pid.path))\n"
        sh += "wait $CHILD\n"
        sh += "RC=$?\n"
        if let post = post { sh += "if [ $RC -eq 0 ]; then\n\(post)\nfi\n" }
        sh += "[ -n \"$D\" ] && rm -rf \"$D\"\n"
        sh += "echo \"\(Self.exitMarker)$RC\" >> \(q(log.path))\n"
        sh += "exit 0\n"

        let flag = Flag()
        let runner = Task { () -> ShellResult in
            let r = privileged ? await Shell.runPrivileged(sh) : await Shell.run("/bin/sh", ["-c", sh])
            flag.done = true
            return r
        }

        var offset: UInt64 = 0
        var exit: Int32?
        while !flag.done {
            let (chunk, newOffset) = Self.readNew(log, from: offset)
            offset = newOffset
            if let c = consume(chunk) { exit = c }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        let result = await runner.value
        let (tail, _) = Self.readNew(log, from: offset)
        if let c = consume(tail) { exit = c }
        if !pending.isEmpty {
            if let c = handle(pending) { exit = c }
            pending = ""
        }
        try? FileManager.default.removeItem(at: log)
        try? FileManager.default.removeItem(at: pid)
        pidFile = nil

        if let code = exit {
            exitCode = code
            if code == 0 { percent = 100 }
            return code
        }
        let msg = result.combined
        append(msg.contains("User canceled") ? "Administrator authentication was cancelled." : "The script did not run. \(msg)", .error)
        exitCode = -1
        return nil
    }

    func cancel() async {
        guard running, let pid = pidFile else { return }
        append("Cancel requested. The script cleans up and stops once its current command finishes.", .warning)
        let cmd = "kill -TERM $(cat \(Shell.quote(pid.path))) 2>/dev/null; exit 0"
        if ranPrivileged { _ = await Shell.runPrivileged(cmd) } else { _ = await Shell.sh(cmd) }
    }

    // MARK: Parsing

    private static func readNew(_ url: URL, from offset: UInt64) -> (String, UInt64) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ("", offset) }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: offset)
            let d = try h.readToEnd() ?? Data()
            return (String(decoding: d, as: UTF8.self), offset + UInt64(d.count))
        } catch {
            return ("", offset)
        }
    }

    private func consume(_ chunk: String) -> Int32? {
        guard !chunk.isEmpty else { return nil }
        pending += chunk
        var exit: Int32?
        while let nl = pending.firstIndex(of: "\n") {
            let raw = String(pending[..<nl])
            pending = String(pending[pending.index(after: nl)...])
            if let c = handle(raw) { exit = c }
        }
        return exit
    }

    /// Handles one output line. Returns an exit code if the line is the end-of-run marker.
    private func handle(_ raw: String) -> Int32? {
        // curl-style progress bars rewrite one line with \r; keep only the last frame.
        var text = raw.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? raw
        let ns = text as NSString
        text = Self.ansi.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        if text.hasPrefix(Self.exitMarker) {
            return Int32(text.dropFirst(Self.exitMarker.count).trimmed)
        }
        guard !text.trimmed.isEmpty else { return nil }

        let ns2 = text as NSString
        if let m = Self.progress.firstMatch(in: text, range: NSRange(location: 0, length: ns2.length)) {
            percent = Int(ns2.substring(with: m.range(at: 1))) ?? percent
            label = ns2.substring(with: m.range(at: 2))
        }
        let level: LogLevel = text.contains("[error]") ? .error : (text.contains("[warn]") ? .warning : .info)
        append(text, level)
        return nil
    }
}
