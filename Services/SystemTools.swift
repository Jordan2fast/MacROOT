import Foundation

// MARK: - USB

struct USBPort: Identifiable, Hashable {
    var id: String { "\(controller)/\(name)/\(portNumber)" }
    let controller: String
    let name: String
    let portNumber: Int
    var connector: Int
    var deviceName: String?
    var hasDevice: Bool
    var isUSB3: Bool { name.hasPrefix("SS") }
}

struct USBConnectorType: Identifiable {
    let value: Int
    let label: String
    var id: Int { value }
}

enum USBService {
    static let connectorTypes: [USBConnectorType] = [
        USBConnectorType(value: 0, label: "USB 2 Type-A"),
        USBConnectorType(value: 3, label: "USB 3 Type-A"),
        USBConnectorType(value: 8, label: "Type-C (no switch)"),
        USBConnectorType(value: 9, label: "Type-C (with switch)"),
        USBConnectorType(value: 255, label: "Internal")
    ]

    /// Walks the IORegistry and returns the ports that belong directly to a host controller
    /// (hub downstream ports are skipped).
    static func scan() async -> [USBPort] {
        let all = await IOReg.nodes(["-l", "-w0"])
        var ports: [USBPort] = []
        func isController(_ n: [String: Any]) -> Bool {
            let c = IOReg.cls(n)
            return c.contains("XHCI") || c.contains("EHCI") || c.contains("OHCI") || c.contains("UHCI")
        }
        IOReg.walk(all) { node, ancestors in
            guard let portData = node["port"] as? Data, let conn = node["UsbConnector"] as? NSNumber else { return }
            guard let idx = ancestors.lastIndex(where: { isController($0) }) else { return }
            let between = ancestors[(idx + 1)...]
            if between.contains(where: { IOReg.cls($0).contains("IOUSBHostDevice") || IOReg.cls($0).contains("Hub") }) { return }
            let ctrlName = IOReg.name(ancestors[idx])
            let dev = IOReg.kids(node).first(where: { $0["USB Product Name"] != nil || $0["kUSBProductString"] != nil })
            let devName = (dev?["USB Product Name"] as? String) ?? (dev?["kUSBProductString"] as? String)
            ports.append(USBPort(controller: ctrlName, name: IOReg.name(node), portNumber: Int(portData.leUInt32),
                                 connector: conn.intValue, deviceName: devName, hasDevice: !IOReg.kids(node).isEmpty))
        }
        return ports.sorted { ($0.controller, $0.portNumber) < ($1.controller, $1.portNumber) }
    }
}

enum USBMapBuilder {
    /// Builds a USBMap.kext (AppleUSBHostMergeProperties personalities) for the chosen ports.
    static func build(ports: [USBPort], model: String) throws -> URL {
        var personalities: [String: Any] = [:]
        let byController = Dictionary(grouping: ports, by: { $0.controller })
        for (ctrl, group) in byController {
            var portDict: [String: Any] = [:]
            for p in group {
                portDict[p.name] = ["UsbConnector": p.connector, "port": Data.le32(UInt32(p.portNumber))] as [String: Any]
            }
            let maxPort = group.map { $0.portNumber }.max() ?? 0
            let merge: [String: Any] = ["port-count": Data.le32(UInt32(maxPort)), "ports": portDict]
            personalities["\(ctrl)-\(model)"] = [
                "CFBundleIdentifier": "com.apple.driver.AppleUSBHostMergeProperties",
                "IOClass": "AppleUSBHostMergeProperties",
                "IONameMatch": ctrl,
                "IOProbeScore": 5000,
                "IOProviderClass": "AppleUSBHostController",
                "IOProviderMergeProperties": merge,
                "model": model
            ] as [String: Any]
        }
        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": "com.macroot.USBMap",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "USBMap",
            "CFBundlePackageType": "KEXT",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1.0",
            "IOKitPersonalities": personalities,
            "OSBundleLibraries": ["com.apple.driver.AppleUSBHostMergeProperties": "1.2"],
            "OSBundleRequired": "Root"
        ]
        let kext = AppPaths.kextProjects.appendingPathComponent("USBMap", isDirectory: true)
            .appendingPathComponent("USBMap.kext", isDirectory: true)
        try? FileManager.default.removeItem(at: kext)
        try FileManager.default.createDirectory(at: kext.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: kext.appendingPathComponent("Contents/Info.plist"))
        return kext
    }
}

// MARK: - SMBIOS

struct SMBIOSModel: Identifiable {
    let id: String
    let note: String
}

