# Changelog

All notable changes to MacROOT. Format based on [Keep a Changelog](https://keepachangelog.com/).

## [1.2.0]
### Added
- **Upgrade Assistant**: migrate an OpenCore config/EFI to a newer macOS (e.g. 13.5 → 26.x). Uses OpCore Simplify's kext dataset, OpenCore's `Sample.plist`, `ocvalidate` and a few documented rules. Preview → backup → apply → validate. Includes an OpCore Simplify launcher and a section-by-section EFI merge.
- **Config Studio**: full config.plist editor with undo/redo, tree editor, list editors (kexts, ACPI, drivers, tools), boot-args and SIP editors, diff against the saved file, compare with any plist, raw XML, consistency audit, `ocvalidate`.
- **iServices**: native port of `iservices-helper.sh` (SMBIOS report, en0/ROM/MAC fixes incl. NullEthernet SSDT patching, Apple-host checks, NVRAM persistence test, iMessage log diagnosis).
- **Backups** manager with restore; retention settings.
- **Settings** page in the sidebar (also ⌘,), **About & Credits**, Dashboard "Copy support report".
- Kext update checker now consults OpCore Simplify's repo data; optional pre-releases.

### Changed
- Sidebar grouped into sections; Config tab renamed Config Studio.

## [1.1.0]
### Added
- **macOS Installer, Debloat, Toolkit & VM** tabs built around the embedded `macROOT.sh` (strip 10.9–10.15 installers, debloat, toolkit, VM tools) with live progress and cancel.

## [1.0.0]
### Added
- First release (formerly *TestKit*): Dashboard, EFI Mounter, OpenCore & Kext updater, config checker, SMBIOS generator, USB mapping, Kext Builder (injector, DeviceProperties spoof, AI-drafted drivers), Tools, `installer.pkg` build script.
