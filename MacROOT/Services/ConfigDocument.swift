import Foundation
import Combine

enum ConfigError: LocalizedError {
    case notADictionary
    var errorDescription: String? { "config.plist is not a dictionary at the top level." }
}

enum ConfigIO {
    static func readDict(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let d = obj as? [String: Any] else { throw ConfigError.notADictionary }
        return d
    }
}

/// Path-based access into nested plist dictionaries/arrays. Path components are
/// String (dictionary key) or Int (array index; an index equal to the count appends).
enum PlistTree {
    enum Kind: String, CaseIterable {
        case dict = "Dictionary", array = "Array", string = "String", bool = "Boolean"
        case int = "Integer", real = "Real", data = "Data", date = "Date", other = "Other"
    }

    static func kind(of v: Any) -> Kind {
        if v is [String: Any] { return .dict }
        if v is [Any] { return .array }
        if v is Data { return .data }
        if v is Date { return .date }
        if v is String { return .string }
        if let n = v as? NSNumber {
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return .bool }
            return CFNumberIsFloatType(n as CFNumber) ? .real : .int
        }
        return .other
    }

    /// Short human-readable rendering of a value.
    static func describe(_ v: Any) -> String {
        switch kind(of: v) {
        case .dict: return "{\((v as? [String: Any])?.count ?? 0) keys}"
        case .array: return "[\((v as? [Any])?.count ?? 0) items]"
        case .string:
            let s = (v as? String) ?? ""
            return "\"" + (s.count > 70 ? String(s.prefix(70)) + "…" : s) + "\""
        case .bool: return isTrue(v) ? "true" : "false"
        case .int: return "\((v as? NSNumber)?.int64Value ?? 0)"
        case .real: return "\((v as? NSNumber)?.doubleValue ?? 0)"
        case .data:
            let d = (v as? Data) ?? Data()
            let h = d.hex
            return (h.count > 32 ? String(h.prefix(32)) + "…" : h) + " (\(d.count) bytes)"
        case .date: return "\(v)"
        case .other: return "\(v)"
        }
    }

    /// Type-tagged full value, used for equality checks.
    static func tag(_ v: Any) -> String {
        switch kind(of: v) {
        case .string: return "s:" + ((v as? String) ?? "")
        case .data: return "d:" + ((v as? Data)?.hex ?? "")
        case .bool: return "b:" + describe(v)
        case .int, .real: return "n:" + describe(v)
        default: return "o:" + describe(v)
        }
    }

    static func get(_ root: Any, _ path: [Any]) -> Any? {
        var cur: Any = root
        for comp in path {
            if let key = comp as? String, let d = cur as? [String: Any], let v = d[key] {
                cur = v
            } else if let idx = comp as? Int, let a = cur as? [Any], a.indices.contains(idx) {
                cur = a[idx]
            } else {
                return nil
            }
        }
        return cur
    }

    /// Applies `f` to the value at `path`. Returning nil from `f` deletes that dictionary key / array element.
    /// Returns the updated root, or nil if the path can't be followed.
    static func modify(_ node: Any, _ path: ArraySlice<Any>, _ f: (Any?) -> Any?) -> Any? {
        guard let comp = path.first else { return f(node) }
        let rest = path.dropFirst()
        if let key = comp as? String {
            var dict = (node as? [String: Any]) ?? [:]
            if rest.isEmpty {
                if let nv = f(dict[key]) { dict[key] = nv } else { dict.removeValue(forKey: key) }
                return dict
            }
            let child: Any = dict[key] ?? [String: Any]()
            guard let updated = modify(child, rest, f) else { return nil }
            dict[key] = updated
            return dict
        }
        if let idx = comp as? Int, var arr = node as? [Any] {
            if rest.isEmpty {
                if idx == arr.count {
                    if let nv = f(nil) { arr.append(nv) }
                    return arr
                }
                guard arr.indices.contains(idx) else { return nil }
                if let nv = f(arr[idx]) { arr[idx] = nv } else { arr.remove(at: idx) }
                return arr
            }
            guard arr.indices.contains(idx), let updated = modify(arr[idx], rest, f) else { return nil }
            arr[idx] = updated
            return arr
        }
        return nil
    }

    static func set(_ node: Any, _ path: ArraySlice<Any>, _ value: Any) -> Any? {
        modify(node, path) { _ in value }
    }

    static func isTrue(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? false }

    static func xml(_ v: Any) -> String {
        let wrapper: [String: Any] = ["v": v]
        guard let d = try? PropertyListSerialization.data(fromPropertyList: wrapper, format: .xml, options: 0),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}

