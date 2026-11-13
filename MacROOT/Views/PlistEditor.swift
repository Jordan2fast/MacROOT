import SwiftUI

/// A text field that only commits when you press Return (so typing doesn't create an undo step per key).
struct CommitField: View {
    let placeholder: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.callout, design: .monospaced))
            .onAppear { text = value }
            .onChange(of: value) { newValue in text = newValue }
            .onSubmit { if text != value { onCommit(text) } }
    }
}

enum PlistValueTools {
    static func defaultValue(_ kind: PlistTree.Kind) -> Any {
        switch kind {
        case .dict: return [String: Any]()
        case .array: return [Any]()
        case .string: return ""
        case .bool: return false
        case .int: return 0
        case .real: return 0.0
        case .data: return Data()
        case .date: return Date()
        case .other: return ""
        }
    }

    static func text(_ v: Any) -> String {
        switch PlistTree.kind(of: v) {
        case .string: return (v as? String) ?? ""
        case .int: return "\((v as? NSNumber)?.int64Value ?? 0)"
        case .real: return "\((v as? NSNumber)?.doubleValue ?? 0)"
        case .data: return Data(((v as? Data) ?? Data())).hex
        case .bool: return PlistTree.isTrue(v) ? "true" : "false"
        default: return PlistTree.describe(v)
        }
    }

