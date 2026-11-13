import Foundation

/// Thin helpers around `ioreg -a` (XML plist output).
enum IOReg {
    static func nodes(_ args: [String]) async -> [[String: Any]] {
        let r = await Shell.run("/usr/sbin/ioreg", args + ["-a"])
        guard r.ok, !r.outData.isEmpty,
              let obj = try? PropertyListSerialization.propertyList(from: r.outData, options: [], format: nil),
              let arr = obj as? [[String: Any]] else { return [] }
        return arr
    }

    static func kids(_ n: [String: Any]) -> [[String: Any]] {
        (n["IORegistryEntryChildren"] as? [[String: Any]]) ?? []
    }
    static func name(_ n: [String: Any]) -> String { (n["IORegistryEntryName"] as? String) ?? "" }
    static func cls(_ n: [String: Any]) -> String {
        (n["IOObjectClass"] as? String) ?? (n["IOClass"] as? String) ?? ""
    }

    static func walk(_ nodes: [[String: Any]], ancestors: [[String: Any]] = [],
                     _ visit: ([String: Any], [[String: Any]]) -> Void) {
        for n in nodes {
            visit(n, ancestors)
            walk(kids(n), ancestors: ancestors + [n], visit)
        }
    }

    static func u32(_ any: Any?) -> UInt32? {
        if let d = any as? Data { return d.leUInt32 }
        if let n = any as? NSNumber { return n.uint32Value }
        return nil
    }

    static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let d = any as? Data {
            return String(data: d, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return nil
    }
}

struct PCIDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let vendor: UInt16
    let device: UInt16
    let subVendor: UInt16
    let subDevice: UInt16
    let classCode: UInt32
    let acpiPath: String?
    let ocPath: String?
    let driverClass: String?
    let hasDriver: Bool

    static let vendors: [UInt16: String] = [
        0x8086: "Intel", 0x10EC: "Realtek", 0x14E4: "Broadcom", 0x168C: "Qualcomm Atheros",
        0x1969: "Atheros", 0x10DE: "NVIDIA", 0x1002: "AMD/ATI", 0x1022: "AMD", 0x144D: "Samsung",
        0x15B7: "SanDisk/WD", 0x1B4B: "Marvell", 0x1987: "Phison", 0x2646: "Kingston",
        0xC0A9: "Micron/Crucial", 0x1C5C: "SK hynix", 0x1B21: "ASMedia", 0x1912: "Renesas",
        0x1106: "VIA", 0x14C3: "MediaTek"
    ]

    var vendorName: String { Self.vendors[vendor] ?? "Unknown vendor" }
    var idString: String { String(format: "%04X:%04X", UInt32(vendor), UInt32(device)) }
    var subsystemString: String { String(format: "%04X:%04X", UInt32(subVendor), UInt32(subDevice)) }
    /// Value for an IOPCIMatch personality key: 0x<device><vendor>
    var ioPCIMatch: String { String(format: "0x%04x%04x", UInt32(device), UInt32(vendor)) }
    var baseClass: UInt32 { (classCode >> 16) & 0xFF }
    var kind: String {
        switch baseClass {
        case 0x01: return "Storage"
        case 0x02: return "Network"
        case 0x03: return "Display / GPU"
        case 0x04: return "Audio / Multimedia"
        case 0x06: return "Bridge"
        case 0x07: return "Communication"
        case 0x08: return "System peripheral"
        case 0x0C: return "Serial bus (USB etc.)"
        case 0x0D: return "Wireless"
        case 0x11: return "Signal processing"
        default: return String(format: "Class 0x%02X", baseClass)
        }
    }
}

enum PCIScanner {
    static func scan() async -> [PCIDevice] {
        let roots = await IOReg.nodes(["-r", "-c", "IOPCIDevice", "-l"])
        var out: [PCIDevice] = []
        var seen = Set<String>()
        IOReg.walk(roots) { node, _ in
            guard let v = IOReg.u32(node["vendor-id"]), let d = IOReg.u32(node["device-id"]) else { return }
            let cc = IOReg.u32(node["class-code"]) ?? 0
            let sv = IOReg.u32(node["subsystem-vendor-id"]) ?? 0
            let sd = IOReg.u32(node["subsystem-id"]) ?? 0
            let acpi = node["acpi-path"] as? String
            let name = IOReg.name(node)
            let id = acpi ?? "\(name)-\(v)-\(d)-\((node["pcidebug"] as? String) ?? "")"
            guard !seen.contains(id) else { return }
            seen.insert(id)
            let driverKids = IOReg.kids(node).filter { $0["vendor-id"] == nil }
            out.append(PCIDevice(
                id: id, name: name,
                vendor: UInt16(truncatingIfNeeded: v), device: UInt16(truncatingIfNeeded: d),
                subVendor: UInt16(truncatingIfNeeded: sv), subDevice: UInt16(truncatingIfNeeded: sd),
                classCode: cc, acpiPath: acpi,
                ocPath: acpi.flatMap { ocDevicePath(fromACPI: $0) },
                driverClass: driverKids.first.map { IOReg.cls($0) },
                hasDriver: !driverKids.isEmpty))
        }
        return out.sorted { ($0.baseClass, $0.name) < ($1.baseClass, $1.name) }
    }

