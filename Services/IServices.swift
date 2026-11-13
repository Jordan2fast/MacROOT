import Foundation

// Native port of iservices-helper.sh: checks and fixes for iMessage / FaceTime / App Store sign-in on a Hackintosh.

struct SMBIOSReport {
    var rows: [(String, String)]
    var issues: [AuditIssue]
    var complete: Bool
}

enum AMLMode {
    case exact([UInt8])
    case structured
}

enum NVRAMTestState {
    case notStarted, waiting, passed, failed
}

struct DiagnosisResult {
    var errors: [String] = []
    var authLines: [String] = []
    var messagesLines: [String] = []
    var crashes: [(file: String, lines: [String])] = []
}

enum IServices {
    static let nvramGUID = "4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14"
    static let hosts = ["albert.apple.com", "identity.ess.apple.com", "gsa.apple.com"]

    /// OUIs the helper script treats as Apple's (00:16:CB is the one Dortania's iServices guide uses).
    static let appleOUIs: Set<String> = Set([
        "0016CB", "0017F2", "001B63", "001CB3", "001EC2", "001FF3", "001F5B", "001E52", "001D4F", "002241",
        "0023DF", "002500", "0026BB", "00254B", "0025BC", "002608", "00264A", "0026B0", "002312", "002332",
        "00236C", "002436", "0021E9", "001124", "000A95", "000A27", "000393", "000502", "000D93", "001451", "0019E3"
    ])

    // MARK: Judging values

    static func isPlaceholder(_ raw: String) -> Bool {
        let v = raw.replacingOccurrences(of: " ", with: "")
        if v.isEmpty || v == "OEM" { return true }
        if v.range(of: "^[A-Za-z]?0+[0-9]?$", options: .regularExpression) != nil { return true }
        if v.range(of: "^[0-]+$", options: .regularExpression) != nil { return true }
        return false
    }

    static func romIsPlaceholder(_ hex: String) -> Bool {
        ["", "000000000000", "112233445566", "FFFFFFFFFFFF"].contains(hex.uppercased())
    }

    static func isUnicast(_ macHex: String) -> Bool {
        guard macHex.count >= 2, let f = UInt8(macHex.prefix(2), radix: 16) else { return false }
        return f & 1 == 0
    }

    static func isAppleOUI(_ macHex: String) -> Bool { appleOUIs.contains(String(macHex.prefix(6)).uppercased()) }

    static func randomAppleMAC() -> [UInt8] {
        [0x00, 0x16, 0xCB] + (0..<3).map { _ in UInt8.random(in: 0...255) }
    }

    static func pretty(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }

    // MARK: SMBIOS report

    static func smbiosReport(_ cfg: [String: Any]) -> SMBIOSReport {
        func str(_ p: [Any]) -> String { (PlistTree.get(cfg, p) as? String) ?? "" }
        func boolText(_ p: [Any]) -> String {
            guard let v = PlistTree.get(cfg, p) else { return "" }
            return PlistTree.isTrue(v) ? "true" : "false"
        }
        let automatic = boolText(["PlatformInfo", "Automatic"])
        let model = str(["PlatformInfo", "Generic", "SystemProductName"])
        let serial = str(["PlatformInfo", "Generic", "SystemSerialNumber"])
        let mlb = str(["PlatformInfo", "Generic", "MLB"])
        let uuid = str(["PlatformInfo", "Generic", "SystemUUID"])
        let rom = ((PlistTree.get(cfg, ["PlatformInfo", "Generic", "ROM"]) as? Data) ?? Data()).hex
        let mode = str(["PlatformInfo", "UpdateSMBIOSMode"])
        let guid = boolText(["Kernel", "Quirks", "CustomSMBIOSGuid"])
        let spoof = boolText(["PlatformInfo", "Generic", "SpoofVendor"])
        func show(_ s: String) -> String { s.isEmpty ? "(blank)" : s }

        var issues: [AuditIssue] = []
        func add(_ s: AuditIssue.Severity, _ m: String) { issues.append(AuditIssue(severity: s, message: m)) }
        var problems = false
        if automatic != "true" { add(.warning, "PlatformInfo ▸ Automatic is not true, so the Generic values are ignored."); problems = true }
        if isPlaceholder(serial) { add(.warning, "SystemSerialNumber is empty or a placeholder."); problems = true }
        if isPlaceholder(mlb) { add(.warning, "MLB is empty or a placeholder."); problems = true }
        if isPlaceholder(uuid) { add(.warning, "SystemUUID is empty or a placeholder."); problems = true }
        if romIsPlaceholder(rom) { add(.warning, "ROM is empty or a placeholder."); problems = true }
        if model.isEmpty { add(.warning, "SystemProductName is empty."); problems = true }
        if mode == "Custom" && guid == "true" {
            add(.info, "UUID spoof is limited to macOS (UpdateSMBIOSMode = Custom + CustomSMBIOSGuid = true).")
        } else {
            add(.info, "UUID spoof mode is the default. If you dual-boot Windows and want the custom SmUUID applied to macOS only, see UpdateSMBIOSMode = Custom and Kernel ▸ Quirks ▸ CustomSMBIOSGuid.")
        }
        if (PlistTree.get(cfg, ["Kernel", "Add"]) as? [[String: Any]] ?? []).contains(where: { ($0["BundlePath"] as? String) == "NullEthernet.kext" }) {
            add(.info, "NullEthernet.kext is listed in config.plist.")
        }
        let rows = [("Automatic", show(automatic)), ("SystemProductName", show(model)), ("SystemSerialNumber", show(serial)),
                    ("MLB (board serial)", show(mlb)), ("SystemUUID", show(uuid)), ("ROM", show(rom)),
                    ("UpdateSMBIOSMode", show(mode)), ("CustomSMBIOSGuid", show(guid)), ("SpoofVendor", show(spoof))]
        return SMBIOSReport(rows: rows, issues: issues, complete: !problems)
    }

