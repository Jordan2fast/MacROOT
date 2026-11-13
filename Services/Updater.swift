import Foundation

// MARK: - GitHub

enum GitHub {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
    }
    struct Release: Decodable {
        let tagName: String
        let name: String?
        let htmlUrl: String?
        let assets: [Asset]
    }
    enum GHError: LocalizedError {
        case http(Int, String)
        case noAsset(String)
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let repo):
                return code == 403 ? "GitHub rate limit hit while checking \(repo). Add a token in Settings." : "GitHub returned HTTP \(code) for \(repo)."
            case .noAsset(let repo): return "No downloadable .zip asset found for \(repo)."
            case .invalid(let m): return m
            }
        }
    }

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacROOT", forHTTPHeaderField: "User-Agent")
        if let t = Keychain.get("github-token"), !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    static func latest(_ repo: String) async throws -> Release {
        let prerelease = UserDefaults.standard.bool(forKey: "includePrereleases")
        let path = prerelease ? "releases?per_page=1" : "releases/latest"
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/\(path)") else { throw GHError.invalid("Bad repo name: \(repo)") }
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        guard let http = resp as? HTTPURLResponse else { throw GHError.invalid("No HTTP response for \(repo)") }
        guard http.statusCode == 200 else { throw GHError.http(http.statusCode, repo) }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        if prerelease {
            guard let first = try dec.decode([Release].self, from: data).first else { throw GHError.invalid("No releases found for \(repo).") }
            return first
        }
        return try dec.decode(Release.self, from: data)
    }

    static func pickAsset(_ r: Release, prefer: [String] = ["RELEASE"],
                          avoid: [String] = ["DEBUG", "dSYM", "NOOPT", "debug"]) -> Asset? {
        let zips = r.assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        let clean = zips.filter { a in !avoid.contains(where: { a.name.contains($0) }) }
        for p in prefer {
            if let hit = clean.first(where: { $0.name.contains(p) }) { return hit }
        }
        return clean.first ?? zips.first
    }

    static func download(_ asset: Asset, to file: URL) async throws -> URL {
        guard let url = URL(string: asset.browserDownloadUrl) else { throw GHError.invalid("Bad asset URL") }
        var req = URLRequest(url: url)
        req.setValue("MacROOT", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw GHError.http(http.statusCode, asset.name) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tmp, to: file)
        return file
    }

    /// Download + unzip a release asset into the cache; returns the extraction folder.
    static func fetchAndExtract(_ rel: Release, repo: String) async throws -> URL {
        guard let asset = pickAsset(rel) else { throw GHError.noAsset(repo) }
        let safe = repo.replacingOccurrences(of: "/", with: "_")
        let dir = AppPaths.cache.appendingPathComponent("kexts/\(safe)/\(rel.tagName)", isDirectory: true)
        let out = dir.appendingPathComponent("x", isDirectory: true)
        let marker = dir.appendingPathComponent(".done")
        if FileManager.default.fileExists(atPath: marker.path) { return out }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = try await download(asset, to: dir.appendingPathComponent(asset.name))
        let r = await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard r.ok else { throw GHError.invalid("Unzip failed: \(r.combined)") }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        return out
    }
}

// MARK: - OpenCore package

struct OCPackage {
    let version: String
    let root: URL
    var x64EFI: URL { root.appendingPathComponent("X64/EFI") }
    var samplePlist: URL { root.appendingPathComponent("Docs/Sample.plist") }
    var ocvalidate: URL { root.appendingPathComponent("Utilities/ocvalidate/ocvalidate") }
    var macserial: URL { root.appendingPathComponent("Utilities/macserial/macserial") }
}