    static func parseHex(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "0x", with: "")
        t = t.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        guard t.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var i = t.startIndex
        while i < t.endIndex {
            let j = t.index(i, offsetBy: 2)
            guard let b = UInt8(t[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Data(bytes)
    }

    /// Best-effort conversion used by "Change type".
    static func convert(_ v: Any, to kind: PlistTree.Kind) -> Any {
        let t = text(v)
        switch kind {
        case .string: return t
        case .bool: return ["true", "yes", "1"].contains(t.lowercased())
        case .int: return Int(t) ?? Int(Double(t) ?? 0)
        case .real: return Double(t) ?? 0.0
        case .data: return parseHex(t) ?? Data(t.utf8)
        default: return defaultValue(kind)
        }
    }

    static func commit(_ text: String, kind: PlistTree.Kind) -> Any? {
        switch kind {
        case .string: return text
        case .int: return Int(text.trimmed)
        case .real: return Double(text.trimmed)
        case .data: return parseHex(text)
        default: return nil
        }
    }
}

struct PlistNodeView: View {
    enum Editing: Identifiable {
        case addKey, rename
        var id: Int { self == .addKey ? 0 : 1 }
    }

    @ObservedObject var doc: ConfigDocument
    let path: [Any]
    let label: String
    let value: Any
    let filter: String

    @State private var editing: Editing?
    @State private var nameText = ""
    @State private var newKind: PlistTree.Kind = .string

    private var kind: PlistTree.Kind { PlistTree.kind(of: value) }
    private var parentPath: [Any] { Array(path.dropLast()) }
    private var isRoot: Bool { path.count < 2 }
    private var arrayIndex: Int? { path.last as? Int }
    private var dictKey: String? { path.last as? String }

    static func matches(_ v: Any, label: String, filter: String) -> Bool {
        if filter.isEmpty { return true }
        let f = filter.lowercased()
        if label.lowercased().contains(f) { return true }
        if let d = v as? [String: Any] { return d.contains { PlistNodeView.matches($0.value, label: $0.key, filter: filter) } }
        if let a = v as? [Any] { return a.contains { PlistNodeView.matches($0, label: "", filter: filter) } }
        return PlistValueTools.text(v).lowercased().contains(f)
    }

    private func childHint(_ e: Any) -> String {
        guard let d = e as? [String: Any] else { return "" }
        for k in PlistDiff.identityKeys { if let s = d[k] as? String, !s.isEmpty { return " " + s } }
        return ""
    }

    var body: some View {
        if PlistNodeView.matches(value, label: label, filter: filter) {
            if kind == .dict || kind == .array {
                if filter.isEmpty {
                    DisclosureGroup { children } label: { header }
                } else {
                    DisclosureGroup(isExpanded: .constant(true)) { children } label: { header }
                }
            } else {
                header
            }
        }
    }

    @ViewBuilder
    private var children: some View {
        if let d = value as? [String: Any] {
            ForEach(d.keys.sorted(), id: \.self) { k in
                PlistNodeView(doc: doc, path: path + [k], label: k, value: d[k] ?? "", filter: filter)
            }
        } else if let a = value as? [Any] {
            ForEach(Array(a.indices), id: \.self) { i in
                PlistNodeView(doc: doc, path: path + [i], label: "[\(i)]" + childHint(a[i]), value: a[i], filter: filter)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(.callout, design: .monospaced)).fontWeight(.medium).lineLimit(1)
            Pill(text: kind.rawValue.uppercased(), color: Color.secondary)
            Spacer(minLength: 8)
            scalarEditor
            menu
        }
        .popover(item: $editing) { mode in editPopover(mode) }
    }

    @ViewBuilder
    private var scalarEditor: some View {
        switch kind {
        case .bool:
            Toggle("", isOn: Binding(get: { PlistTree.isTrue(doc.value(path)) }, set: { doc.set(path, $0) })).labelsHidden()
        case .string, .int, .real, .data:
            CommitField(placeholder: "", value: PlistValueTools.text(value)) { text in
                if let v = PlistValueTools.commit(text, kind: kind) { doc.set(path, v) }
            }
            .frame(maxWidth: 340)
        case .dict, .array:
            Text(PlistTree.describe(value)).font(.caption).foregroundStyle(.secondary)
        default:
            Text(PlistTree.describe(value)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var menu: some View {
        Menu {
            if kind == .dict || kind == .array {
                Menu("Add") {
                    ForEach(PlistTree.Kind.allCases.filter { $0 != .other }, id: \.self) { k in
                        Button(k.rawValue) {
                            if kind == .dict { newKind = k; nameText = ""; editing = .addKey }
                            else { doc.mutate(path) { v in ((v as? [Any]) ?? []) + [PlistValueTools.defaultValue(k)] } }
                        }
                    }
                }
            }
            if !isRoot {
                Menu("Change type") {
                    ForEach(PlistTree.Kind.allCases.filter { $0 != .other }, id: \.self) { k in
                        Button(k.rawValue) { doc.set(path, PlistValueTools.convert(value, to: k)) }
                    }
                }
                if dictKey != nil { Button("Rename…") { nameText = dictKey ?? ""; editing = .rename } }
                Button("Duplicate") { duplicate() }
                if let i = arrayIndex {
                    Button("Move up") { move(i, -1) }.disabled(i == 0)
                    Button("Move down") { move(i, 1) }
                }
                Divider()
                Button("Delete", role: .destructive) { doc.mutate(path) { _ in nil } }
            }
            Divider()
            Button("Copy as XML") { Panels.copy(PlistTree.xml(value)) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
    }

    @ViewBuilder
    private func editPopover(_ mode: Editing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == .addKey ? "New \(newKind.rawValue.lowercased()) key" : "Rename key").font(.headline)
            TextField("Key name", text: $nameText).textFieldStyle(.roundedBorder).frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                Button(mode == .addKey ? "Add" : "Rename") { commitName(mode) }
                    .buttonStyle(.borderedProminent)
                    .disabled(nameText.trimmed.isEmpty)
            }
        }
        .padding(14)
    }

    private func commitName(_ mode: Editing) {
        let name = nameText.trimmed
        editing = nil
        if mode == .addKey {
            let k = newKind
            doc.mutate(path) { v in
                var d = (v as? [String: Any]) ?? [:]
                d[name] = PlistValueTools.defaultValue(k)
                return d
            }
        } else if let old = dictKey {
            doc.mutate(parentPath) { v in
                var d = (v as? [String: Any]) ?? [:]
                if let val = d.removeValue(forKey: old) { d[name] = val }
                return d
            }
        }
    }

    private func duplicate() {
        if let i = arrayIndex {
            doc.mutate(parentPath) { v in
                var a = (v as? [Any]) ?? []
                if a.indices.contains(i) { a.insert(a[i], at: i + 1) }
                return a
            }
        } else if let k = dictKey {
            doc.mutate(parentPath) { v in
                var d = (v as? [String: Any]) ?? [:]
                if let val = d[k] { d[k + " copy"] = val }
                return d
            }
        }
    }

    private func move(_ i: Int, _ delta: Int) {
        doc.mutate(parentPath) { v in
            var a = (v as? [Any]) ?? []
            let j = i + delta
            if a.indices.contains(i), a.indices.contains(j) { a.swapAt(i, j) }
            return a
        }
    }
}

/// Edits an array of dictionaries (Kernel > Add, ACPI > Add, UEFI > Drivers, Misc > Tools …).
struct EntryListEditor: View {
    @ObservedObject var doc: ConfigDocument
    @EnvironmentObject var state: AppState
    let title: String
    let path: [Any]
    let fields: [String]
    let template: [String: Any]?
    var showKextVersion = false

    var body: some View {
        let arr = (doc.value(path) as? [Any]) ?? []
        Card(title, subtitle: "\(arr.count) entries") {
            if arr.isEmpty { Text("Empty.").foregroundStyle(.secondary) }
            ForEach(Array(arr.enumerated()), id: \.offset) { i, e in row(i, e, count: arr.count) }
            HStack {
                if let t = template { Button("Add entry") { doc.mutate(path) { v in ((v as? [Any]) ?? []) + [t] } } }
                if showKextVersion {
                    Button("Add kext from file…") { Task { await addKext() } }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ i: Int, _ e: Any, count: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let d = e as? [String: Any] {
                Toggle("", isOn: Binding(get: { doc.bool(path + [i, "Enabled"]) }, set: { doc.set(path + [i, "Enabled"], $0) }))
                    .labelsHidden()
                    .opacity(d["Enabled"] == nil ? 0.3 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(fields, id: \.self) { f in
                        HStack {
                            Text(f).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                            CommitField(placeholder: f, value: (d[f] as? String) ?? "") { doc.set(path + [i, f], $0) }
                        }
                    }
                    if showKextVersion, let b = d["BundlePath"] as? String, let oc = state.ocFolder,
                       let v = KextInfo.version(of: oc.appendingPathComponent("Kexts/\(b)")) {
                        Text("On disk: v\(v)").font(.caption2).foregroundStyle(.secondary).padding(.leading, 118)
                    }
                }
            } else if let s = e as? String {
                Text(s).font(.system(.callout, design: .monospaced))
                Text("(old string-style entry. The Upgrade Assistant converts these.)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { swap(i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0).buttonStyle(.borderless)
            Button { swap(i, 1) } label: { Image(systemName: "arrow.down") }.disabled(i == count - 1).buttonStyle(.borderless)
            Button { doc.mutate(path + [i]) { _ in nil } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        Divider()
    }

    private func swap(_ i: Int, _ delta: Int) {
        doc.mutate(path) { v in
            var a = (v as? [Any]) ?? []
            let j = i + delta
            if a.indices.contains(i), a.indices.contains(j) { a.swapAt(i, j) }
            return a
        }
    }

    private func addKext() async {
        guard let u = Panels.pick(message: "Choose a .kext to copy into EFI/OC/Kexts and add here") else { return }
        let msg = await state.installKextIntoEFI(u)
        state.addLog(msg)
    }
}
