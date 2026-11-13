# MacROOT

**A native macOS toolbox for Hackintosh (x86_64) systems**: mount and back up your EFI, update OpenCore and kexts, edit `config.plist`, migrate a config to a newer macOS, fix iMessage/FaceTime, map USB ports, and more. SwiftUI, macOS 13+, Intel only.

> **Status: pre-release.** Expect rough edges and report them. See [Honest limitations](#honest-limitations).

> ⚠️ Running macOS on non-Apple hardware is outside Apple's licence terms, and editing an EFI can leave a machine unbootable. MacROOT backs up before it writes, but keep your own backup too. Not affiliated with Apple, Acidanthera, Dortania or any project credited below.

## Features
| Tab | What it does |
|---|---|
| **Dashboard** | System, OpenCore, SIP, boot-args, identity, loaded kexts; copy a support report (serial/MLB/UUID/ROM are never included) |
| **EFI Mounter** | Lists EFI partitions, flags the one you booted from, mounts/unmounts, backs up, opens in Finder |
| **Upgrade Assistant** | Migrate an OpenCore config/EFI to a newer macOS (e.g. 13.5 → 26.x): analyze → review → apply → `ocvalidate`. Uses **OpCore Simplify** as a backend |
| **OpenCore & Kexts** | Updates OpenCore, drivers, tools and kexts; migrates `config.plist` against the newest `Sample.plist` |
| **Config Studio** | Full config editor: tree editor, kext/ACPI/driver/tool lists, boot-args and SIP editors, undo/redo, diff, compare, raw XML, audit, `ocvalidate` |
| **SMBIOS** | Generates serial / MLB / UUID / ROM with `macserial` |
| **iServices** | iMessage / FaceTime / App Store sign-in: SMBIOS report, en0 & ROM & MAC fixes, Apple-host checks, NVRAM persistence test, log diagnosis |
| **USB Mapping** | Scans ports, builds and installs `USBMap.kext` |
| **Kext Builder** | Injector kexts, DeviceProperties spoofs, AI-drafted drivers (optional, your API key) + built-in compiler |
| **macOS Installer / Debloat / Toolkit & VM** | The embedded [`macROOT.sh`](Scripts/macROOT.sh): strip 10.9–10.15 installers to a core system + root Terminal, debloat, install OpenCore/OCLP toolkit, VM guest tools. With live progress |
| **Tools / Backups / Logs** | Quick fixes, restore points, session log |
| **Settings / About & Credits** | Options (⌘, too) and every tool this app uses or learned from |

## Install
**From a release:** download `MacROOT-Installer.pkg` from [Releases](../../releases). It is ad-hoc signed, not notarized, so right-click ▸ Open the first time (or `xattr -dr com.apple.quarantine /Applications/MacROOT.app`).

**From source** (macOS with Xcode 16+):
```bash
git clone https://github.com/Jordan2fast/MacROOT.git
cd MacROOT
open MacROOT.xcodeproj        # or: make build
make pkg                      # builds MacROOT-Installer.pkg
```
Targets: **x86_64**, macOS **13.0+**, App Sandbox **off** (mounting and writing the EFI needs it), ad-hoc signing. To sign with your own identity: `APP_SIGN_ID="Developer ID Application: …" PKG_SIGN_ID="Developer ID Installer: …" make pkg`.

## How the Upgrade Assistant decides things
- **Per-kext compatibility** (min/max macOS, required kexts, conflicts, download sources) comes from [OpCore Simplify](https://github.com/lzhoang2801/OpCore-Simplify)'s `kext_data.py`, downloaded at run time and cached.
- **Structure** comes from the newest OpenCore `Sample.plist`: missing keys are added, string-style Drivers entries converted, nothing you set is overwritten.
- **A few built-in rules**, each explaining itself: macOS 27+ is Apple-silicon only (nothing to migrate to), OpenCore ≥ 1.0.5 for macOS 26, `DisableLinkeditJettison` from macOS 11, BlueToolFixup for Broadcom Bluetooth, kext load order, and an SMBIOS-support table for Intel Macs.
- **Risky changes are off by default**: switching SMBIOS model (signs you out of iCloud/iMessage), AMFI changes, Broadcom Wi-Fi root-patch kexts.
- OpCore Simplify itself builds a *new* EFI from a hardware report. MacROOT can download and launch it, then merge selected sections of its result into your config.

More in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Honest limitations
- Not battle-tested: IORegistry key names, the USBMap personality format, kext compile flags and the iServices heuristics follow common practice but need testing on real hardware and current macOS releases.
- macOS 26 Tahoe is the last release for Intel Macs; macOS 27 is Apple silicon only.
- Spoofing and AI-generated drivers may not work, and kernel code can panic the machine. Test with a spare EFI.
- OpCore Simplify's authors warn that Hackintosh advice from AI/LLM sources is often wrong. MacROOT's rules are drawn from its data, OpenCore's own `Sample.plist` and documented behaviour. Verify important changes against [Dortania's guide](https://dortania.github.io/OpenCore-Install-Guide/).
- `config.plist` is rewritten as XML plist: comments and key order are not preserved (OpenCore doesn't care).
- No automated UI tests yet. CI builds the app and checks the scripts.

## Contributing
Issues and PRs welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. **Never paste your serial, MLB, SystemUUID or ROM** in an issue. Security reports: see [SECURITY.md](SECURITY.md).

## Credits & licence
See [CREDITS.md](CREDITS.md) (also in the app under About & Credits). MacROOT is released under the [MIT License](LICENSE). It downloads, but does not bundle, OpenCore, kexts and OpCore Simplify's data; those keep their own licences.
