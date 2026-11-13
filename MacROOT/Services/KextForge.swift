import Foundation

// MARK: - Donor / spoof injector

struct DonorPersonality: Identifiable {
    let id: String               // personality name
    let dict: [String: Any]
    var providerClass: String { (dict["IOProviderClass"] as? String) ?? "?" }
    var ioClass: String { (dict["IOClass"] as? String) ?? "?" }
}

struct DonorKext {
    let url: URL
    let bundleID: String
    let version: String
    let personalities: [DonorPersonality]
}

enum SpoofBuilder {
    enum SpoofError: LocalizedError {
        case notAKext, noPersonalities
        var errorDescription: String? {
            switch self {
            case .notAKext: return "That doesn't look like a kext (no Contents/Info.plist with a CFBundleIdentifier)."
            case .noPersonalities: return "The kext has no IOKitPersonalities to clone."
            }
        }
    }

    static func loadDonor(_ url: URL) throws -> DonorKext {
        guard let p = KextInfo.plist(url), let id = p["CFBundleIdentifier"] as? String else { throw SpoofError.notAKext }
        let version = (p["CFBundleVersion"] as? String) ?? "1.0"
        var merged: [String: Any] = (p["IOKitPersonalities"] as? [String: Any]) ?? [:]
        for (k, v) in (p["IOKitPersonalities_x86_64"] as? [String: Any]) ?? [:] { merged[k] = v }
        let list = merged.compactMap { pair -> DonorPersonality? in
            guard let d = pair.value as? [String: Any] else { return nil }
            return DonorPersonality(id: pair.key, dict: d)
        }.sorted { $0.id < $1.id }
        guard !list.isEmpty else { throw SpoofError.noPersonalities }
        return DonorKext(url: url, bundleID: id, version: version, personalities: list)
    }

    static func safeName(_ s: String) -> String {
        let cleaned = s.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return cleaned.isEmpty ? "Spoof" : cleaned
    }

    /// Build a plist-only injector kext: the donor's driver personality re-targeted at `device`.
    static func buildInjector(name: String, device: PCIDevice, donor: DonorKext, personality: DonorPersonality) throws -> URL {
        let name = safeName(name)
        var p = personality.dict
        for key in ["IOPCIMatch", "IOPCIPrimaryMatch", "IOPCISecondaryMatch", "IOPCIClassMatch", "IONameMatch"] {
            p.removeValue(forKey: key)
        }
        p["IOPCIMatch"] = device.ioPCIMatch
        p["CFBundleIdentifier"] = donor.bundleID

        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": "com.macroot.spoof.\(name)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundlePackageType": "KEXT",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1.0",
            "IOKitPersonalities": [name: p],
            "OSBundleLibraries": [donor.bundleID: donor.version]
        ]
        let kext = AppPaths.kextProjects
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("\(name).kext", isDirectory: true)
        try? FileManager.default.removeItem(at: kext)
        try FileManager.default.createDirectory(at: kext.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: kext.appendingPathComponent("Contents/Info.plist"))
        return kext
    }

    // MARK: DeviceProperties spoof

    static func deviceProperties(deviceID: UInt16?, vendorID: UInt16?, compatible: String?) -> [String: Any] {
        var d: [String: Any] = [:]
        if let id = deviceID { d["device-id"] = Data.le32(UInt32(id)) }
        if let v = vendorID { d["vendor-id"] = Data.le32(UInt32(v)) }
        if let c = compatible, !c.isEmpty { d["compatible"] = c }
        return d
    }

    static func xmlSnippet(devicePath: String, props: [String: Any]) -> String {
        let dict: [String: Any] = [devicePath: props]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
              let s = String(data: data, encoding: .utf8) else { return "" }
        if let a = s.range(of: "<plist version=\"1.0\">\n"), let b = s.range(of: "</plist>") {
            return String(s[a.upperBound..<b.lowerBound]).trimmed
        }
        return s
    }
}

// MARK: - AI generator

struct AIKextFile: Decodable {
    let path: String
    let content: String
}
struct AIKextProject: Decodable {
    let summary: String
    let approach: String?
    let confidence: String?
    let files: [AIKextFile]
    let notes: [String]?
}