    // MARK: Live checks

    static func hostCheck(_ h: String) async -> AuditIssue {
        let r = await Shell.run("/usr/bin/curl", ["-sk", "-o", "/dev/null", "-m", "8", "-w", "%{http_code}", "https://\(h)"])
        let code = r.out.trimmed
        if code.isEmpty || code == "000" { return AuditIssue(severity: .warning, message: "Can't reach \(h) (firewall, DNS or VPN?).") }
        let issuer = await Shell.sh("echo | /usr/bin/openssl s_client -connect \(h):443 -servername \(h) 2>/dev/null | /usr/bin/openssl x509 -noout -issuer 2>/dev/null").out.trimmed
        if issuer.lowercased().contains("apple") {
            return AuditIssue(severity: .info, message: "Reachable with an Apple-issued certificate: \(h)")
        }
        return AuditIssue(severity: .warning, message: "\(h) is reachable but its certificate issuer isn't Apple (\(issuer.isEmpty ? "unknown" : issuer)). Something may be intercepting HTTPS: a proxy, antivirus, router filtering or a VPN.")
    }

    static func nvramTestMarker() -> URL { AppPaths.support.appendingPathComponent("nvram-test-pending") }

    static func bootTime() async -> String {
        await Shell.run("/usr/sbin/sysctl", ["-n", "kern.boottime"]).out.trimmed
    }

    /// Checks the persistence test variable (without starting one). Cleans up after a finished test.
    static func nvramTestStatus() async -> NVRAMTestState {
        guard let saved = try? String(contentsOf: nvramTestMarker(), encoding: .utf8) else { return .notStarted }
        if saved.trimmed == (await bootTime()) { return .waiting }
        let r = await Shell.run("/usr/sbin/nvram", ["iservicestest"])
        try? FileManager.default.removeItem(at: nvramTestMarker())
        if r.ok {
            _ = await Shell.runPrivileged("/usr/sbin/nvram -d iservicestest")
            return .passed
        }
        return .failed
    }

    static func startNVRAMTest() async -> Bool {
        let r = await Shell.runPrivileged("/usr/sbin/nvram iservicestest=ok")
        guard r.ok else { return false }
        try? (await bootTime()).write(to: nvramTestMarker(), atomically: true, encoding: .utf8)
        return true
    }

