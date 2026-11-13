import Foundation

// MARK: - Minimal Python-literal reader (just enough for OpCore Simplify's kext_data.py)

enum PyVal {
    case str(String)
    case bool(Bool)
    case list([PyVal])
    case dict([String: PyVal])
    case other

    var string: String? { if case .str(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var strings: [String] { if case .list(let l) = self { return l.compactMap { $0.string } }; return [] }
    var dictValue: [String: PyVal]? { if case .dict(let d) = self { return d }; return nil }
}

struct PyParser {
    private let c: [Character]
    private(set) var i = 0

    init(_ text: String, at offset: Int = 0) {
        c = Array(text)
        i = offset
    }

    private mutating func skipSpace() {
        while i < c.count {
            if c[i].isWhitespace { i += 1 }
            else if c[i] == "#" { while i < c.count && c[i] != "\n" { i += 1 } }
            else { break }
        }
    }

    private mutating func parseString() -> String {
        let q = c[i]
        i += 1
        var out = ""
        while i < c.count, c[i] != q {
            if c[i] == "\\", i + 1 < c.count { out.append(c[i + 1]); i += 2 } else { out.append(c[i]); i += 1 }
        }
        i += 1
        return out
    }

    private mutating func skipBalanced() {
        var depth = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\"" || ch == "'" { _ = parseString(); continue }
            if ch == "(" || ch == "[" || ch == "{" { depth += 1 }
            else if ch == ")" || ch == "]" || ch == "}" {
                depth -= 1
                if depth <= 0 { i += 1; return }
            }
            i += 1
        }
    }

    mutating func parseValue() -> PyVal {
        skipSpace()
        guard i < c.count else { return .other }
        let ch = c[i]
        if ch == "\"" || ch == "'" { return .str(parseString()) }
        if ch == "[" {
            i += 1
            var items: [PyVal] = []
            while true {
                skipSpace()
                if i >= c.count { break }
                if c[i] == "]" { i += 1; break }
                let before = i
                items.append(parseValue())
                skipSpace()
                if i < c.count, c[i] == "," { i += 1 }
                if i == before { i += 1 }
            }
            return .list(items)
        }
        if ch == "{" {
            i += 1
            var d: [String: PyVal] = [:]
            while true {
                skipSpace()
                if i >= c.count { break }
                if c[i] == "}" { i += 1; break }
                let before = i
                let k = parseValue()
                skipSpace()
                if i < c.count, c[i] == ":" {
                    i += 1
                    let v = parseValue()
                    if let key = k.string { d[key] = v }
                }
                skipSpace()
                if i < c.count, c[i] == "," { i += 1 }
                if i == before { i += 1 }
            }
            return .dict(d)
        }
        let start = i
        while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "." || c[i] == "-" { i += 1 }
        let word = String(c[start..<i])
        skipSpace()
        if i < c.count, c[i] == "(" { skipBalanced(); return .other }
        if word == "True" { return .bool(true) }
        if word == "False" { return .bool(false) }
        if i == start { i += 1 }
        return .other
    }

    /// Parses `name = value, name2 = value2 )` and consumes the closing parenthesis.
    mutating func parseKeywordArguments() -> [String: PyVal] {
        var out: [String: PyVal] = [:]
        while true {
            skipSpace()
            if i >= c.count { break }
            if c[i] == ")" { i += 1; break }
            let before = i
            let start = i
            while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" { i += 1 }
            let key = String(c[start..<i])
            skipSpace()
            if !key.isEmpty, i < c.count, c[i] == "=" {
                i += 1
                out[key] = parseValue()
            } else {
                i = before
                _ = parseValue()
            }
            skipSpace()
            if i < c.count, c[i] == "," { i += 1 }
            if i == before { i += 1 }
        }
        return out
    }
}

// MARK: - OpCore Simplify data

struct OCSKext: Identifiable {
    let name: String
    let description: String
    let category: String
    let required: Bool
    let minDarwin: Int?
    let maxDarwin: Int?
    let requires: [String]
    let conflict: String?
    let repo: String?
    let url: String?
    let sha256: String?

