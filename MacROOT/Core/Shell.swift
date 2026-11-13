import Foundation

struct ShellResult {
    let status: Int32
    let outData: Data
    let err: String
    var out: String { String(decoding: outData, as: UTF8.self) }
    var ok: Bool { status == 0 }
    /// stdout + stderr, trimmed, for logging.
    var combined: String {
        let o = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        return [o, e].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

enum Shell {
    /// Single-quote a string for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run an executable without blocking the caller's thread. Output is drained
    /// while the process runs, so very large output (e.g. `ioreg -l`) is safe.
    static func run(_ path: String, _ args: [String] = [], cwd: URL? = nil) async -> ShellResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ShellResult, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if let cwd = cwd { p.currentDirectoryURL = cwd }
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = FileHandle.nullDevice
            let outBox = DataBox()
            let errBox = DataBox()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { outBox.append(d) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { errBox.append(d) }
            }
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: ShellResult(status: proc.terminationStatus,
                                                   outData: outBox.value,
                                                   err: String(decoding: errBox.value, as: UTF8.self)))
            }
            do {
                try p.run()
            } catch {
                cont.resume(returning: ShellResult(status: -1, outData: Data(),
                                                   err: "Failed to launch \(path): \(error.localizedDescription)"))
            }
        }
    }

    static func sh(_ command: String) async -> ShellResult {
        await run("/bin/sh", ["-c", command])
    }

    /// Run a shell script as root via the standard macOS admin-password prompt.
    /// The script is written to a temp file so quoting never gets mangled.
    static func runPrivileged(_ script: String) async -> ShellResult {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macroot-\(UUID().uuidString).sh")
        do {
            try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return ShellResult(status: -1, outData: Data(), err: "Could not write temp script: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let cmd = "/bin/sh " + quote(url.path) + " 2>&1"
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
}
