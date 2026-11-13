import Foundation

struct BackupEntry: Identifiable {
    enum Kind: String { case efi = "EFI", config = "config.plist", other = "Other" }
    let url: URL
    let date: Date
    let kind: Kind
    let bytes: Int64
    var id: String { url.path }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

enum Backups {
    static func list() -> [BackupEntry] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: AppPaths.backups, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        var out: [BackupEntry] = []
        for u in items {
            let name = u.lastPathComponent
            if name.hasPrefix(".") { continue }
            let rv = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let date = rv?.contentModificationDate ?? .distantPast
            let kind: BackupEntry.Kind = name.hasPrefix("EFI-") ? .efi : (name.hasSuffix(".bak") ? .config : .other)
            out.append(BackupEntry(url: u, date: date, kind: kind, bytes: size(of: u)))
        }
        return out.sorted { $0.date > $1.date }
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        return total
    }

    static var keepCount: Int {
        let v = UserDefaults.standard.integer(forKey: "keepBackups")
        return v > 0 ? v : 20
    }

    /// Keeps the newest `keepCount` EFI backups and the newest `keepCount` config backups.
    static func prune(force: Bool = false) {
        let auto = (UserDefaults.standard.object(forKey: "autoPruneBackups") as? Bool) ?? true
        guard auto || force else { return }
        let all = list()
        for kind in [BackupEntry.Kind.efi, .config] {
            for old in all.filter({ $0.kind == kind }).dropFirst(keepCount) {
                try? FileManager.default.removeItem(at: old.url)
            }
        }
    }

    static func restoreConfig(_ backup: URL, to dest: URL) async -> String? {
        guard let data = try? Data(contentsOf: backup) else { return "Couldn't read the backup." }
        FileOps.backupFile(dest)
        return await FileOps.write(data, to: dest)
    }

    /// Copies the backed-up EFI over the mounted one (files added since stay). The current EFI is backed up first.
    static func restoreEFI(_ backup: URL, to efi: URL) async -> String? {
        let src = backup.appendingPathComponent("EFI")
        guard FileManager.default.fileExists(atPath: src.path) else { return "That backup has no EFI folder." }
        do { _ = try await FileOps.backupEFI(efi) } catch { return "Couldn't back up the current EFI first: \(error.localizedDescription)" }
        let priv = !FileOps.isWritable(efi)
        let r = await FileOps.runScript("/usr/bin/ditto --norsrc --noextattr --noqtn \(Shell.quote(src.path)) \(Shell.quote(efi.path))", privileged: priv)
        return r.ok ? nil : r.combined
    }
}