    var id: String { name }

    func supports(darwin: Int) -> Bool {
        (minDarwin ?? 0) <= darwin && darwin <= (maxDarwin ?? 999)
    }
}

/// Process-wide cache so the (synchronous) kext registry can consult OpCore Simplify's repo list.
final class OCSStore: @unchecked Sendable {
    static let shared = OCSStore()
    private let lock = NSLock()
    private var table: [String: OCSKext] = [:]

    var kexts: [String: OCSKext] {
        get { lock.lock(); defer { lock.unlock() }; return table }
        set { lock.lock(); table = newValue; lock.unlock() }
    }
}

enum OCSBackend {
    static let rawKextData = "https://github.com/lzhoang2801/OpCore-Simplify/raw/refs/heads/main/Scripts/datasets/kext_data.py"
    static let zipURL = "https://github.com/lzhoang2801/OpCore-Simplify/archive/refs/heads/main.zip"
    static let repoPage = "https://github.com/lzhoang2801/OpCore-Simplify"

    static var dir: URL {
        let u = AppPaths.support.appendingPathComponent("OpCore-Simplify", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var dataFile: URL { dir.appendingPathComponent("kext_data.py") }
    static var toolFolder: URL { dir.appendingPathComponent("OpCore-Simplify-main", isDirectory: true) }
    static var launcher: URL { toolFolder.appendingPathComponent("OpCore-Simplify.command") }

    private static func darwinMajor(_ s: String?) -> Int? {
        guard let s = s, !s.isEmpty else { return nil }
        return Version.parts(s).first
    }

    /// Parses kext_data.py source into kext records.
    static func parse(_ source: String) -> [OCSKext] {
        var out: [OCSKext] = []
        var search = source.startIndex
        let marker = "KextInfo("
        while let r = source.range(of: marker, range: search..<source.endIndex) {
            let offset = source.distance(from: source.startIndex, to: r.upperBound)
            var p = PyParser(source, at: offset)
            let kw = p.parseKeywordArguments()
            search = r.upperBound
            guard let name = kw["name"]?.string else { continue }
            let gh = kw["github_repo"]?.dictValue
            let owner = gh?["owner"]?.string
            let repoName = gh?["repo"]?.string
            let dl = kw["download_info"]?.dictValue
            out.append(OCSKext(
                name: name,
                description: kw["description"]?.string ?? "",
                category: kw["category"]?.string ?? "",
                required: kw["required"]?.boolValue ?? false,
                minDarwin: darwinMajor(kw["min_darwin_version"]?.string),
                maxDarwin: darwinMajor(kw["max_darwin_version"]?.string),
                requires: kw["requires_kexts"]?.strings ?? [],
                conflict: kw["conflict_group_id"]?.string,
                repo: (owner != nil && repoName != nil) ? "\(owner!)/\(repoName!)" : nil,
                url: dl?["url"]?.string,
                sha256: dl?["sha256"]?.string))
        }
        return out
    }

    /// Loads OpCore Simplify's kext dataset (downloading it when missing or older than `maxAgeDays`).
    static func loadKextData(forceRefresh: Bool = false, maxAgeDays: Double = 7) async throws -> [String: OCSKext] {
        let fm = FileManager.default
        var needDownload = forceRefresh || !fm.fileExists(atPath: dataFile.path)
        if !needDownload,
           let attrs = try? fm.attributesOfItem(atPath: dataFile.path),
           let date = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(date) > maxAgeDays * 86400 { needDownload = true }
        if needDownload {
            do {
                guard let url = URL(string: rawKextData) else { throw GitHub.GHError.invalid("Bad OpCore Simplify URL") }
                var req = URLRequest(url: url)
                req.setValue("MacROOT", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw GitHub.GHError.http(http.statusCode, "OpCore-Simplify kext_data.py") }
                guard String(data: data, encoding: .utf8)?.contains("KextInfo(") == true else {
                    throw GitHub.GHError.invalid("OpCore Simplify's kext_data.py has an unexpected format.")
                }
                try data.write(to: dataFile, options: .atomic)
            } catch {
                if !fm.fileExists(atPath: dataFile.path) { throw error }   // fall back to the cached copy
            }
        }
        let text = try String(contentsOf: dataFile, encoding: .utf8)
        let list = parse(text)
        guard !list.isEmpty else { throw GitHub.GHError.invalid("Couldn't read any kexts from OpCore Simplify's data.") }
        let table = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        OCSStore.shared.kexts = table
        return table
    }

    /// Downloads the full OpCore Simplify tool (zip of the main branch) so it can be launched.
    static func downloadTool() async throws -> URL {
        guard let url = URL(string: zipURL) else { throw GitHub.GHError.invalid("Bad URL") }
        var req = URLRequest(url: url)
        req.setValue("MacROOT", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw GitHub.GHError.http(http.statusCode, "OpCore-Simplify") }
        let stage = dir.appendingPathComponent("stage", isDirectory: true)
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let zip = stage.appendingPathComponent("main.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)
        let r = await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path])
        guard r.ok else { throw GitHub.GHError.invalid("Unzip failed: \(r.combined)") }
        let extracted = stage.appendingPathComponent("OpCore-Simplify-main")
        guard FileManager.default.fileExists(atPath: extracted.path) else { throw GitHub.GHError.invalid("Unexpected archive layout.") }
        try? FileManager.default.removeItem(at: toolFolder)
        try FileManager.default.moveItem(at: extracted, to: toolFolder)
        try? FileManager.default.removeItem(at: stage)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return toolFolder
    }
}

// MARK: - Fetching a kext from a repo or direct URL

enum KextSourceSpec {
    case repo(String)
    case url(String, sha256: String?)
}

extension OCSKext {
    /// Direct download link (with checksum) wins, like OpCore Simplify itself; otherwise the repo's latest release.
    var source: KextSourceSpec? {
        if let u = url { return .url(u, sha256: sha256) }
        if let r = repo { return .repo(r) }
        return nil
    }
}

enum KextFetcher {
    /// Returns the folder of `<name>.kext` inside the downloaded release/archive.
    static func fetch(name: String, spec: KextSourceSpec) async throws -> URL {
        switch spec {
        case .repo(let repo):
            let rel = try await GitHub.latest(repo)
            let root = try await GitHub.fetchAndExtract(rel, repo: repo)
            guard let k = KextInfo.find(name + ".kext", in: root) else { throw GitHub.GHError.invalid("\(name).kext isn't in the latest \(repo) release.") }
            return k
        case .url(let u, let sha):
            guard let url = URL(string: u) else { throw GitHub.GHError.invalid("Bad URL for \(name)") }
            let key = FileOps.sha256Of(Data(u.utf8)).prefix(16)
            let dir = AppPaths.cache.appendingPathComponent("kexts/url-\(key)", isDirectory: true)
            let out = dir.appendingPathComponent("x", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".done").path) {
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var req = URLRequest(url: url)
                req.setValue("MacROOT", forHTTPHeaderField: "User-Agent")
                let (tmp, resp) = try await URLSession.shared.download(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw GitHub.GHError.http(http.statusCode, name) }
                let zip = dir.appendingPathComponent("download.zip")
                try FileManager.default.moveItem(at: tmp, to: zip)
                if let sha = sha, let got = FileOps.sha256(zip), got.lowercased() != sha.lowercased() {
                    throw GitHub.GHError.invalid("Checksum mismatch for \(name); refusing to use the download.")
                }
                let r = await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
                guard r.ok else { throw GitHub.GHError.invalid("Unzip failed: \(r.combined)") }
                FileManager.default.createFile(atPath: dir.appendingPathComponent(".done").path, contents: Data())
            }
            guard let k = KextInfo.find(name + ".kext", in: out) else { throw GitHub.GHError.invalid("\(name).kext isn't in the downloaded archive.") }
            return k
        }
    }
}
