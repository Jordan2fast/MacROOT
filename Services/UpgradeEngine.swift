import Foundation

// MARK: - Rules

struct KextInstallSpec {
    let name: String
    let spec: KextSourceSpec
    let after: [String]
}

struct UpgradeRule: Identifiable {
    enum Category: String, CaseIterable {
        case blocker = "Blocker", opencore = "OpenCore", smbios = "SMBIOS", kernel = "Kernel"
        case kexts = "Kexts", bootArgs = "Boot args", wifi = "Wi-Fi", info = "Notes"
    }
    enum Risk: String { case safe = "SAFE", review = "REVIEW", risky = "RISKY", info = "INFO" }

    let id: String
    let category: Category
    let title: String
    let detail: String
    let risk: Risk
    var selected: Bool
    var change: (([String: Any]) -> [String: Any])? = nil
    var installs: [KextInstallSpec] = []
    var smbiosModel: String? = nil

    var isActionable: Bool { change != nil || !installs.isEmpty || smbiosModel != nil }
}

struct UpgradeContext {
    var config: [String: Any]
    var from: MacOSVersion
    var to: MacOSVersion
    var ocs: [String: OCSKext]
    var kextsOnDisk: Set<String>
    var installedOpenCore: String?
    var cpuHasAVX2: Bool?
}

enum UpgradeAnalyzer {
    static let bootArgsPath: [Any] = ["NVRAM", "Add", "7C436110-AB2A-4BBB-A880-FE41995C9F82", "boot-args"]

    // MARK: Config helpers

    static func topName(_ bundlePath: String) -> String {
        let first = bundlePath.split(separator: "/").first.map(String.init) ?? bundlePath
        return first.hasSuffix(".kext") ? String(first.dropLast(5)) : first
    }

    static func kernelAdd(_ cfg: [String: Any]) -> [[String: Any]] {
        (PlistTree.get(cfg, ["Kernel", "Add"]) as? [[String: Any]]) ?? []
    }

    static func names(_ cfg: [String: Any], enabledOnly: Bool) -> Set<String> {
        var s = Set<String>()
        for e in kernelAdd(cfg) {
            guard let b = e["BundlePath"] as? String else { continue }
            if !enabledOnly || PlistTree.isTrue(e["Enabled"]) { s.insert(topName(b)) }
        }
        return s
    }

    static func setValue(_ cfg: [String: Any], _ path: [Any], _ value: Any) -> [String: Any] {
        (PlistTree.set(cfg, ArraySlice(path), value) as? [String: Any]) ?? cfg
    }

    static func bootArgs(_ cfg: [String: Any]) -> [String] {
        ((PlistTree.get(cfg, bootArgsPath) as? String) ?? "").split(separator: " ").map(String.init)
    }

    static func disableKext(_ cfg: [String: Any], named name: String) -> [String: Any] {
        var add = (PlistTree.get(cfg, ["Kernel", "Add"]) as? [Any]) ?? []
        for i in add.indices {
            guard var e = add[i] as? [String: Any], let b = e["BundlePath"] as? String, topName(b) == name else { continue }
            e["Enabled"] = false
            add[i] = e
        }
        return setValue(cfg, ["Kernel", "Add"], add)
    }

    /// Adds (or re-enables) a Kernel > Add entry, placing it after the last of `after` that is already listed.
    static func addKextEntry(_ cfg: [String: Any], name: String, executable: String, after: [String]) -> [String: Any] {
        var add = (PlistTree.get(cfg, ["Kernel", "Add"]) as? [Any]) ?? []
        for i in add.indices {
            if var e = add[i] as? [String: Any], let b = e["BundlePath"] as? String, b == "\(name).kext" {
                e["Enabled"] = true
                add[i] = e
                return setValue(cfg, ["Kernel", "Add"], add)
            }
        }
        let entry: [String: Any] = [
            "Arch": "Any", "BundlePath": "\(name).kext", "Comment": "Added by MacROOT Upgrade Assistant", "Enabled": true,
            "ExecutablePath": executable.isEmpty ? "" : "Contents/MacOS/\(executable)", "MaxKernel": "", "MinKernel": "",
            "PlistPath": "Contents/Info.plist"
        ]
        var insertAt = add.count
        var last = -1
        for (i, e) in add.enumerated() {
            if let b = (e as? [String: Any])?["BundlePath"] as? String, after.contains(topName(b)) { last = i }
        }
        if last >= 0 { insertAt = last + 1 }
        add.insert(entry, at: insertAt)
        return setValue(cfg, ["Kernel", "Add"], add)
    }