enum OCPackageManager {
    static func latest() async throws -> OCPackage {
        let rel = try await GitHub.latest("acidanthera/OpenCorePkg")
        let version = rel.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let dir = AppPaths.cache.appendingPathComponent("OpenCore-\(version)-RELEASE", isDirectory: true)
        let probe = dir.appendingPathComponent("X64/EFI/OC/OpenCore.efi")
        if !FileManager.default.fileExists(atPath: probe.path) {
            guard let asset = GitHub.pickAsset(rel, prefer: ["RELEASE"]) else { throw GitHub.GHError.noAsset("acidanthera/OpenCorePkg") }
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let zip = try await GitHub.download(asset, to: dir.appendingPathComponent("download.zip"))
            let r = await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
            guard r.ok else { throw GitHub.GHError.invalid("Unzip failed: \(r.combined)") }
            try? FileManager.default.removeItem(at: zip)
        }
        guard FileManager.default.fileExists(atPath: probe.path) else {
            throw GitHub.GHError.invalid("Downloaded OpenCore package has an unexpected layout (no X64/EFI/OC/OpenCore.efi).")
        }
        let pkg = OCPackage(version: version, root: dir)
        for tool in [pkg.ocvalidate, pkg.macserial] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        return pkg
    }
}

// MARK: - Kext helpers

enum KextInfo {
    static func plist(_ kext: URL) -> [String: Any]? {
        try? ConfigIO.readDict(kext.appendingPathComponent("Contents/Info.plist"))
    }
    static func version(of kext: URL) -> String? {
        let p = plist(kext)
        return (p?["CFBundleShortVersionString"] as? String) ?? (p?["CFBundleVersion"] as? String)
    }
    static func executableName(_ kext: URL) -> String? {
        plist(kext)?["CFBundleExecutable"] as? String
    }
    /// Find `Name.kext` inside an extracted release (without descending into kexts).
    static func find(_ name: String, in root: URL, depth: Int = 0) -> URL? {
        guard depth <= 4 else { return nil }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        for e in entries where e.lastPathComponent == name { return e }
        for e in entries {
            let n = e.lastPathComponent
            let isDir = ((try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
            if isDir, !n.hasSuffix(".kext"), !n.hasPrefix("__"), !n.lowercased().contains("debug"),
               let hit = find(name, in: e, depth: depth + 1) { return hit }
        }
        return nil
    }
}

enum KextRegistry {
    /// Best-effort map of kext bundle name -> GitHub repo. Extendable in Settings.
    static let builtin: [String: String] = {
        var m: [String: String] = [:]
        func add(_ repo: String, _ names: [String]) { for n in names { m[n + ".kext"] = repo } }
        add("acidanthera/Lilu", ["Lilu"])
        add("acidanthera/VirtualSMC", ["VirtualSMC", "SMCProcessor", "SMCSuperIO", "SMCBatteryManager", "SMCLightSensor", "SMCDellSensors"])
        add("acidanthera/WhateverGreen", ["WhateverGreen"])
        add("acidanthera/AppleALC", ["AppleALC"])
        add("acidanthera/NVMeFix", ["NVMeFix"])
        add("acidanthera/CPUFriend", ["CPUFriend"])
        add("acidanthera/RestrictEvents", ["RestrictEvents"])
        add("acidanthera/HibernationFixup", ["HibernationFixup"])
        add("acidanthera/AirportBrcmFixup", ["AirportBrcmFixup"])
        add("acidanthera/BrcmPatchRAM", ["BrcmPatchRAM3", "BrcmPatchRAM2", "BrcmFirmwareData", "BrcmFirmwareRepo", "BrcmBluetoothInjector", "BlueToolFixup"])
        add("acidanthera/IntelMausi", ["IntelMausi"])
        add("acidanthera/VoodooPS2", ["VoodooPS2Controller"])
        add("acidanthera/CryptexFixup", ["CryptexFixup"])
        add("acidanthera/FeatureUnlock", ["FeatureUnlock"])
        add("VoodooI2C/VoodooI2C", ["VoodooI2C", "VoodooI2CHID"])
        add("OpenIntelWireless/IntelBluetoothFirmware", ["IntelBluetoothFirmware", "IntelBTPatcher", "IntelBluetoothInjector"])
        add("USBToolBox/kext", ["USBToolBox"])
        add("1Revenger1/ECEnabler", ["ECEnabler"])
        add("ChefKissInc/NootedRed", ["NootedRed"])
        add("ChefKissInc/ForgedInvariant", ["ForgedInvariant"])
        add("Mieze/RTL8111_driver_for_OS_X", ["RealtekRTL8111"])
        add("Mieze/LucyRTL8125Ethernet", ["LucyRTL8125Ethernet"])
        add("Mieze/AtherosE2200Ethernet", ["AtherosE2200Ethernet"])
        return m
    }()

    /// User additions, one per line in Settings: `Name.kext=owner/repo`
    static func custom() -> [String: String] {
        var m: [String: String] = [:]
        let text = UserDefaults.standard.string(forKey: "customKextSources") ?? ""
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmed }
            if parts.count == 2, parts[0].hasSuffix(".kext"), parts[1].contains("/") { m[parts[0]] = parts[1] }
        }
        return m
    }

