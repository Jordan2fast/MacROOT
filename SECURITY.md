# Security

## Reporting a vulnerability
Please use GitHub's **Security ▸ Report a vulnerability** (private advisory) rather than a public issue.

## What MacROOT does that deserves scrutiny
- Runs some actions as root through the standard macOS administrator prompt (`osascript … with administrator privileges`). Scripts are first copied to a root-owned temporary folder so what runs as root can't be swapped after authentication.
- Downloads and installs files onto the EFI partition (OpenCore, drivers, kexts) from GitHub releases. Downloads with a published SHA-256 are verified; others rely on GitHub's TLS.
- Optionally sends PCI device IDs (never your files or identifiers) to the Anthropic API when you use the AI kext generator. Your API key is stored in your login keychain.
- No telemetry. Network endpoints are listed in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Serial, MLB, SystemUUID and ROM are never written to logs or the support report.

## Supported versions
Only the latest release is supported.