    /// Reorders Kernel > Add so every kext comes after the kexts it depends on (stable otherwise).
    static func reorderKernelAdd(_ cfg: [String: Any], ocs: [String: OCSKext]) -> [String: Any] {
        let add = (PlistTree.get(cfg, ["Kernel", "Add"]) as? [Any]) ?? []
        func name(_ e: Any) -> String { topName(((e as? [String: Any])?["BundlePath"] as? String) ?? "") }
        func deps(_ n: String) -> [String] { Array(Set((ConfigAudit.loadAfter[n] ?? []) + (ocs[n]?.requires ?? []))).sorted() }
        var emitted = Set<Int>()
        var visiting = Set<Int>()
        var out: [Any] = []
        func emit(_ i: Int) {
            if emitted.contains(i) || visiting.contains(i) { return }
            visiting.insert(i)
            let n = name(add[i])
            for d in deps(n) where d != n {
                for j in add.indices where name(add[j]) == d { emit(j) }
            }
            visiting.remove(i)
            if !emitted.contains(i) { emitted.insert(i); out.append(add[i]) }
        }
        for i in add.indices { emit(i) }
        return setValue(cfg, ["Kernel", "Add"], out)
    }

    static func orderViolations(_ cfg: [String: Any], ocs: [String: OCSKext]) -> Bool {
        let before = (PlistTree.get(cfg, ["Kernel", "Add"]) as? [Any]) ?? []
        let after = (PlistTree.get(reorderKernelAdd(cfg, ocs: ocs), ["Kernel", "Add"]) as? [Any]) ?? []
        func ids(_ a: [Any]) -> [String] { a.map { ((($0 as? [String: Any])?["BundlePath"]) as? String) ?? "" } }
        return ids(before) != ids(after)
    }

    // MARK: Analysis

