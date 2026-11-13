import Foundation

struct EFIPartition: Identifiable, Hashable {
    let id: String            // e.g. disk0s1
    let parent: String        // e.g. disk0
    var parentName: String
    var sizeBytes: Int64
    var mountPoint: String?
    var diskUUID: String?
    var isInternal: Bool

    var isMounted: Bool { !(mountPoint ?? "").isEmpty }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

enum DiskService {
    static func plist(_ args: [String]) async -> [String: Any] {
        let r = await Shell.run("/usr/sbin/diskutil", args)
        guard let obj = try? PropertyListSerialization.propertyList(from: r.outData, options: [], format: nil),
              let d = obj as? [String: Any] else { return [:] }
        return d
    }

    static func listEFI() async -> [EFIPartition] {
        let root = await plist(["list", "-plist"])
        guard let disks = root["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var result: [EFIPartition] = []
        for disk in disks {
            guard let parent = disk["DeviceIdentifier"] as? String else { continue }
            let parts = (disk["Partitions"] as? [[String: Any]]) ?? []
            let efis = parts.filter { ($0["Content"] as? String) == "EFI" }
            if efis.isEmpty { continue }
            let pInfo = await plist(["info", "-plist", parent])
            let parentName = (pInfo["MediaName"] as? String) ?? parent
            let internalDisk = (pInfo["Internal"] as? Bool) ?? false
            for e in efis {
                guard let id = e["DeviceIdentifier"] as? String else { continue }
                let eInfo = await plist(["info", "-plist", id])
                var mp = eInfo["MountPoint"] as? String
                if mp?.isEmpty == true { mp = nil }
                result.append(EFIPartition(
                    id: id, parent: parent, parentName: parentName,
                    sizeBytes: (e["Size"] as? NSNumber)?.int64Value ?? 0,
                    mountPoint: mp, diskUUID: eInfo["DiskUUID"] as? String,
                    isInternal: internalDisk))
            }
        }
        return result
    }

    static func mount(_ id: String) async -> (ok: Bool, message: String) {
        let r = await Shell.run("/usr/sbin/diskutil", ["mount", "/dev/\(id)"])
        if r.ok { return (true, r.combined) }
        let p = await Shell.runPrivileged("/usr/sbin/diskutil mount /dev/\(id)")
        return (p.ok, p.combined.isEmpty ? r.combined : p.combined)
    }

    static func unmount(_ id: String) async -> (ok: Bool, message: String) {
        let r = await Shell.run("/usr/sbin/diskutil", ["unmount", "/dev/\(id)"])
        if r.ok { return (true, r.combined) }
        let p = await Shell.runPrivileged("/usr/sbin/diskutil unmount /dev/\(id)")
        return (p.ok, p.combined.isEmpty ? r.combined : p.combined)
    }

    /// GUID of the partition OpenCore was booted from (from /chosen boot-device-path).
    static func bootEFIUUID() async -> String? {
        let nodes = await IOReg.nodes(["-p", "IODeviceTree", "-n", "chosen", "-r"])
        for n in nodes {
            for key in ["boot-device-path", "boot-path"] {
                if let d = n[key] as? Data, let g = partitionGUID(in: d) { return g }
            }
        }
        return nil
    }

    /// Walk an EFI device path and pull the GPT partition signature out of the HD() node.
    static func partitionGUID(in d: Data) -> String? {
        let b = [UInt8](d)
        var i = 0
        while i + 4 <= b.count {
            let type = b[i], sub = b[i + 1]
            let len = Int(b[i + 2]) | (Int(b[i + 3]) << 8)
            if type == 0x7F || len < 4 { break }
            if type == 0x04 && sub == 0x01 && len >= 42 && i + 42 <= b.count {
                let h = b[(i + 24)..<(i + 40)].map { String(format: "%02X", $0) }
                return "\(h[3])\(h[2])\(h[1])\(h[0])-\(h[5])\(h[4])-\(h[7])\(h[6])-\(h[8])\(h[9])-\(h[10...15].joined())"
            }
            i += len
        }
        return nil
    }
}
