import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings().tabItem { Label("Accounts & AI", systemImage: "key") }
            SourcesSettings().tabItem { Label("Update sources", systemImage: "arrow.triangle.2.circlepath") }
            ScrollView { CreditsContent().padding(20) }.tabItem { Label("About & credits", systemImage: "info.circle") }
        }
    }
}

struct GeneralSettings: View {
    @AppStorage("keepBackups") private var keepBackups = 20
    @AppStorage("autoPruneBackups") private var autoPrune = true
    @AppStorage("includePrereleases") private var prereleases = false
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Backups") {
                Stepper("Keep the newest \(keepBackups) EFI backups and \(keepBackups) config backups", value: $keepBackups, in: 3...200)
                Toggle("Delete older backups automatically after each backup", isOn: $autoPrune)
                HStack {
                    Button("Prune now") { Backups.prune(force: true); message = "Pruned." }
                    Button("Open backups folder") { NSWorkspace.shared.open(AppPaths.backups) }
                }
            }
            Section("Updates") {
                Toggle("Include pre-releases when checking GitHub for kext and OpenCore updates", isOn: $prereleases)
                HStack {
                    Button("Refresh OpCore Simplify kext data") { Task { await refresh() } }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            Section("Folders") {
                LabeledContent("Backups", value: AppPaths.backups.path)
                LabeledContent("Built kexts", value: AppPaths.kextProjects.path)
                LabeledContent("Downloads cache", value: AppPaths.cache.path)
                Button("Clear downloads cache") {
                    try? FileManager.default.removeItem(at: AppPaths.cache)
                    message = "Cache cleared."
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }

    private func refresh() async {
        busy = true
        defer { busy = false }
        do {
            let t = try await OCSBackend.loadKextData(forceRefresh: true)
            message = "Loaded \(t.count) kexts from OpCore Simplify's dataset."
        } catch {
            message = "Failed: \(error.localizedDescription)"
        }
    }
}

struct AccountsSettings: View {
    @AppStorage("aiModel") private var aiModel = "claude-sonnet-5-5"
    @State private var github = Keychain.get("github-token") ?? ""
    @State private var anthropic = Keychain.get("anthropic-key") ?? ""

    var body: some View {
        Form {
            Section("GitHub") {
                SecureField("Personal access token (optional)", text: $github)
                    .onChange(of: github) { v in Keychain.set(v, for: "github-token") }
                Text("Only needed if update checks hit GitHub's anonymous rate limit (60 requests per hour). No scopes required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI kext generator (optional)") {
                SecureField("Anthropic API key", text: $anthropic)
                    .onChange(of: anthropic) { v in Keychain.set(v, for: "anthropic-key") }
                TextField("Model", text: $aiModel)
                Text("The key lives in your login keychain and is only sent to api.anthropic.com. Generated drivers are experimental, and OpCore Simplify's authors rightly warn that Hackintosh advice from AI is often wrong. Read generated code before loading it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SourcesSettings: View {
    @AppStorage("customKextSources") private var custom = ""

    var body: some View {
        Form {
            Section("Where kext updates come from") {
                Text("Order of lookup: your own list below, then OpCore Simplify's dataset (kept current by its maintainer), then MacROOT's built-in list.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $custom)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 150)
                Text("One per line: Name.kext=owner/repo (for example AirportItlwm.kext=DexterSLamb/itlwm). The repo's latest GitHub release must be a .zip containing the kext.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Credits

struct Credit: Identifiable {
    let name: String
    let author: String
    let what: String
    let url: String
    var id: String { name }
}

enum Credits {
    static let used: [Credit] = [
        Credit(name: "OpCore Simplify", author: "lzhoang2801",
               what: "Backend for the Upgrade Assistant: its kext dataset (per-macOS compatibility, requirements, download sources) drives the analysis, and its generated EFIs can be merged. BSD 3-Clause.",
               url: "https://github.com/lzhoang2801/OpCore-Simplify"),
        Credit(name: "OpenCorePkg (OpenCore, ocvalidate, macserial, Sample.plist)", author: "Acidanthera",
               what: "The bootloader itself, the config validator and serial generator MacROOT runs, and the Sample.plist configs are migrated against.",
               url: "https://github.com/acidanthera/OpenCorePkg"),
        Credit(name: "Lilu, VirtualSMC, WhateverGreen, AppleALC, NVMeFix, CPUFriend, RestrictEvents, HibernationFixup, BrcmPatchRAM, AirportBrcmFixup, CryptexFixup, FeatureUnlock, VoodooPS2", author: "Acidanthera",
               what: "Kexts MacROOT checks and updates.", url: "https://github.com/acidanthera"),
        Credit(name: "OpenCore Legacy Patcher payloads", author: "Dortania",
               what: "Source of kexts such as AMFIPass and IO80211FamilyLegacy that OpCore Simplify's dataset points to.",
               url: "https://github.com/dortania/OpenCore-Legacy-Patcher"),
        Credit(name: "Other kext authors in OpCore Simplify's dataset", author: "Many",
               what: "Including VoodooI2C, Mieze (Realtek/Atheros/Intel Ethernet), ChefKissInc (NootedRed, NootRX, ForgedInvariant), DexterSLamb (itlwm), lshbluesky (IntelBluetoothFirmware), USBToolBox, 1Revenger1 (ECEnabler), 0xFireWolf (RealtekCardReader) and others.",
               url: "https://github.com/lzhoang2801/OpCore-Simplify"),
        Credit(name: "Claude API", author: "Anthropic", what: "Optional AI kext generator (your own API key).", url: "https://www.anthropic.com")
    ]

    static let inspiration: [Credit] = [
        Credit(name: "OpenCore Install Guide", author: "Dortania",
               what: "The reference for nearly every rule, quirk and checklist here, and the iServices guidance.",
               url: "https://dortania.github.io/OpenCore-Install-Guide/"),
        Credit(name: "Hackintool", author: "headkaze", what: "Inspiration for the PCI, USB and SMBIOS tooling.", url: "https://github.com/headkaze/Hackintool"),
        Credit(name: "MountEFI, ProperTree, USBMap, OCConfigCompare, SSDTTime", author: "CorpNewt",
               what: "Inspiration for the EFI mounter, plist editor, USB mapping, config comparison and ACPI work.",
               url: "https://github.com/corpnewt"),
        Credit(name: "GenSMBIOS", author: "CorpNewt",
               what: "The SMBIOS flow in iservices-helper.sh followed it. MacROOT generates with macserial directly, the engine GenSMBIOS also uses.",
               url: "https://github.com/corpnewt/GenSMBIOS"),
        Credit(name: "OpenCore Auxiliary Tools (OCAT)", author: "ic005k", what: "Inspiration for a full GUI config editor.", url: "https://github.com/ic005k/OCAuxiliaryTools"),
        Credit(name: "USBToolBox", author: "USBToolBox", what: "Inspiration for USB mapping.", url: "https://github.com/USBToolBox"),
        Credit(name: "Hardware Sniffer", author: "lzhoang2801", what: "Produces the hardware report OpCore Simplify needs.", url: "https://github.com/lzhoang2801/Hardware-Sniffer"),
        Credit(name: "macROOT.sh and iservices-helper.sh", author: "The MacROOT project",
               what: "The installer-stripping, debloat, toolkit and iServices logic built into this app.", url: "https://github.com/lzhoang2801/OpCore-Simplify")
    ]
}

struct CreditsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacROOT \(AppInfo.version)").font(.title2.bold())
                    Text("Build \(AppInfo.build) · x86_64 · macOS 13 or later").foregroundStyle(.secondary)
                }
            }
            Text("MacROOT stands on the work of the Hackintosh community. None of these projects endorse MacROOT and MacROOT isn't affiliated with Apple or any of them. Please support and report issues to the original authors.")
                .font(.callout)
            Group {
                Text("Used by MacROOT").font(.headline)
                ForEach(Credits.used) { c in creditRow(c) }
                Text("Inspiration").font(.headline).padding(.top, 6)
                ForEach(Credits.inspiration) { c in creditRow(c) }
            }
            Text("Heads-up: OpCore Simplify's authors warn that Hackintosh information from AI/LLM sources is often wrong. MacROOT's rules are drawn from OpCore Simplify's data, OpenCore's own Sample.plist and documented behaviour. Check anything important against Dortania's guide and keep a backup.")
                .font(.callout).foregroundStyle(.orange)
            Text("Running macOS on non-Apple hardware falls outside Apple's macOS licence terms. MacROOT doesn't change that, so use it at your own risk.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func creditRow(_ c: Credit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(c.name).font(.callout.weight(.semibold))
                Text("· \(c.author)").font(.callout).foregroundStyle(.secondary)
            }
            Text(c.what).font(.caption).foregroundStyle(.secondary)
            if let u = URL(string: c.url) { Link(c.url, destination: u).font(.caption) }
        }
    }
}