    static func analyze(_ ctx: UpgradeContext) -> [UpgradeRule] {
        var rules: [UpgradeRule] = []
        let cfg = ctx.config
        let to = ctx.to, from = ctx.from
        let enabled = names(cfg, enabledOnly: true)
        let present = names(cfg, enabledOnly: false)
        let toD = to.darwinMajor, fromD = from.darwinMajor

        if !to.supportsIntel {
            rules.append(UpgradeRule(
                id: "blocker-intel", category: .blocker,
                title: "macOS \(to.major) (\(to.name)) doesn't run on Intel Macs",
                detail: "Apple silicon only. macOS 26 Tahoe is the last release an x86_64 Hackintosh can boot, so there is nothing to migrate to. Pick macOS 26 or earlier.",
                risk: .risky, selected: false))
            return rules
        }

        rules.append(UpgradeRule(
            id: "note-span", category: .info,
            title: "Migrating \(from.display) → \(to.display)",
            detail: to.major == 26
                ? "macOS 26 Tahoe is the last macOS release that supports Intel hardware. Test on a spare boot entry or drive before changing your main EFI."
                : "Test on a spare boot entry or drive before changing your main EFI.",
            risk: .info, selected: false))

        // OpenCore version
        if to.major >= 26 {
            let old = ctx.installedOpenCore.map { Version.isNewer("1.0.5", than: $0) } ?? false
            rules.append(UpgradeRule(
                id: "oc-version", category: .opencore,
                title: "macOS 26 needs OpenCore 1.0.5 or newer",
                detail: "OpenCore's 1.0.5 release notes list kext-injection fixes for macOS 26, and 1.0.7 improved XhciPortLimit compatibility with it. Leave “Update OpenCore + drivers” ticked to get the latest. Installed: \(ctx.installedOpenCore ?? "unknown (booted without OpenCore?)").",
                risk: old ? .review : .info, selected: false))
        }

        // SMBIOS
        let model = (PlistTree.get(cfg, ["PlatformInfo", "Generic", "SystemProductName"]) as? String) ?? ""
        if !model.isEmpty {
            switch MacModelSupport.status(model: model, target: to.major) {
            case .unsupported(let last):
                let lastName = MacOSVersion(major: last).name
                let suggestion = MacModelSupport.suggestion(for: model, target: to.major)
                rules.append(UpgradeRule(
                    id: "smbios-model", category: .smbios,
                    title: "\(model) isn't supported by macOS \(to.name)",
                    detail: "Apple's support for this model ended with macOS \(lastName). You can keep it (OpenCore can still boot unsupported models, but Software Update and some features can misbehave; OpCore Simplify has a patch for unsupported SMBIOS that MacROOT doesn't generate) or switch to \(suggestion ?? "a supported model"). Switching generates a new serial/MLB, signs you out of iCloud/iMessage and may change power management, so it is off by default. Use the iServices tab afterwards.",
                    risk: .risky, selected: false, smbiosModel: suggestion))
            case .unknown:
                rules.append(UpgradeRule(
                    id: "smbios-unknown", category: .info,
                    title: "No built-in support data for \(model)",
                    detail: "MacROOT's small table doesn't know this model. Check Apple's compatibility list for macOS \(to.name).",
                    risk: .info, selected: false))
            case .supported:
                break
            }
        }

        // Kernel quirks
        if fromD < 20 && toD >= 20 && !PlistTree.isTrue(PlistTree.get(cfg, ["Kernel", "Quirks", "DisableLinkeditJettison"])) {
            rules.append(UpgradeRule(
                id: "quirk-linkedit", category: .kernel,
                title: "Turn on Kernel ▸ Quirks ▸ DisableLinkeditJettison",
                detail: "Recommended from macOS 11 on so Lilu-based kexts can resolve symbols.",
                risk: .safe, selected: true,
                change: { setValue($0, ["Kernel", "Quirks", "DisableLinkeditJettison"], true) }))
        }

        // Kexts: data from OpCore Simplify
        let ocs = ctx.ocs
        if ocs.isEmpty {
            rules.append(UpgradeRule(
                id: "note-no-ocs", category: .info,
                title: "OpCore Simplify's kext data wasn't loaded",
                detail: "Per-kext macOS compatibility checks are skipped. Check your connection and run the analysis again.",
                risk: .info, selected: false))
        }
        var missing: [String: [String]] = [:]
        for n in enabled.sorted() {
            guard let k = ocs[n] else { continue }
            if !k.supports(darwin: toD) {
                let maxText = k.maxDarwin.map { "Darwin \($0).x" } ?? "?"
                rules.append(UpgradeRule(
                    id: "kext-unsupported-\(n)", category: .kexts,
                    title: "\(n).kext doesn't support macOS \(to.name)",
                    detail: "OpCore Simplify lists it up to \(maxText) (\(k.description)). It will most likely fail to load or cause problems, so MacROOT disables it. Look for a replacement for what it did.",
                    risk: .review, selected: true,
                    change: { disableKext($0, named: n) }))
            }
            for r in k.requires where !enabled.contains(r) { missing[r, default: []].append(n) }
        }
        for (r, users) in missing.sorted(by: { $0.key < $1.key }) {
            let userText = users.sorted().joined(separator: ", ")
            if let rk = ocs[r], rk.supports(darwin: toD), let src = rk.source {
                rules.append(UpgradeRule(
                    id: "dep-\(r)", category: .kexts,
                    title: "Add \(r).kext (needed by \(userText))",
                    detail: "OpCore Simplify lists \(r) as a requirement of \(userText) (\(rk.description)). MacROOT downloads it and adds it to Kernel ▸ Add before its dependents.",
                    risk: .review, selected: true,
                    installs: [KextInstallSpec(name: r, spec: src, after: rk.requires)]))
            } else {
                rules.append(UpgradeRule(
                    id: "dep-\(r)-manual", category: .kexts,
                    title: "\(r).kext is required by \(userText) but isn't enabled",
                    detail: "MacROOT has no download source that supports macOS \(to.name) for it. Add it by hand.",
                    risk: .info, selected: false))
            }
        }

        // Conflict groups
        var groups: [String: [String]] = [:]
        for n in enabled { if let g = ocs[n]?.conflict { groups[g, default: []].append(n) } }
        for (g, members) in groups.sorted(by: { $0.key < $1.key }) where members.count > 1 {
            rules.append(UpgradeRule(
                id: "conflict-\(g)", category: .kexts,
                title: "Possible kext conflict (\(g)): \(members.sorted().joined(separator: ", "))",
                detail: "OpCore Simplify treats these as mutually exclusive. Some setups intentionally combine them; check that yours is deliberate.",
                risk: .info, selected: false))
        }

        // Broadcom Bluetooth on Monterey+
        let hasBroadcomBT = !present.isDisjoint(with: ["BrcmPatchRAM3", "BrcmPatchRAM2", "BrcmFirmwareData"])
        if hasBroadcomBT && !present.contains("BlueToolFixup") && toD >= 21 {
            let src: KextSourceSpec? = ocs["BlueToolFixup"]?.source ?? .repo("acidanthera/BrcmPatchRAM")
            if let src = src {
                rules.append(UpgradeRule(
                    id: "add-BlueToolFixup", category: .kexts,
                    title: "Add BlueToolFixup.kext for Broadcom Bluetooth",
                    detail: "OpCore Simplify lists BlueToolFixup (patches the Bluetooth stack for third-party cards) from macOS 12 on, and your config uses Broadcom Bluetooth kexts.",
                    risk: .review, selected: true,
                    installs: [KextInstallSpec(name: "BlueToolFixup", spec: src, after: ["Lilu"])]))
            }
        }

        // AMFI boot-arg -> AMFIPass
        let args = bootArgs(cfg)
        let amfiTokens = args.filter { $0 == "amfi=0x80" || $0.hasPrefix("amfi_get_out_of_my_way=") }
        if !amfiTokens.isEmpty && !present.contains("AMFIPass"), let k = ocs["AMFIPass"], let src = k.source, toD >= 20 {
            rules.append(UpgradeRule(
                id: "amfi-pass", category: .bootArgs,
                title: "Replace \(amfiTokens.joined(separator: " ")) with AMFIPass.kext",
                detail: "OpCore Simplify describes AMFIPass as “a replacement for amfi=0x80”. MacROOT adds the kext and removes the boot argument. Off by default because AMFI changes affect system security and OCLP root patches.",
                risk: .review, selected: false,
                change: { cfg in
                    let kept = bootArgs(cfg).filter { !($0 == "amfi=0x80" || $0.hasPrefix("amfi_get_out_of_my_way=")) }
                    return setValue(cfg, bootArgsPath, kept.joined(separator: " "))
                },
                installs: [KextInstallSpec(name: "AMFIPass", spec: src, after: k.requires)]))
        }

        // Broadcom Wi-Fi on Sonoma+
        if present.contains("AirportBrcmFixup") && toD >= 23 && !present.contains("IO80211FamilyLegacy") {
            var installs: [KextInstallSpec] = []
            for n in ["AMFIPass", "IOSkywalkFamily", "IO80211FamilyLegacy"] where !present.contains(n) {
                if let k = ocs[n], k.supports(darwin: toD), let src = k.source { installs.append(KextInstallSpec(name: n, spec: src, after: k.requires + ["Lilu"])) }
            }
            if !installs.isEmpty {
                rules.append(UpgradeRule(
                    id: "wifi-broadcom", category: .wifi,
                    title: "Native Broadcom Wi-Fi on macOS 14+ needs extra kexts and OCLP root patches",
                    detail: "OpCore Simplify lists IOSkywalkFamily and IO80211FamilyLegacy (with AMFIPass) for “legacy Apple Wireless adapters” from macOS 14. After booting you still have to apply OpenCore Legacy Patcher's root patches. Off by default.",
                    risk: .review, selected: false, installs: installs))
            }
        }
        if present.contains("AirportItlwm") && from.major != to.major {
            rules.append(UpgradeRule(
                id: "wifi-itlwm", category: .wifi,
                title: "AirportItlwm is built per macOS release",
                detail: "Use the AirportItlwm build made for macOS \(to.name) (see the itlwm releases) instead of the one for \(from.name). The Kext updater only replaces it with the first release archive it finds.",
                risk: .info, selected: false))
        }

        // Kernel>Add entries capped below the target
        for e in kernelAdd(cfg) where PlistTree.isTrue(e["Enabled"]) {
            if let mx = e["MaxKernel"] as? String, !mx.isEmpty, let d = Version.parts(mx).first, d < toD, let b = e["BundlePath"] as? String {
                rules.append(UpgradeRule(
                    id: "maxkernel-\(b)", category: .kernel,
                    title: "\(b) is capped at MaxKernel \(mx)",
                    detail: "That is below macOS \(to.name) (Darwin \(toD)), so OpenCore won't inject it there. Replace it with a build for the new release or clear MaxKernel in the Config Studio.",
                    risk: .info, selected: false))
            }
        }

        // CPU without AVX2
        if ctx.cpuHasAVX2 == false && toD >= 22 && !present.contains("CryptexFixup"), let k = ocs["CryptexFixup"], let src = k.source {
            rules.append(UpgradeRule(
                id: "cpu-avx2", category: .kexts,
                title: "This CPU doesn't report AVX2: add CryptexFixup.kext",
                detail: "OpCore Simplify lists CryptexFixup (“various patches to install Rosetta cryptex”) from macOS 13 on. It also lists AppleIntelCPUPowerManagement kexts for legacy Intel CPUs, which you may need as well.",
                risk: .review, selected: false,
                installs: [KextInstallSpec(name: "CryptexFixup", spec: src, after: ["Lilu"])]))
        }

        // Load order
        if orderViolations(cfg, ocs: ocs) {
            rules.append(UpgradeRule(
                id: "reorder", category: .kexts,
                title: "Fix the Kernel ▸ Add load order",
                detail: "Some kexts are listed before the kexts they depend on (Lilu, VirtualSMC, …). MacROOT reorders the list, changing nothing else.",
                risk: .safe, selected: true,
                change: { reorderKernelAdd($0, ocs: ocs) }))
        }

        rules.append(UpgradeRule(
            id: "note-ai", category: .info,
            title: "About these rules",
            detail: "Kext compatibility comes from OpCore Simplify's dataset; structure comes from OpenCore's own Sample.plist; the rest are the few documented rules shown above. OpCore Simplify's authors warn that Hackintosh advice from AI sources is often wrong, so read each change before applying and keep a backup.",
            risk: .info, selected: false))
        return rules
    }
}

