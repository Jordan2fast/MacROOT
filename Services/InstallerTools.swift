import Foundation

// MARK: - Installer apps

struct InstallerApp: Identifiable, Hashable {
    enum Layout: String {
        case ready, unsupported, incomplete
    }
    let url: URL
    let version: String?
    let layout: Layout
    let esdBytes: Int64

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var layoutText: String {
        switch layout {
        case .ready: return "Ready (InstallESD.dmg)"
        case .unsupported: return "Unsupported: macOS 11+ layout"
        case .incomplete: return "Incomplete: no InstallESD.dmg"
        }
    }
    /// The script refuses to start without roughly 4x the ESD size free in the output folder.
    var neededBytes: Int64 { esdBytes * 4 }
}

enum InstallerScanner {
    static func scan() -> [InstallerApp] {
        let fm = FileManager.default
        var dirs = [URL(fileURLWithPath: "/Applications"),
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")]
        for u in (try? fm.contentsOfDirectory(atPath: "/Users")) ?? [] where u != "Shared" && !u.hasPrefix(".") {
            dirs.append(URL(fileURLWithPath: "/Users/\(u)/Downloads"))
        }
        var seen = Set<String>()
        var out: [InstallerApp] = []
        for d in dirs {
            let items = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            for u in items where u.lastPathComponent.hasPrefix("Install") && u.pathExtension == "app" {
                if seen.insert(u.path).inserted { out.append(inspect(u)) }
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    static func inspect(_ url: URL) -> InstallerApp {
        let fm = FileManager.default
        let ss = url.appendingPathComponent("Contents/SharedSupport")
        let esd = ss.appendingPathComponent("InstallESD.dmg")
        let layout: InstallerApp.Layout
        if fm.fileExists(atPath: esd.path) { layout = .ready }
        else if fm.fileExists(atPath: ss.appendingPathComponent("SharedSupport.dmg").path) { layout = .unsupported }
        else { layout = .incomplete }
        var size: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: esd.path), let n = attrs[.size] as? NSNumber { size = n.int64Value }
        let info = try? ConfigIO.readDict(url.appendingPathComponent("Contents/Info.plist"))
        return InstallerApp(url: url, version: info?["CFBundleShortVersionString"] as? String, layout: layout, esdBytes: size)
    }
}

// MARK: - Installers Apple still offers

struct AppleInstaller: Identifiable {
    let title: String
    let version: String
    let sizeKiB: Int64
    var id: String { "\(title)-\(version)" }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: sizeKiB * 1024, countStyle: .file) }
    /// `macROOT.sh build` only understands the InstallESD.dmg layout used up to macOS 10.15.
    var buildable: Bool { version.hasPrefix("10.") }
}

enum AppleInstallerList {
    static func fetch() async -> (items: [AppleInstaller], raw: String) {
        let r = await Shell.run("/usr/sbin/softwareupdate", ["--list-full-installers"])
        var items: [AppleInstaller] = []
        if let re = try? NSRegularExpression(pattern: "Title: ([^,]+), Version: ([^,]+), Size: (\\d+)KiB") {
            for line in r.out.split(separator: "\n") {
                let l = String(line)
                let ns = l as NSString
                if let m = re.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
                    items.append(AppleInstaller(title: ns.substring(with: m.range(at: 1)),
                                                version: ns.substring(with: m.range(at: 2)),
                                                sizeKiB: Int64(ns.substring(with: m.range(at: 3))) ?? 0))
                }
            }
        }
        return (items, r.combined)
    }
}

// MARK: - macOS volumes (debloat / toolkit targets)

struct MacVolume: Identifiable, Hashable {
    let path: String
    let name: String
    var id: String { path }
}

enum VolumeScanner {
    static func macOSVolumes() -> [MacVolume] {
        let fm = FileManager.default
        var out = [MacVolume(path: "/", name: "Running system (this Mac)")]
        for v in ((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []).sorted() {
            let url = URL(fileURLWithPath: "/Volumes/\(v)")
            if url.resolvingSymlinksInPath().path == "/" { continue }
            let hasMac = fm.fileExists(atPath: url.appendingPathComponent("Applications").path)
                || fm.fileExists(atPath: url.appendingPathComponent("Library").path)
            if hasMac { out.append(MacVolume(path: url.path, name: v)) }
        }
        return out
    }
}