/// An in-memory OpenCore config.plist that can be edited (with undo/redo) and saved back.
/// Note: plist comments and key order are not preserved (OpenCore doesn't care).
@MainActor
final class ConfigDocument: ObservableObject {
    @Published private(set) var root: [String: Any]
    @Published private(set) var isDirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    let url: URL
    private(set) var saved: [String: Any]
    private var undoStack: [[String: Any]] = []
    private var redoStack: [[String: Any]] = []

    init(url: URL, root: [String: Any]) {
        self.url = url
        self.root = root
        self.saved = root
    }

    static func load(_ url: URL) throws -> ConfigDocument {
        ConfigDocument(url: url, root: try ConfigIO.readDict(url))
    }

    func value(_ path: [Any]) -> Any? { PlistTree.get(root, path) }
    func bool(_ path: [Any]) -> Bool { PlistTree.isTrue(value(path)) }
    func string(_ path: [Any]) -> String? { value(path) as? String }

    private func refreshFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        isDirty = !(root as NSDictionary).isEqual(to: saved)
    }

    private func commit(_ new: [String: Any]) {
        undoStack.append(root)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        root = new
        refreshFlags()
    }

    func set(_ path: [Any], _ newValue: Any) {
        mutate(path) { _ in newValue }
    }

    /// Applies a change at `path` (return nil from `f` to delete). Undoable.
    func mutate(_ path: [Any], _ f: (Any?) -> Any?) {
        if let n = PlistTree.modify(root, ArraySlice(path), f) as? [String: Any] { commit(n) }
    }

    func replaceRoot(_ new: [String: Any]) { commit(new) }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(root)
        root = prev
        refreshFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(root)
        root = next
        refreshFlags()
    }

    func diffFromSaved() -> [DiffEntry] { PlistDiff.diff(saved, root) }

    func serialized() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    /// Saves to disk (backing up the old file first). Returns an error message or nil.
    func save(backup: Bool = true) async -> String? {
        do {
            if backup { FileOps.backupFile(url) }
            let data = try serialized()
            if let err = await FileOps.write(data, to: url) { return err }
            saved = root
            refreshFlags()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Convenience edits

    func addKernelKext(bundlePath: String, executablePath: String, comment: String, afterBundle: String? = nil) {
        var add = (value(["Kernel", "Add"]) as? [Any]) ?? []
        if add.contains(where: { (($0 as? [String: Any])?["BundlePath"] as? String) == bundlePath }) { return }
        let entry: [String: Any] = [
            "Arch": "Any", "BundlePath": bundlePath, "Comment": comment, "Enabled": true,
            "ExecutablePath": executablePath, "MaxKernel": "", "MinKernel": "",
            "PlistPath": "Contents/Info.plist"
        ]
        if let after = afterBundle,
           let i = add.firstIndex(where: { (($0 as? [String: Any])?["BundlePath"] as? String) == after }) {
            add.insert(entry, at: i + 1)
        } else {
            add.append(entry)
        }
        set(["Kernel", "Add"], add)
    }

    func mergeDeviceProperties(devicePath: String, props: [String: Any]) {
        var add = (value(["DeviceProperties", "Add"]) as? [String: Any]) ?? [:]
        var entry = (add[devicePath] as? [String: Any]) ?? [:]
        for (k, v) in props { entry[k] = v }
        add[devicePath] = entry
        set(["DeviceProperties", "Add"], add)
    }
}

// MARK: - Diff

struct DiffEntry: Identifiable {
    enum Kind: String { case added = "Added", removed = "Removed", changed = "Changed" }
    let id = UUID()
    let kind: Kind
    /// Path to the node (or, when `appendToArray` is true, to the array it should be appended to).
    let path: [Any]
    let appendToArray: Bool
    let display: String
    let oldValue: Any?
    let newValue: Any?
    var oldText: String { oldValue.map { PlistTree.describe($0) } ?? "" }
    var newText: String { newValue.map { PlistTree.describe($0) } ?? "" }
}

enum PlistDiff {
    static let identityKeys = ["BundlePath", "Path", "Name", "Identifier", "Comment"]

    /// Differences needed to turn `old` into `new`.
    static func diff(_ old: Any, _ new: Any) -> [DiffEntry] {
        var out: [DiffEntry] = []
        walk(old, new, path: [], name: [], out: &out)
        return out
    }

    private static func commonKey(_ a: [Any], _ b: [Any]) -> String? {
        guard !a.isEmpty || !b.isEmpty else { return nil }
        guard a.allSatisfy({ $0 is [String: Any] }), b.allSatisfy({ $0 is [String: Any] }) else { return nil }
        for k in identityKeys {
            let va = a.compactMap { ($0 as? [String: Any])?[k] as? String }
            let vb = b.compactMap { ($0 as? [String: Any])?[k] as? String }
            if va.count == a.count, vb.count == b.count, Set(va).count == va.count, Set(vb).count == vb.count { return k }
        }
        return nil
    }

    private static func walk(_ a: Any, _ b: Any, path: [Any], name: [String], out: inout [DiffEntry]) {
        if out.count > 3000 { return }
        if let da = a as? [String: Any], let db = b as? [String: Any] {
            for k in Set(da.keys).union(db.keys).sorted() {
                let p = path + [k]
                let n = name + [k]
                switch (da[k], db[k]) {
                case (let x?, let y?):
                    walk(x, y, path: p, name: n, out: &out)
                case (nil, let y?):
                    out.append(DiffEntry(kind: .added, path: p, appendToArray: false, display: n.joined(separator: " ▸ "), oldValue: nil, newValue: y))
                case (let x?, nil):
                    out.append(DiffEntry(kind: .removed, path: p, appendToArray: false, display: n.joined(separator: " ▸ "), oldValue: x, newValue: nil))
                default:
                    break
                }
            }
            return
        }
        if let xa = a as? [Any], let xb = b as? [Any] {
            if let key = commonKey(xa, xb) {
                func id(_ e: Any) -> String { ((e as? [String: Any])?[key] as? String) ?? "" }
                let idsB = Dictionary(uniqueKeysWithValues: xb.map { (id($0), $0) })
                let idsA = Set(xa.map { id($0) })
                for (i, e) in xa.enumerated() {
                    let n = name + ["[\(id(e))]"]
                    if let other = idsB[id(e)] {
                        walk(e, other, path: path + [i], name: n, out: &out)
                    } else {
                        out.append(DiffEntry(kind: .removed, path: path + [i], appendToArray: false, display: n.joined(separator: " ▸ "), oldValue: e, newValue: nil))
                    }
                }
                for e in xb where !idsA.contains(id(e)) {
                    out.append(DiffEntry(kind: .added, path: path, appendToArray: true,
                                         display: (name + ["[\(id(e))]"]).joined(separator: " ▸ "), oldValue: nil, newValue: e))
                }
            } else {
                for i in 0..<min(xa.count, xb.count) {
                    walk(xa[i], xb[i], path: path + [i], name: name + ["[\(i)]"], out: &out)
                }
                if xb.count > xa.count {
                    for i in xa.count..<xb.count {
                        out.append(DiffEntry(kind: .added, path: path, appendToArray: true,
                                             display: (name + ["[\(i)]"]).joined(separator: " ▸ "), oldValue: nil, newValue: xb[i]))
                    }
                } else if xa.count > xb.count {
                    for i in xb.count..<xa.count {
                        out.append(DiffEntry(kind: .removed, path: path + [i], appendToArray: false,
                                             display: (name + ["[\(i)]"]).joined(separator: " ▸ "), oldValue: xa[i], newValue: nil))
                    }
                }
            }
            return
        }
        if PlistTree.tag(a) != PlistTree.tag(b) {
            out.append(DiffEntry(kind: .changed, path: path, appendToArray: false, display: name.joined(separator: " ▸ "), oldValue: a, newValue: b))
        }
    }

    /// Applies selected entries from a diff (old -> new) to `root`. Removals are applied only if `applyRemovals`.
    static func apply(_ entries: [DiffEntry], to root: [String: Any], applyRemovals: Bool = false) -> [String: Any] {
        var cur: Any = root
        // Appends first, in order; then changes; removals last, highest array index first.
        for e in entries where e.kind == .added {
            guard let v = e.newValue else { continue }
            if e.appendToArray {
                if let r = PlistTree.modify(cur, ArraySlice(e.path), { existing in ((existing as? [Any]) ?? []) + [v] }) { cur = r }
            } else if let r = PlistTree.set(cur, ArraySlice(e.path), v) {
                cur = r
            }
        }
        for e in entries where e.kind == .changed {
            guard let v = e.newValue else { continue }
            if let r = PlistTree.set(cur, ArraySlice(e.path), v) { cur = r }
        }
        if applyRemovals {
            let rem = entries.filter { $0.kind == .removed }.sorted { lhs, rhs in
                (lhs.path.last as? Int ?? -1) > (rhs.path.last as? Int ?? -1)
            }
            for e in rem {
                if let r = PlistTree.modify(cur, ArraySlice(e.path), { _ in nil }) { cur = r }
            }
        }
        return (cur as? [String: Any]) ?? root
    }
}

// MARK: - Audit

struct AuditIssue: Identifiable {
    enum Severity: String { case error = "Error", warning = "Warning", info = "Info" }
    let id = UUID()
    let severity: Severity
    let message: String
}

enum ConfigAudit {
    /// Kexts that must load after another one (names without .kext).
    static let loadAfter: [String: [String]] = [
        "VirtualSMC": ["Lilu"], "WhateverGreen": ["Lilu"], "AppleALC": ["Lilu"],
        "RestrictEvents": ["Lilu"], "NVMeFix": ["Lilu"], "CPUFriend": ["Lilu"],
        "HibernationFixup": ["Lilu"], "AirportBrcmFixup": ["Lilu"], "BlueToolFixup": ["Lilu"],
        "NootedRed": ["Lilu"], "ForgedInvariant": ["Lilu"], "FeatureUnlock": ["Lilu"],
        "CryptexFixup": ["Lilu"], "ECEnabler": ["VirtualSMC"],
        "SMCProcessor": ["VirtualSMC"], "SMCSuperIO": ["VirtualSMC"], "SMCBatteryManager": ["VirtualSMC"],
        "SMCLightSensor": ["VirtualSMC"], "SMCDellSensors": ["VirtualSMC"],
        "VoodooI2CHID": ["VoodooI2C"], "BrcmPatchRAM3": ["BrcmFirmwareData"]
    ]

    static func run(config: [String: Any], oc: URL) -> [AuditIssue] {
        var issues: [AuditIssue] = []
        let fm = FileManager.default
        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: oc.appendingPathComponent(rel).path) }
        func add(_ s: AuditIssue.Severity, _ m: String) { issues.append(AuditIssue(severity: s, message: m)) }

        if !exists("OpenCore.efi") { add(.error, "EFI/OC/OpenCore.efi is missing.") }
        if !fm.fileExists(atPath: oc.deletingLastPathComponent().appendingPathComponent("BOOT/BOOTx64.efi").path) {
            add(.warning, "EFI/BOOT/BOOTx64.efi is missing — firmware may not find OpenCore.")
        }

        // Kernel > Add
        let kexts = (PlistTree.get(config, ["Kernel", "Add"]) as? [[String: Any]]) ?? []
        var order: [String: Int] = [:]
        var referenced = Set<String>()
        for (i, k) in kexts.enumerated() {
            guard let bundle = k["BundlePath"] as? String else { add(.error, "Kernel > Add #\(i) has no BundlePath."); continue }
            let top = bundle.split(separator: "/").first.map(String.init) ?? bundle
            referenced.insert(top)
            let enabled = PlistTree.isTrue(k["Enabled"])
            if enabled { order[top.replacingOccurrences(of: ".kext", with: "")] = i }
            guard enabled else { continue }
            if !exists("Kexts/\(bundle)") { add(.error, "Enabled kext not found on disk: Kexts/\(bundle)"); continue }
            if let exe = k["ExecutablePath"] as? String, !exe.isEmpty, !exists("Kexts/\(bundle)/\(exe)") {
                add(.error, "ExecutablePath missing: Kexts/\(bundle)/\(exe)")
            }
            if let pl = k["PlistPath"] as? String, !pl.isEmpty, !exists("Kexts/\(bundle)/\(pl)") {
                add(.error, "PlistPath missing: Kexts/\(bundle)/\(pl)")
            }
        }
        for (name, deps) in loadAfter {
            guard let me = order[name] else { continue }
            for dep in deps {
                if let d = order[dep] {
                    if d > me { add(.error, "\(name).kext is listed before \(dep).kext — \(dep) must load first.") }
                } else {
                    add(.warning, "\(name).kext is enabled but \(dep).kext is not enabled in Kernel > Add.")
                }
            }
        }
        for f in ((try? fm.contentsOfDirectory(atPath: oc.appendingPathComponent("Kexts").path)) ?? [])
        where f.hasSuffix(".kext") && !referenced.contains(f) {
            add(.info, "Kexts/\(f) is on disk but not listed in the config.")
        }

        // ACPI
        for (i, a) in ((PlistTree.get(config, ["ACPI", "Add"]) as? [[String: Any]]) ?? []).enumerated() {
            guard PlistTree.isTrue(a["Enabled"]), let p = a["Path"] as? String else { continue }
            if !exists("ACPI/\(p)") { add(.error, "ACPI > Add #\(i): ACPI/\(p) not found.") }
        }

        // UEFI Drivers (string array in old OC, dict array in new OC)
        var driverNames = Set<String>()
        var canopy = false
        for (i, d) in ((PlistTree.get(config, ["UEFI", "Drivers"]) as? [Any]) ?? []).enumerated() {
            var path: String?
            var enabled = true
            if let s = d as? String { path = s }
            else if let dd = d as? [String: Any] { path = dd["Path"] as? String; enabled = PlistTree.isTrue(dd["Enabled"]) }
            guard let p = path else { continue }
            driverNames.insert(p)
            if enabled {
                if !exists("Drivers/\(p)") { add(.error, "UEFI > Drivers #\(i): Drivers/\(p) not found.") }
                if p == "OpenCanopy.efi" { canopy = true }
            }
        }
        if canopy && !exists("Resources") { add(.error, "OpenCanopy.efi is enabled but EFI/OC/Resources is missing.") }
        for f in ((try? fm.contentsOfDirectory(atPath: oc.appendingPathComponent("Drivers").path)) ?? [])
        where f.hasSuffix(".efi") && !driverNames.contains(f) {
            add(.info, "Drivers/\(f) is on disk but not listed in the config.")
        }

        // Tools
        for (i, t) in ((PlistTree.get(config, ["Misc", "Tools"]) as? [[String: Any]]) ?? []).enumerated() {
            guard PlistTree.isTrue(t["Enabled"]), let p = t["Path"] as? String else { continue }
            if !exists("Tools/\(p)") { add(.error, "Misc > Tools #\(i): Tools/\(p) not found.") }
        }

        // A couple of well-known footguns
        let sn = PlistTree.get(config, ["PlatformInfo", "Generic", "SystemSerialNumber"]) as? String ?? ""
        if sn.isEmpty || sn == "W00000000001" { add(.warning, "PlatformInfo > Generic has no real serial — generate SMBIOS (needed for iMessage/FaceTime).") }
        if PlistTree.isTrue(PlistTree.get(config, ["Kernel", "Quirks", "XhciPortLimit"])) {
            add(.info, "XhciPortLimit is on. Once you have a USB map, turn it off.")
        }
        if issues.isEmpty { add(.info, "No problems found.") }
        return issues
    }
}