    static func liveChecks(config: [String: Any]?) async -> [AuditIssue] {
        var out: [AuditIssue] = []
        func add(_ s: AuditIssue.Severity, _ m: String) { out.append(AuditIssue(severity: s, message: m)) }

        // en0
        let mac = await SMBIOSService.en0MAC()
        let ifaces = await IOReg.nodes(["-r", "-c", "IOEthernetInterface", "-l"])
        var en0Node: [String: Any]?
        IOReg.walk(ifaces) { n, _ in if (n["BSD Name"] as? String) == "en0" { en0Node = n } }
        if let mac = mac {
            let pretty = IServices.pretty(Array(mac))
            if let n = en0Node, PlistTree.isTrue(n["IOBuiltin"]) { add(.info, "en0 is flagged built-in (MAC \(pretty)).") }
            else {
                add(.error, "en0 is NOT flagged built-in (MAC \(pretty)). iMessage/FaceTime require this. With no built-in NIC, use NullEthernet.kext + SSDT-RMNE. If a USB adapter grabbed en0, unplug it, delete /Library/Preferences/SystemConfiguration/NetworkInterfaces.plist and preferences.plist, reboot, and plug it in after en0 is assigned. (Best-effort check; confirm in Hackintool.)")
            }
            if !isUnicast(mac.hex) {
                add(.error, "en0 MAC \(pretty) has the multicast bit set (odd first byte), so it isn't a valid unicast MAC. With NullEthernet, give the MAC bytes in SSDT-RMNE an even first byte. The fix below can do it.")
            }
            if let cfg = config, let rom = PlistTree.get(cfg, ["PlatformInfo", "Generic", "ROM"]) as? Data, !rom.isEmpty {
                if rom == mac { add(.info, "ROM matches the en0 MAC.") }
                else { add(.warning, "ROM (\(rom.hex)) doesn't match the en0 MAC (\(mac.hex)). Recommended: make them identical.") }
            }
        } else {
            add(.error, "No en0 interface found.")
        }

        // route
        let route = await Shell.run("/sbin/route", ["-n", "get", "default"])
        if let line = route.out.split(separator: "\n").first(where: { $0.contains("interface:") }) {
            add(.info, "Internet is going out via \(line.split(separator: ":").last.map { String($0).trimmed } ?? "?").")
        } else {
            add(.warning, "No default route. Is there internet?")
        }

        // Apple hosts, concurrently
        async let a = hostCheck(hosts[0])
        async let b = hostCheck(hosts[1])
        async let c = hostCheck(hosts[2])
        out += [await a, await b, await c]

        // NVRAM
        for k in ["ROM", "MLB"] {
            let r = await Shell.run("/usr/sbin/nvram", ["\(nvramGUID):\(k)"])
            if r.ok { add(.info, "NVRAM has \(k).") }
            else { add(.warning, "NVRAM is missing \(k). Check UpdateNVRAM and that NVRAM works (emulated NVRAM set up).") }
        }
        if let cfg = config {
            if PlistTree.isTrue(PlistTree.get(cfg, ["NVRAM", "WriteFlash"])) { add(.info, "NVRAM ▸ WriteFlash is true.") }
            else { add(.warning, "NVRAM ▸ WriteFlash isn't true. It should be, so iMessage keys survive reboots.") }
        }
        switch await nvramTestStatus() {
        case .waiting: add(.info, "An NVRAM test variable is waiting for a reboot. Reboot, then run the checks again to verify persistence.")
        case .passed: add(.info, "NVRAM persisted across a reboot, so iMessage keys can be stored.")
        case .failed: add(.error, "NVRAM did NOT persist across the reboot. iMessage can't keep its keys, which causes sign-in loops. Check WriteFlash, your emulated NVRAM setup (OpenVariableRuntimeDxe / LogoutHook) and the BIOS.")
        case .notStarted: break
        }

        // Running serial vs config
        let plat = await IOReg.nodes(["-r", "-d", "1", "-c", "IOPlatformExpertDevice"])
        if let live = IOReg.string(plat.first?["IOPlatformSerialNumber"]), !live.isEmpty {
            if let cfg = config, let conf = PlistTree.get(cfg, ["PlatformInfo", "Generic", "SystemSerialNumber"]) as? String, !conf.isEmpty {
                if conf == live { add(.info, "macOS is running with the serial in your config (\(live)).") }
                else { add(.warning, "macOS is running serial \(live) but the loaded config says \(conf). Reboot after changing it, and make sure PlatformInfo ▸ Automatic is true.") }
            }
        }
        return out
    }

    static func tahoeIssue(model: String, runningMajor: Int) -> AuditIssue? {
        guard runningMajor >= 26, !model.isEmpty else { return nil }
        if MacModelSupport.tahoeModels.contains(model) {
            return AuditIssue(severity: .info, message: "\(model) is one of macOS 26's supported Intel models.")
        }
        return AuditIssue(severity: .warning, message: "\(model) isn't one of the few Intel Macs macOS 26 officially supports (\(MacModelSupport.tahoeModels.joined(separator: ", "))). That may or may not matter for iMessage. Switching model signs you out of iCloud/iMessage and may need power management re-checked; the Upgrade Assistant can do it with a backup.")
    }

    // MARK: ACPI MAC patching