    /// Priority: your own list, then OpCore Simplify's data (kept current by its maintainer), then the built-in list.
    static func repo(for kext: String) -> String? {
        if let c = custom()[kext] { return c }
        let base = kext.hasSuffix(".kext") ? String(kext.dropLast(5)) : kext
        if let r = OCSStore.shared.kexts[base]?.repo { return r }
        return builtin[kext]
    }
}

// MARK: - Plan

struct UpdateItem: Identifiable {
    enum Kind: String, CaseIterable { case core = "OpenCore", driver = "Drivers", tool = "Tools", resources = "Resources", config = "config.plist", kext = "Kexts" }
    let id = UUID()
    var kind: Kind
    var name: String
    var installed: String
    var latest: String
    var source: URL
    var dest: String
    var needsUpdate: Bool
    var selected: Bool
    var note: String
}

struct UpdatePlan {
    var package: OCPackage
    var items: [UpdateItem]
    var changes: [ConfigChange]
    var unmanagedKexts: [String]
}

enum UpdatePlanner {
    static func plan(efi: URL, config: [String: Any], includeKexts: Bool, removeObsolete: Bool,
                     progress: @escaping (String) -> Void) async throws -> UpdatePlan {
        let fm = FileManager.default
        progress("Fetching latest OpenCore release…")
        let pkg = try await OCPackageManager.latest()
        let pkgEFI = pkg.x64EFI
        var items: [UpdateItem] = []

        func compareFile(_ kind: UpdateItem.Kind, _ name: String, installed: URL, latest: URL) {
            guard fm.fileExists(atPath: installed.path), fm.fileExists(atPath: latest.path) else { return }
            let a = FileOps.sha256(installed)
            let b = FileOps.sha256(latest)
            let changed = a != b
            items.append(UpdateItem(
                kind: kind, name: name,
                installed: a.map { String($0.prefix(8)) } ?? "?",
                latest: b.map { String($0.prefix(8)) } ?? "?",
                source: latest, dest: installed.path,
                needsUpdate: changed, selected: changed,
                note: changed ? "Differs from OpenCore \(pkg.version)" : "Up to date"))
        }

        compareFile(.core, "OpenCore.efi", installed: efi.appendingPathComponent("OC/OpenCore.efi"), latest: pkgEFI.appendingPathComponent("OC/OpenCore.efi"))
        compareFile(.core, "BOOTx64.efi", installed: efi.appendingPathComponent("BOOT/BOOTx64.efi"), latest: pkgEFI.appendingPathComponent("BOOT/BOOTx64.efi"))

        for sub in ["Drivers", "Tools"] {
            let dir = efi.appendingPathComponent("OC/\(sub)")
            let kind: UpdateItem.Kind = sub == "Drivers" ? .driver : .tool
            for f in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            where f.hasSuffix(".efi") && !f.hasPrefix(".") {
                compareFile(kind, f, installed: dir.appendingPathComponent(f), latest: pkgEFI.appendingPathComponent("OC/\(sub)/\(f)"))
            }
        }

        let res = efi.appendingPathComponent("OC/Resources")
        let pres = pkgEFI.appendingPathComponent("OC/Resources")
        if fm.fileExists(atPath: res.path), fm.fileExists(atPath: pres.path) {
            let coreChanged = items.contains { $0.kind == .core && $0.needsUpdate }
            items.append(UpdateItem(kind: .resources, name: "Resources (OpenCanopy assets)", installed: "", latest: pkg.version,
                                    source: pres, dest: res.path, needsUpdate: coreChanged, selected: coreChanged,
                                    note: coreChanged ? "Refreshed together with OpenCore" : "Up to date"))
        }

        progress("Comparing config.plist with Sample.plist…")
        let sample = try ConfigIO.readDict(pkg.samplePlist)
        let (migrated, changes) = ConfigMigrator.migrate(user: config, sample: sample, removeObsolete: removeObsolete)
        let applicable = changes.filter { $0.kind != .obsolete || removeObsolete }
        if !applicable.isEmpty {
            let staged = AppPaths.cache.appendingPathComponent("staged-config.plist")
            let data = try PropertyListSerialization.data(fromPropertyList: migrated, format: .xml, options: 0)
            try data.write(to: staged)
            items.append(UpdateItem(kind: .config, name: "config.plist", installed: "", latest: pkg.version,
                                    source: staged, dest: efi.appendingPathComponent("OC/config.plist").path,
                                    needsUpdate: true, selected: true,
                                    note: "\(applicable.count) change(s) to match OpenCore \(pkg.version)"))
        }

        var unmanaged: [String] = []
        if includeKexts {
            let kextDir = efi.appendingPathComponent("OC/Kexts")
            let names = ((try? fm.contentsOfDirectory(atPath: kextDir.path)) ?? []).filter { $0.hasSuffix(".kext") }.sorted()
            var groups: [String: [String]] = [:]
            for n in names {
                if let repo = KextRegistry.repo(for: n) { groups[repo, default: []].append(n) } else { unmanaged.append(n) }
            }
            for (repo, kexts) in groups.sorted(by: { $0.key < $1.key }) {
                progress("Checking \(repo)…")
                do {
                    let rel = try await GitHub.latest(repo)
                    let latestV = rel.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                    var extracted: URL?
                    for k in kexts {
                        let installedURL = kextDir.appendingPathComponent(k)
                        let installedV = KextInfo.version(of: installedURL)
                        let needs = installedV.map { Version.isNewer(latestV, than: $0) } ?? true
                        var src: URL?
                        if needs {
                            if extracted == nil { extracted = try await GitHub.fetchAndExtract(rel, repo: repo) }
                            src = extracted.flatMap { KextInfo.find(k, in: $0) }
                        }
                        let ok = needs && src != nil
                        items.append(UpdateItem(
                            kind: .kext, name: k, installed: installedV ?? "?", latest: latestV,
                            source: src ?? installedURL, dest: installedURL.path,
                            needsUpdate: ok, selected: ok,
                            note: !needs ? "Up to date" : (src == nil ? "Not found in release archive" : "Update available (\(repo))")))
                    }
                } catch {
                    for k in kexts {
                        let u = kextDir.appendingPathComponent(k)
                        items.append(UpdateItem(kind: .kext, name: k, installed: KextInfo.version(of: u) ?? "?", latest: "?",
                                                source: u, dest: u.path, needsUpdate: false, selected: false,
                                                note: "Lookup failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
        return UpdatePlan(package: pkg, items: items, changes: changes, unmanagedKexts: unmanaged)
    }

    /// Shell script that applies the selected items. Kexts are replaced wholesale.
    static func applyScript(_ items: [UpdateItem]) -> String {
        var lines = ["set -e"]
        for it in items where it.selected && it.needsUpdate {
            let d = Shell.quote(it.dest)
            let s = Shell.quote(it.source.path)
            if it.kind == .kext { lines.append("rm -rf \(d)") }
            lines.append("/usr/bin/ditto --norsrc --noextattr --noqtn \(s) \(d)")
        }
        return lines.joined(separator: "\n")
    }
}