// MARK: - Migration against Sample.plist

struct ConfigChange: Identifiable {
    enum Kind: String { case added = "Added", converted = "Converted", obsolete = "Obsolete" }
    let id = UUID()
    let kind: Kind
    let path: String
    let detail: String
}

enum ConfigMigrator {
    /// Dictionaries whose keys are user-defined, so they are never compared with the sample.
    static let freeform: Set<String> = [
        "NVRAM/Add", "NVRAM/Delete", "NVRAM/LegacySchema",
        "DeviceProperties/Add", "DeviceProperties/Delete"
    ]
    /// Per-entry keys that must never be copied from the sample's example entry.
    static let neverCopy: Set<String> = [
        "Path", "BundlePath", "ExecutablePath", "PlistPath", "Comment", "Name",
        "Find", "Replace", "Mask", "ReplaceMask", "Base", "Identifier", "Address"
    ]

    static func migrate(user: [String: Any], sample: [String: Any], removeObsolete: Bool) -> (result: [String: Any], changes: [ConfigChange]) {
        var changes: [ConfigChange] = []
        let merged = merge(user, sample, path: "", removeObsolete: removeObsolete, changes: &changes)
        return ((merged as? [String: Any]) ?? user, changes)
    }

    private static func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : a + "/" + b }

    private static func merge(_ user: Any, _ sample: Any, path: String, removeObsolete: Bool, changes: inout [ConfigChange]) -> Any {
        if freeform.contains(path) { return user }

        if let u = user as? [String: Any], let s = sample as? [String: Any] {
            var out = u
            for (k, sv) in s where u[k] == nil {
                out[k] = sv
                changes.append(ConfigChange(kind: .added, path: join(path, k), detail: "New key from Sample.plist"))
            }
            for (k, uv) in u {
                if let sv = s[k] {
                    out[k] = merge(uv, sv, path: join(path, k), removeObsolete: removeObsolete, changes: &changes)
                } else if !k.hasPrefix("#") {
                    changes.append(ConfigChange(kind: .obsolete, path: join(path, k), detail: "Not present in Sample.plist"))
                    if removeObsolete { out.removeValue(forKey: k) }
                }
            }
            return out
        }

        if let u = user as? [Any], let s = sample as? [Any], let template = s.first as? [String: Any] {
            var out: [Any] = []
            for (i, elem) in u.enumerated() {
                if var d = elem as? [String: Any] {
                    for (k, tv) in template where d[k] == nil && !neverCopy.contains(k) {
                        d[k] = tv
                        changes.append(ConfigChange(kind: .added, path: "\(path)[\(i)]/\(k)", detail: "New per-entry key"))
                    }
                    out.append(d)
                } else if let str = elem as? String {
                    var d = template
                    for k in ["Path", "BundlePath"] where d[k] != nil { d[k] = str }
                    d["Enabled"] = true
                    if d["Comment"] != nil { d["Comment"] = "" }
                    out.append(d)
                    changes.append(ConfigChange(kind: .converted, path: "\(path)[\(i)]", detail: "\"\(str)\" converted from a plain string to a dictionary entry"))
                } else {
                    out.append(elem)
                }
            }
            return out
        }
        return user
    }
}