    private static func indices(of pattern: [UInt8], in bytes: [UInt8]) -> [Int] {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return [] }
        var hits: [Int] = []
        var i = 0
        let last = bytes.count - pattern.count
        while i <= last {
            if bytes[i] == pattern[0] && Array(bytes[i..<(i + pattern.count)]) == pattern { hits.append(i); i += pattern.count } else { i += 1 }
        }
        return hits
    }

    /// `Name (MAC, Buffer (6) { … })` compiles to "MAC_" 0x11 0x09 0x0A 0x06 + 6 bytes.
    private static let macHeader: [UInt8] = [0x4D, 0x41, 0x43, 0x5F, 0x11, 0x09, 0x0A, 0x06]

    static func countMatches(_ data: Data, mode: AMLMode) -> Int {
        let b = [UInt8](data)
        switch mode {
        case .exact(let old): return indices(of: old, in: b).count
        case .structured:
            let h = indices(of: macHeader, in: b)
            return (h.first.map { $0 + macHeader.count + 6 <= b.count } ?? false) ? 1 : 0
        }
    }

    static func patch(_ data: Data, mode: AMLMode, new: [UInt8]) -> (Data, Int) {
        var b = [UInt8](data)
        var n = 0
        switch mode {
        case .exact(let old):
            for i in indices(of: old, in: b) { b.replaceSubrange(i..<(i + 6), with: new); n += 1 }
        case .structured:
            if let i = indices(of: macHeader, in: b).first, i + macHeader.count + 6 <= b.count {
                let s = i + macHeader.count
                b.replaceSubrange(s..<(s + 6), with: new)
                n = 1
            }
        }
        if n > 0, b.count > 9 {
            let len = Int(b[4]) | (Int(b[5]) << 8) | (Int(b[6]) << 16) | (Int(b[7]) << 24)
            if len > 9, len <= b.count {
                b[9] = 0
                let sum = b[0..<len].reduce(0) { ($0 + Int($1)) & 0xFF }
                b[9] = UInt8((256 - sum) % 256)
            }
        }
        return (Data(b), n)
    }

    /// Looks for the current MAC's bytes first, then for a `Name (MAC, Buffer (6) …)`.
    static func findAMLHits(in acpiDir: URL, currentMAC: [UInt8]) -> (mode: AMLMode, hits: [URL]) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: acpiDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "aml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let exact = AMLMode.exact(currentMAC)
        let exactHits = files.filter { (try? Data(contentsOf: $0)).map { countMatches($0, mode: exact) > 0 } ?? false }
        if !exactHits.isEmpty { return (exact, exactHits) }
        let structHits = files.filter { (try? Data(contentsOf: $0)).map { countMatches($0, mode: .structured) > 0 } ?? false }
        return (.structured, structHits)
    }

    // MARK: Diagnose

    static let diagnosePredicate = "process == \"imagent\" OR process == \"identityservicesd\" OR process == \"Messages\" OR process == \"accountsd\" OR process == \"akd\" OR process == \"apsd\""

    static func diagnoseCommand(output: URL, seconds: Int = 90) -> String {
        let step = max(1, seconds / 9)
        let inner = """
        OUT=\(Shell.quote(output.path))
        /usr/bin/log stream --style compact --level debug --predicate \(Shell.quote(diagnosePredicate)) >> "$OUT" 2>/dev/null &
        P=$!
        i=0
        while [ $i -lt 9 ]; do
          sleep \(step)
          i=$((i+1))
          printf '[%3d%%] Recording iMessage and account logs\\n' $((i*100/9))
        done
        kill $P 2>/dev/null
        wait $P 2>/dev/null
        exit 0
        """
        return "/bin/sh -c \(Shell.quote(inner))"
    }

    static func analyze(logFile: URL) -> DiagnosisResult {
        var r = DiagnosisResult()
        let text = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        func cut(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) : s }
        let noise = ["ACDAccountStore was invalidated", "invalidated because"]
        func isNoise(_ l: String) -> Bool { noise.contains { l.contains($0) } }

        r.errors = lines.filter { l in
            let parts = l.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 3, let c = parts[2].first else { return false }
            return (c == "E" || c == "F") && !isNoise(l)
        }.suffix(30).map { cut($0, 230) }

        let auth = try? NSRegularExpression(pattern: "sign.?out|signed out|log.?out|logged out|unauthor|authenticat|token|expired|rejected|denied|deregist|unregist|[^a-z]40[13][^0-9]", options: [.caseInsensitive])
        r.authLines = lines.filter { l in
            guard !isNoise(l), !l.hasPrefix("==") else { return false }
            return auth?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
        }.suffix(30).map { cut($0, 230) }

        let msg = try? NSRegularExpression(pattern: "exit|terminat|quit|crash|signal|abort|sign", options: [.caseInsensitive])
        r.messagesLines = lines.filter { l in
            l.contains(" Messages[") && msg?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
        }.suffix(10).map { cut($0, 230) }

        let fm = FileManager.default
        let dirs = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                    URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
        var reports: [(URL, Date)] = []
        for d in dirs {
            for u in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let n = u.lastPathComponent.lowercased()
                if n.contains("messages") || n.contains("imagent") || n.contains("identityservices") {
                    let date = ((try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
                    reports.append((u, date))
                }
            }
        }
        let key = try? NSRegularExpression(pattern: "exception|termination|signal|reason|namespace", options: [.caseInsensitive])
        for (u, _) in reports.sorted(by: { $0.1 > $1.1 }).prefix(3) {
            let t = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            let hits = t.split(separator: "\n").map(String.init).filter { key?.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            r.crashes.append((u.path, hits.prefix(8).map { cut($0, 200) }))
        }
        return r
    }
}
