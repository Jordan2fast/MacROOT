import Foundation
import CryptoKit

extension Data {
    /// First 4 bytes as a little-endian UInt32 (IORegistry stores IDs this way).
    var leUInt32: UInt32 {
        var v: UInt32 = 0
        for (i, b) in self.prefix(4).enumerated() { v |= UInt32(b) << UInt32(8 * i) }
        return v
    }
    static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    var hex: String { map { String(format: "%02X", $0) }.joined() }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Version {
    static func parts(_ s: String) -> [Int] {
        s.split(whereSeparator: { !($0.isASCII && $0.isNumber) }).compactMap { Int($0) }
    }
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        compare(latest, installed) == .orderedDescending
    }
}

enum AppPaths {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return sub(base, "MacROOT")
    }
    static var cache: URL { sub(support, "Cache") }
    static var backups: URL { sub(documents, "MacROOT Backups") }
    static var kextProjects: URL { sub(documents, "MacROOT Kexts") }

    private static func sub(_ base: URL, _ name: String) -> URL {
        let u = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

enum Keychain {
    private static let service = "com.pine.MacROOT"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum FileOps {
    static func sha256(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isWritable(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: url.path)
    }

    /// Write data to `url`; falls back to an admin-privileged copy when needed.
    /// Returns an error message, or nil on success.
    static func write(_ data: Data, to url: URL) async -> String? {
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {}
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try data.write(to: tmp) } catch { return error.localizedDescription }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = await Shell.runPrivileged("/usr/bin/ditto --norsrc --noextattr --noqtn \(Shell.quote(tmp.path)) \(Shell.quote(url.path))")
        return r.ok ? nil : r.combined
    }

    static func runScript(_ script: String, privileged: Bool) async -> ShellResult {
        if privileged { return await Shell.runPrivileged(script) }
        return await Shell.run("/bin/sh", ["-c", script])
    }

    /// Copy the whole EFI folder to ~/Documents/MacROOT Backups/EFI-<timestamp>/EFI
    static func backupEFI(_ efi: URL) async throws -> URL {
        let dest = AppPaths.backups.appendingPathComponent("EFI-" + AppPaths.timestamp(), isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let target = dest.appendingPathComponent("EFI")
        try await Task.detached { try FileManager.default.copyItem(at: efi, to: target) }.value
        Backups.prune()
        return dest
    }

    @discardableResult
    static func backupFile(_ url: URL) -> URL? {
        let dest = AppPaths.backups.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(AppPaths.timestamp()).\(url.pathExtension).bak")
        do { try FileManager.default.copyItem(at: url, to: dest); Backups.prune(); return dest } catch { return nil }
    }
}