// MARK: - Preparing the changes

struct UpgradeResult {
    var finalConfig: [String: Any]
    var items: [UpdateItem]
    var diff: [DiffEntry]
    var package: OCPackage
    var notes: [String]
}

enum UpgradeEngine {
    static func prepare(efi: URL, config: [String: Any], rules: [UpgradeRule], ocs: [String: OCSKext],
                        updateOpenCore: Bool, updateKexts: Bool, migrate: Bool, removeObsolete: Bool,
                        progress: @escaping (String) -> Void) async throws -> UpgradeResult {
        let fm = FileManager.default
        var cfg = config
        var notes: [String] = []
        let chosen = rules.filter { $0.selected && $0.isActionable }

        for r in chosen { if let f = r.change { cfg = f(cfg) } }

        // New kexts
        var newItems: [UpdateItem] = []
        var done = Set<String>()
        let kextDir = efi.appendingPathComponent("OC/Kexts")
        for r in chosen {
            for inst in r.installs where !done.contains(inst.name) {
                done.insert(inst.name)
                let existing = kextDir.appendingPathComponent("\(inst.name).kext")
                var exe = KextInfo.executableName(existing) ?? ""
                if !fm.fileExists(atPath: existing.path) {
                    progress("Downloading \(inst.name)…")
                    do {
                        let src = try await KextFetcher.fetch(name: inst.name, spec: inst.spec)
                        exe = KextInfo.executableName(src) ?? ""
                        newItems.append(UpdateItem(kind: .kext, name: "\(inst.name).kext", installed: "—",
                                                   latest: KextInfo.version(of: src) ?? "new", source: src, dest: existing.path,
                                                   needsUpdate: true, selected: true, note: "New kext added by the Upgrade Assistant"))
                    } catch {
                        notes.append("Couldn't get \(inst.name): \(error.localizedDescription). It was not added.")
                        continue
                    }
                }
                cfg = UpgradeAnalyzer.addKextEntry(cfg, name: inst.name, executable: exe, after: inst.after)
            }
        }
        if !newItems.isEmpty || chosen.contains(where: { $0.id == "reorder" }) {
            cfg = UpgradeAnalyzer.reorderKernelAdd(cfg, ocs: ocs)
        }

        // SMBIOS change
        if let rule = chosen.first(where: { $0.smbiosModel != nil }), let model = rule.smbiosModel {
            progress("Generating SMBIOS for \(model)…")
            let pkg = try await OCPackageManager.latest()
            if let g = await SMBIOSService.generate(model: model, macserial: pkg.macserial) {
                cfg = UpgradeAnalyzer.setValue(cfg, ["PlatformInfo", "Generic", "SystemProductName"], model)
                cfg = UpgradeAnalyzer.setValue(cfg, ["PlatformInfo", "Generic", "SystemSerialNumber"], g.serial)
                cfg = UpgradeAnalyzer.setValue(cfg, ["PlatformInfo", "Generic", "MLB"], g.mlb)
                cfg = UpgradeAnalyzer.setValue(cfg, ["Misc", "Security", "SecureBootModel"], "Disabled")
                notes.append("SMBIOS changed to \(model) with a new serial/MLB; SystemUUID and ROM were kept. Sign in to iCloud/iMessage again afterwards (see the iServices tab).")
            } else {
                notes.append("macserial produced no output; SMBIOS was not changed.")
            }
        }

        // OpenCore, drivers, tools, kexts
        progress("Checking OpenCore and kext releases…")
        let plan = try await UpdatePlanner.plan(efi: efi, config: cfg, includeKexts: updateKexts, removeObsolete: removeObsolete, progress: progress)
        var items = plan.items.filter { $0.kind != .config }
        if !updateOpenCore { items = items.filter { ![.core, .driver, .tool, .resources].contains($0.kind) } }
        items += newItems

        // Final config
        var finalCfg = cfg
        if migrate {
            let sample = try ConfigIO.readDict(plan.package.samplePlist)
            finalCfg = ConfigMigrator.migrate(user: cfg, sample: sample, removeObsolete: removeObsolete).result
        }
        let diff = PlistDiff.diff(config, finalCfg)
        if !(finalCfg as NSDictionary).isEqual(to: config) {
            let staged = AppPaths.cache.appendingPathComponent("upgrade-config.plist")
            let data = try PropertyListSerialization.data(fromPropertyList: finalCfg, format: .xml, options: 0)
            try data.write(to: staged)
            items.append(UpdateItem(kind: .config, name: "config.plist", installed: "", latest: "", source: staged,
                                    dest: efi.appendingPathComponent("OC/config.plist").path,
                                    needsUpdate: true, selected: true, note: "\(diff.count) change(s) from the rules and Sample.plist"))
        }
        return UpgradeResult(finalConfig: finalCfg, items: items, diff: diff, package: plan.package, notes: notes)
    }
}
