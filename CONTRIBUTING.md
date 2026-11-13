# Contributing

Thanks for helping. MacROOT is a SwiftUI app for x86_64 Macs (macOS 13+) that edits EFI partitions, so the bar for safety is high.

## Build
1. macOS with **Xcode 16+**. Open `MacROOT.xcodeproj`, scheme **MacROOT**. The `MacROOT/` folder is a synchronized group: add files there and they compile.
2. Or `make build`. `make pkg` builds `MacROOT-Installer.pkg`.
3. App Sandbox is **off** on purpose (mounting and writing the EFI needs it).

## Layout
| Path | Contents |
|---|---|
| `MacROOT/Core` | Shell/process runner, utilities, IORegistry and disk helpers, generated `MacROOTScript.swift` |
| `MacROOT/Services` | Logic without UI: config model + diff + audit + migration, updater, OpCore Simplify backend, upgrade rules, iServices, kext tools, backups |
| `MacROOT/Views` | SwiftUI pages |
| `Scripts/` | `macROOT.sh` (embedded in the app), `iservices-helper.sh` (reference, ported natively), `embed_script.py` |
| `Packaging/` | pkg build script and installer resources |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Rules of the road
- **Back up before writing.** Anything that changes the EFI or `config.plist` goes through `FileOps.backupEFI` / `ConfigDocument.save`.
- **Never log or export** serial, MLB, SystemUUID or ROM.
- **Risky changes default to off** and say why (SMBIOS model, AMFI, security-lowering).
- **Cite your source** in user-facing text for rules about specific macOS/OpenCore behaviour (OpenCore changelog, Dortania, OpCore Simplify data). Hackintosh folklore spreads fast. If you aren't sure, make the rule informational.
- If you edit `Scripts/macROOT.sh`, run `make embed` and commit `MacROOT/Core/MacROOTScript.swift` (CI checks this).

## Adding things
- **A migration rule**: add it in `UpgradeAnalyzer.analyze` (`MacROOT/Services/UpgradeEngine.swift`). A rule has an id, category, title, detail, risk, default selection, and optionally a `change` function, `installs` (kexts to download) or `smbiosModel`.
- **A kext update source**: add it to `KextRegistry.builtin` (`Updater.swift`), or let users add one in Settings ▸ Update sources.
- **A macOS version**: extend `MacOSVersion` and `MacModelSupport` (`MacOSVersions.swift`).

## Testing
There is no automated UI test suite yet. CI builds the app and checks the scripts. When you change parsing, diffing or patching logic, please test it against real config/AML/kext samples, and say what you tested on (hardware, macOS, OpenCore version) in the PR.
