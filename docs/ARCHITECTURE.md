# Architecture

## Principles
1. Read-only until you press a button; preview before apply.
2. Every write to the EFI or `config.plist` is preceded by a backup in `~/Documents/MacROOT Backups`.
3. Privileged work goes through one path (`Shell.runPrivileged` / `ScriptJob`), never ad-hoc.
4. No telemetry.

## Layers
```
Views (SwiftUI)  →  Services (logic)  →  Core (process, files, IORegistry)
```

### Core
- `Shell.swift`: async `Process` runner that drains large output (`ioreg -l`); `runPrivileged` writes a temp script and runs it via `osascript … with administrator privileges`.
- `Util.swift`: `Data` helpers, `Version` comparison, `AppPaths`, `Keychain`, `FileOps` (SHA-256, privileged-fallback writes, EFI/config backups).
- `IORegistry.swift`: `ioreg -a` parsing, PCI scanner (+ OpenCore device paths from `acpi-path`), `SystemInfoService`.
- `DiskService.swift`: EFI partitions from `diskutil`, mount/unmount, GUID of the partition OpenCore booted from.
- `MacROOTScript.swift`: **generated** from `Scripts/macROOT.sh`.

### Services
- `ConfigDocument.swift`: `PlistTree` (path get/modify), `ConfigDocument` (undo/redo, dirty tracking, save), `PlistDiff`, `ConfigAudit`, `ConfigMigrator` (merge against `Sample.plist`).
- `Updater.swift`: GitHub client, OpenCore package, `KextRegistry`, `UpdatePlanner` (SHA-256/version comparison, apply script).
- `OCSBackend.swift`: a small Python-literal reader for OpCore Simplify's `kext_data.py`, the kext dataset, the tool downloader, and `KextFetcher`.
- `MacOSVersions.swift`: `MacOSVersion` (Darwin mapping), `MacModelSupport` table, `AppInfo`.
- `UpgradeEngine.swift`: `UpgradeRule`, `UpgradeAnalyzer` (rules), `UpgradeEngine.prepare` (apply rules → fetch kexts → plan OpenCore/kext updates → migrate → diff).
- `IServices.swift`: SMBIOS report, live checks, AML MAC patching with ACPI checksum, NVRAM persistence test, log analysis.
- `ScriptJob.swift`: runs the embedded `macROOT.sh` (or a command) with live output, progress and cancel; root copies of the script live in a root-owned temp dir.
- `KextForge.swift`, `SystemTools.swift`, `InstallerTools.swift`, `Backups.swift`.

### Views
One file per page; `AppState` holds shared state (EFI selection, open config, log, the shared `ScriptJob`).

## Upgrade Assistant data flow
```
selected EFI → config.plist ─┐
OpCore Simplify kext_data.py ─┼→ UpgradeAnalyzer → [UpgradeRule]
OpenCore NVRAM version / CPU ─┘          │ user ticks rules
                                          ▼
 UpgradeEngine.prepare: apply rules → download new kexts → UpdatePlanner (OC, drivers, kexts)
                        → ConfigMigrator(Sample.plist) → PlistDiff → UpgradeResult
                                          │ user reviews
                                          ▼
 backup EFI → apply script (ditto) → ocvalidate → reload config
```

## Network endpoints
| Host | Why |
|---|---|
| `api.github.com`, `github.com` (release downloads) | OpenCore and kext releases, OpCore Simplify archive |
| `raw.githubusercontent.com` / `github.com/.../raw/...` | OpCore Simplify's `kext_data.py` |
| `api.anthropic.com` | Optional AI kext generator (only with your key) |
| `albert.apple.com`, `identity.ess.apple.com`, `gsa.apple.com` | iServices reachability checks (HTTPS, certificate issuer only) |
| Hosts in OpCore Simplify's dataset (e.g. `nightly.link`, `raw.githubusercontent.com`) | Kexts that have a direct download link; SHA-256 verified when provided |

## Known gaps
No unit tests; kext compile flags, USBMap personality format and iServices heuristics are unverified on current macOS; see README ▸ Honest limitations.