enum SMBIOSService {
    static let models: [SMBIOSModel] = [
        SMBIOSModel(id: "iMac19,1", note: "Coffee Lake desktop (8th/9th gen)"),
        SMBIOSModel(id: "iMac20,1", note: "Comet Lake desktop (10th gen)"),
        SMBIOSModel(id: "iMac20,2", note: "Comet Lake desktop, high end"),
        SMBIOSModel(id: "iMacPro1,1", note: "Xeon / HEDT"),
        SMBIOSModel(id: "MacPro7,1", note: "Workstation, Sequoia and newer"),
        SMBIOSModel(id: "MacBookPro16,1", note: "Laptop, 9th gen and newer"),
        SMBIOSModel(id: "MacBookPro15,2", note: "Laptop, Coffee Lake"),
        SMBIOSModel(id: "MacBookPro14,1", note: "Laptop, Kaby Lake"),
        SMBIOSModel(id: "Macmini8,1", note: "Small form factor / NUC"),
        SMBIOSModel(id: "MacBookAir9,1", note: "Laptop, Ice Lake")
    ]

    static func generate(model: String, macserial: URL) async -> (serial: String, mlb: String)? {
        let r = await Shell.run(macserial.path, ["-m", model, "-n", "1"])
        guard r.ok else { return nil }
        for line in r.out.split(separator: "\n") {
            let parts = line.components(separatedBy: " | ")
            if parts.count == 2 { return (parts[0].trimmed, parts[1].trimmed) }
        }
        return nil
    }

    /// MAC address of en0 as 6 raw bytes (used for PlatformInfo ROM).
    static func en0MAC() async -> Data? {
        let r = await Shell.run("/sbin/ifconfig", ["en0"])
        guard r.ok else { return nil }
        for line in r.out.split(separator: "\n") {
            let t = line.trimmed
            if t.hasPrefix("ether ") {
                let bytes = t.dropFirst(6).split(separator: ":").compactMap { UInt8($0.trimmed, radix: 16) }
                return bytes.count == 6 ? Data(bytes) : nil
            }
        }
        return nil
    }
}

// MARK: - Apple services sanity check

enum ServiceCheck {
    static func run(config: [String: Any]?) async -> [AuditIssue] {
        var out: [AuditIssue] = []
        func add(_ s: AuditIssue.Severity, _ m: String) { out.append(AuditIssue(severity: s, message: m)) }

        let ifaces = await IOReg.nodes(["-r", "-c", "IOEthernetInterface", "-l"])
        var en0: [String: Any]?
        IOReg.walk(ifaces) { n, _ in if (n["BSD Name"] as? String) == "en0" { en0 = n } }
        if let e = en0 {
            if PlistTree.isTrue(e["IOBuiltin"]) { add(.info, "en0 exists and is marked built-in.") }
            else { add(.error, "en0 is NOT marked built-in. iMessage/FaceTime registration needs en0 to be a built-in Ethernet interface.") }
        } else {
            add(.error, "No en0 interface found. Apple services need a working built-in Ethernet device as en0.")
        }

        let plat = await IOReg.nodes(["-r", "-d", "1", "-c", "IOPlatformExpertDevice"])
        if let p = plat.first {
            let serial = IOReg.string(p["IOPlatformSerialNumber"]) ?? ""
            if serial.count == 12 || serial.count == 11 { add(.info, "System serial has a plausible length (\(serial.count) characters).") }
            else { add(.warning, "System serial \"\(serial)\" has an unusual length.") }
        }

        if let cfg = config {
            let mlb = PlistTree.get(cfg, ["PlatformInfo", "Generic", "MLB"]) as? String ?? ""
            if mlb.count == 17 || mlb.count == 13 { add(.info, "MLB length looks valid.") }
            else { add(.warning, "PlatformInfo > Generic > MLB is empty or has an unusual length.") }
            let uuid = PlistTree.get(cfg, ["PlatformInfo", "Generic", "SystemUUID"]) as? String ?? ""
            if UUID(uuidString: uuid) == nil { add(.warning, "SystemUUID is not a valid UUID.") }
            if let rom = PlistTree.get(cfg, ["PlatformInfo", "Generic", "ROM"]) as? Data, let mac = await SMBIOSService.en0MAC() {
                if rom == mac { add(.info, "ROM matches the en0 MAC address.") }
                else { add(.warning, "ROM (\(rom.hex)) differs from the en0 MAC (\(mac.hex)). That's allowed, but matching them is the usual recommendation.") }
            }
            if !PlistTree.isTrue(PlistTree.get(cfg, ["PlatformInfo", "Automatic"])) {
                add(.warning, "PlatformInfo > Automatic is off, so OpenCore won't apply the Generic values.")
            }
        } else {
            add(.info, "Load a config.plist in the Config tab to also check serial/MLB/ROM.")
        }
        return out
    }
}