    /// "IOACPIPlane:/_SB/PCI0@0/RP05@1C0004/ARPT@0" -> "PciRoot(0x0)/Pci(0x1C,0x4)/Pci(0x0,0x0)"
    static func ocDevicePath(fromACPI acpi: String) -> String? {
        guard let colon = acpi.firstIndex(of: ":") else { return nil }
        let comps = acpi[acpi.index(after: colon)...].split(separator: "/").map(String.init)
        guard comps.count >= 3, comps[0] == "_SB" else { return nil }
        let rootParts = comps[1].split(separator: "@")
        guard rootParts.count == 2, let uid = Int(rootParts[1], radix: 16) else { return nil }
        var path = "PciRoot(0x\(String(uid, radix: 16, uppercase: true)))"
        for c in comps.dropFirst(2) {
            let parts = c.split(separator: "@")
            guard parts.count == 2, let adr = Int(parts[1], radix: 16) else { return nil }
            let dev = (adr >> 16) & 0xFFFF
            let fn = adr & 0xFFFF
            path += "/Pci(0x\(String(dev, radix: 16, uppercase: true)),0x\(String(fn, radix: 16, uppercase: true)))"
        }
        return path
    }
}

struct SystemInfo {
    var model = "—"
    var cpu = "—"
    var memory = "—"
    var macOS = "—"
    var sip = "—"
    var bootArgs = "—"
    var openCore = "Not detected (not booted via OpenCore?)"
    var serial = "—"
    var uuid = "—"
    var boardID = "—"
    var gpus: [String] = []
    var thirdPartyKexts: [(name: String, version: String)] = []
}

enum SystemInfoService {
    /// OpenCore version from NVRAM (nil when macOS wasn't booted through OpenCore), e.g. "1.0.6".
    static func openCoreVersion() async -> String? {
        let o = await Shell.run("/usr/sbin/nvram", ["4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version"])
        guard let re = try? NSRegularExpression(pattern: "(REL|DBG|NOO)-(\\d)(\\d)(\\d)-"),
              let m = re.firstMatch(in: o.out, range: NSRange(o.out.startIndex..., in: o.out)) else { return nil }
        let ns = o.out as NSString
        return "\(ns.substring(with: m.range(at: 2))).\(ns.substring(with: m.range(at: 3))).\(ns.substring(with: m.range(at: 4)))"
    }

    /// True/false when this Mac's CPU reports AVX2; nil if it can't be read.
    static func cpuHasAVX2() async -> Bool? {
        let r = await Shell.run("/usr/sbin/sysctl", ["-n", "machdep.cpu.leaf7_features"])
        guard r.ok else { return nil }
        return r.out.uppercased().contains("AVX2")
    }

    static func gather() async -> SystemInfo {
        async let model = Shell.run("/usr/sbin/sysctl", ["-n", "hw.model"])
        async let cpu = Shell.run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
        async let mem = Shell.run("/usr/sbin/sysctl", ["-n", "hw.memsize"])
        async let ver = Shell.run("/usr/bin/sw_vers", ["-productVersion"])
        async let build = Shell.run("/usr/bin/sw_vers", ["-buildVersion"])
        async let sip = Shell.run("/usr/bin/csrutil", ["status"])
        async let args = Shell.run("/usr/sbin/nvram", ["boot-args"])
        async let ocv = Shell.run("/usr/sbin/nvram", ["4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version"])
        async let kext = Shell.run("/usr/sbin/kextstat", ["-l"])
        async let plat = IOReg.nodes(["-r", "-d", "1", "-c", "IOPlatformExpertDevice"])
        async let pci = PCIScanner.scan()

        var info = SystemInfo()
        let m = await model, c = await cpu, ms = await mem, v = await ver, b = await build
        if m.ok { info.model = m.out.trimmed }
        if c.ok { info.cpu = c.out.trimmed }
        if ms.ok, let bytes = Double(ms.out.trimmed) { info.memory = String(format: "%.0f GB", bytes / 1_073_741_824) }
        if v.ok { info.macOS = "\(v.out.trimmed) (\(b.out.trimmed))" }
        let s = await sip
        if let r = s.out.range(of: ": ") { info.sip = String(s.out[r.upperBound...]).trimmed }
        let a = await args
        if a.ok, let tab = a.out.firstIndex(of: "\t") { info.bootArgs = String(a.out[a.out.index(after: tab)...]).trimmed }
        let o = await ocv
        if let re = try? NSRegularExpression(pattern: "(REL|DBG|NOO)-(\\d)(\\d)(\\d)-(\\d{4})-(\\d{2})-(\\d{2})"),
           let mt = re.firstMatch(in: o.out, range: NSRange(o.out.startIndex..., in: o.out)) {
            func g(_ i: Int) -> String { Range(mt.range(at: i), in: o.out).map { String(o.out[$0]) } ?? "" }
            let flavour = g(1) == "REL" ? "Release" : (g(1) == "DBG" ? "Debug" : "NOOPT")
            info.openCore = "\(g(2)).\(g(3)).\(g(4)) \(flavour) (built \(g(5))-\(g(6))-\(g(7)))"
        }
        if let p = (await plat).first {
            info.serial = IOReg.string(p["IOPlatformSerialNumber"]) ?? "—"
            info.uuid = IOReg.string(p["IOPlatformUUID"]) ?? "—"
            info.boardID = IOReg.string(p["board-id"]) ?? "—"
        }
        let k = await kext
        if let re = try? NSRegularExpression(pattern: "([A-Za-z0-9_.\\-]+) \\(([0-9A-Za-z.\\-]+)\\)") {
            for line in k.out.split(separator: "\n") {
                let l = String(line)
                if let mt = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                   let r1 = Range(mt.range(at: 1), in: l), let r2 = Range(mt.range(at: 2), in: l) {
                    let name = String(l[r1])
                    if !name.hasPrefix("com.apple.") { info.thirdPartyKexts.append((name, String(l[r2]))) }
                }
            }
        }
        info.gpus = (await pci).filter { $0.baseClass == 0x03 }.map { "\($0.vendorName) \($0.idString)" }
        return info
    }
}