enum AIKextClient {
    enum AIError: LocalizedError {
        case noKey
        case http(Int, String)
        case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "No Anthropic API key set. Add one in MacROOT ▸ Settings."
            case .http(let c, let m): return "API error \(c): \(m)"
            case .badResponse(let m): return "Unexpected API response: \(m)"
            }
        }
    }

    static let systemPrompt = """
    You are an expert macOS kernel-extension (IOKit) engineer who writes drivers for Hackintosh systems (x86_64, injected by OpenCore).
    The user gives you a PCI device that has no driver on macOS. Decide honestly whether a working driver can be produced.

    Rules:
    - Reply with ONE JSON object and nothing else (no markdown fences). Schema:
      {"summary": string, "approach": string, "confidence": "low"|"medium"|"high",
       "files": [{"path": string, "content": string}], "notes": [string]}
    - "files" paths are relative (e.g. "Info.plist", "Sources/MyDriver.cpp", "Sources/MyDriver.hpp"). No absolute paths, no "..".
    - Info.plist must be a complete kext Info.plist whose CFBundleExecutable, CFBundleIdentifier and IOClass match the names the user supplies, with an IOKitPersonalities entry using IOProviderClass IOPCIDevice and IOPCIMatch for the given IDs.
    - Use only public Kernel.framework / IOKit C++ APIs. Do NOT write kmod_info / _start / _stop boilerplate; the build tool adds it.
    - Never invent register maps, firmware formats or protocol details you do not actually know. If the device needs proprietary firmware or documentation you cannot reproduce, return "files": [] and explain what would be needed (for example a different existing driver to spoof, or a different adapter).
    - A minimal driver that attaches, logs, and safely does nothing is better than guessed hardware access that could hang the machine. State clearly in "notes" which parts are unverified.
    """

    static func generate(device: PCIDevice, kextName: String, bundleID: String, notes: String, macOS: String) async throws -> (project: AIKextProject?, raw: String) {
        guard let key = Keychain.get("anthropic-key"), !key.isEmpty else { throw AIError.noKey }
        let model = UserDefaults.standard.string(forKey: "aiModel") ?? "claude-sonnet-5-5"
        let user = """
        Device: \(device.name) — \(device.vendorName), class: \(device.kind)
        Vendor ID: 0x\(String(format: "%04X", UInt32(device.vendor)))   Device ID: 0x\(String(format: "%04X", UInt32(device.device)))
        Subsystem: \(device.subsystemString)   Class code: 0x\(String(format: "%06X", device.classCode))
        IOPCIMatch string: \(device.ioPCIMatch)
        Driver currently attached on macOS: \(device.driverClass ?? "none")
        Target macOS: \(macOS), architecture x86_64
        Kext name / CFBundleExecutable / IOClass: \(kextName)
        CFBundleIdentifier: \(bundleID)
        Extra notes from the user: \(notes.isEmpty ? "(none)" : notes)
        """
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "system": systemPrompt,
            "messages": [["role": "user", "content": user]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse("no HTTP response") }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data, as: UTF8.self)
            throw AIError.http(http.statusCode, msg)
        }
        let text = ((obj?["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.badResponse("empty content") }
        return (decodeProject(text), text)
    }

    static func decodeProject(_ text: String) -> AIKextProject? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { return nil }
        return try? JSONDecoder().decode(AIKextProject.self, from: Data(text[a...b].utf8))
    }

    /// Writes the files into a project folder. Rejects any path that could escape it.
    static func write(_ project: AIKextProject, name: String) throws -> URL {
        let dir = AppPaths.kextProjects.appendingPathComponent("\(SpoofBuilder.safeName(name))-AI", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let allowed: Set<String> = ["cpp", "hpp", "h", "c", "cc", "plist", "md", "txt"]
        for f in project.files {
            let comps = f.path.split(separator: "/").map(String.init)
            guard !f.path.hasPrefix("/"), !comps.isEmpty, !comps.contains(".."), !comps.contains(where: { $0.hasPrefix(".") }),
                  allowed.contains((f.path as NSString).pathExtension.lowercased()) else {
                throw AIError.badResponse("Refused unsafe file path from the model: \(f.path)")
            }
            let url = dir.appendingPathComponent(f.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.content.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }
}

// MARK: - Compiler

enum KextCompiler {
    /// Compile `<projectDir>/Sources/*.cpp|c` + `<projectDir>/Info.plist` into `<projectDir>/Build/<name>.kext`.
    static func build(projectDir: URL, name: String, bundleID: String, version: String = "1.0.0",
                      deployment: String = "10.15") async -> (ok: Bool, log: String, kext: URL?) {
        let fm = FileManager.default
        var log = ""
        let sdkR = await Shell.run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"])
        guard sdkR.ok else { return (false, "xcrun failed — install Xcode or the Command Line Tools.\n\(sdkR.combined)", nil) }
        let sdk = sdkR.out.trimmed
        let resR = await Shell.run("/usr/bin/xcrun", ["clang", "-print-resource-dir"])
        let res = resR.out.trimmed
        let kh = sdk + "/System/Library/Frameworks/Kernel.framework/Headers"
        guard fm.fileExists(atPath: kh) else { return (false, "Kernel.framework headers not found at \(kh)", nil) }

        let src = projectDir.appendingPathComponent("Sources", isDirectory: true)
        let buildDir = projectDir.appendingPathComponent("Build", isDirectory: true)
        try? fm.removeItem(at: buildDir)
        do { try fm.createDirectory(at: buildDir, withIntermediateDirectories: true) } catch { return (false, error.localizedDescription, nil) }

        // Info.plist: take the generated one but force the identity fields.
        let infoSrc = projectDir.appendingPathComponent("Info.plist")
        guard var info = try? ConfigIO.readDict(infoSrc) else { return (false, "Info.plist is missing or unreadable in \(projectDir.path)", nil) }
        info["CFBundleExecutable"] = name
        info["CFBundleIdentifier"] = bundleID
        info["CFBundlePackageType"] = "KEXT"
        if info["CFBundleVersion"] == nil { info["CFBundleVersion"] = version }
        if info["CFBundleShortVersionString"] == nil { info["CFBundleShortVersionString"] = version }
        if info["CFBundleInfoDictionaryVersion"] == nil { info["CFBundleInfoDictionaryVersion"] = "6.0" }
        let ver = (info["CFBundleVersion"] as? String) ?? version

        let stub = buildDir.appendingPathComponent("kmod_stub.cpp")
        let stubSource = """
        #include <mach/mach_types.h>
        extern "C" {
        extern kern_return_t _start(kmod_info_t *ki, void *data);
        extern kern_return_t _stop(kmod_info_t *ki, void *data);
        __attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(\(bundleID), "\(ver)", _start, _stop)
        __private_extern__ kmod_start_func_t *_realmain = 0;
        __private_extern__ kmod_stop_func_t *_antimain = 0;
        __private_extern__ int _kext_apple_cc = __APPLE_CC__;
        }
        """
        do { try stubSource.write(to: stub, atomically: true, encoding: .utf8) } catch { return (false, error.localizedDescription, nil) }

        var sources = ((try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["cpp", "cc", "c"].contains($0.pathExtension) }
        guard !sources.isEmpty else { return (false, "No source files found in \(src.path)", nil) }
        sources.append(stub)

        var objects: [String] = []
        for s in sources {
            let obj = buildDir.appendingPathComponent(s.deletingPathExtension().lastPathComponent + ".o")
            let isC = s.pathExtension == "c"
            var args = [isC ? "clang" : "clang++", "-arch", "x86_64", "-mmacosx-version-min=\(deployment)", "-isysroot", sdk,
                        "-nostdinc", "-isystem", kh, "-isystem", res + "/include", "-I", src.path,
                        "-mkernel", "-fapple-kext", "-fno-builtin", "-fno-common", "-fno-stack-protector",
                        "-DKERNEL", "-DKERNEL_PRIVATE", "-DDRIVER_PRIVATE", "-DAPPLE", "-DNeXT", "-O2",
                        "-Wno-unused-parameter"]
            if !isC { args += ["-nostdinc++", "-std=gnu++14", "-fno-rtti", "-fno-exceptions"] }
            args += ["-c", s.path, "-o", obj.path]
            let r = await Shell.run("/usr/bin/xcrun", args)
            log += "$ clang \(s.lastPathComponent)\n\(r.combined)\n"
            guard r.ok else { return (false, log, nil) }
            objects.append(obj.path)
        }

        let kext = buildDir.appendingPathComponent("\(name).kext", isDirectory: true)
        let macos = kext.appendingPathComponent("Contents/MacOS", isDirectory: true)
        do { try fm.createDirectory(at: macos, withIntermediateDirectories: true) } catch { return (false, error.localizedDescription, nil) }
        let exe = macos.appendingPathComponent(name)
        let linkArgs = ["clang++", "-arch", "x86_64", "-mmacosx-version-min=\(deployment)", "-isysroot", sdk,
                        "-nostdlib", "-Xlinker", "-kext", "-L", sdk + "/usr/lib"] + objects + ["-lkmod", "-lcc_kext", "-o", exe.path]
        let lr = await Shell.run("/usr/bin/xcrun", linkArgs)
        log += "$ link \(name)\n\(lr.combined)\n"
        guard lr.ok else { return (false, log, nil) }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: kext.appendingPathComponent("Contents/Info.plist"))
        } catch { return (false, log + error.localizedDescription, nil) }
        log += "Built \(kext.path)\n"
        return (true, log, kext)
    }
}

// MARK: - Install into EFI

enum KextInstaller {
    @MainActor
    static func install(kext: URL, efiOC: URL, config: ConfigDocument?) async -> (ok: Bool, message: String) {
        let name = kext.lastPathComponent
        let dest = efiOC.appendingPathComponent("Kexts/\(name)")
        let script = "set -e\nrm -rf \(Shell.quote(dest.path))\n/usr/bin/ditto --norsrc --noextattr --noqtn \(Shell.quote(kext.path)) \(Shell.quote(dest.path))"
        let priv = !FileOps.isWritable(efiOC.appendingPathComponent("Kexts"))
        let r = await FileOps.runScript(script, privileged: priv)
        guard r.ok else { return (false, "Copy failed: \(r.combined)") }
        guard let config = config, config.url.path == efiOC.appendingPathComponent("config.plist").path else {
            return (true, "Copied \(name) to EFI/OC/Kexts. Open that EFI's config.plist in the Config tab to add the Kernel ▸ Add entry.")
        }
        let exe = KextInfo.executableName(kext).map { "Contents/MacOS/\($0)" } ?? ""
        config.addKernelKext(bundlePath: name, executablePath: exe, comment: "Added by MacROOT")
        if let err = await config.save() { return (false, "Kext copied, but saving config.plist failed: \(err)") }
        return (true, "Installed \(name) and added it to Kernel ▸ Add (config.plist backed up first).")
    }
}
