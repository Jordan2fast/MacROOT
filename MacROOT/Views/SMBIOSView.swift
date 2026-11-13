import SwiftUI

struct SMBIOSView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        PageView(title: "SMBIOS", subtitle: "Generate PlatformInfo values for iMessage, FaceTime and the App Store") {
            if let doc = state.config {
                SMBIOSEditor(doc: doc)
            } else {
                Card("No config loaded") {
                    Text("Load a config.plist first so the values can be written into PlatformInfo ▸ Generic.")
                        .foregroundStyle(.secondary)
                    Button("Load from selected EFI") { Task { await state.loadConfigFromEFI() } }
                }
            }
        }
    }
}

struct SMBIOSEditor: View {
    @ObservedObject var doc: ConfigDocument
    @EnvironmentObject var state: AppState
    @State private var model = "iMac20,1"
    @State private var serial = ""
    @State private var mlb = ""
    @State private var uuid = ""
    @State private var rom = ""
    @State private var working = false
    @State private var confirm = false
    @State private var message = ""

    var body: some View {
        Card("Current values in config.plist") {
            LabeledContent("Model", value: doc.string(["PlatformInfo", "Generic", "SystemProductName"]) ?? "—")
            LabeledContent("Serial", value: doc.string(["PlatformInfo", "Generic", "SystemSerialNumber"]) ?? "—")
            LabeledContent("MLB", value: doc.string(["PlatformInfo", "Generic", "MLB"]) ?? "—")
            LabeledContent("SystemUUID", value: doc.string(["PlatformInfo", "Generic", "SystemUUID"]) ?? "—")
            LabeledContent("ROM", value: (doc.value(["PlatformInfo", "Generic", "ROM"]) as? Data)?.hex ?? "—")
        }

        Card("Generate new values", subtitle: "Uses macserial from the latest OpenCore release. New serials should show as 'unregistered' on Apple's coverage page.") {
            Picker("Model", selection: $model) {
                ForEach(SMBIOSService.models) { m in Text("\(m.id) — \(m.note)").tag(m.id) }
            }
            HStack {
                Button { Task { await generate() } } label: { Label("Generate", systemImage: "wand.and.stars") }
                    .disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            Group {
                TextField("SystemSerialNumber", text: $serial)
                TextField("MLB (board serial)", text: $mlb)
                TextField("SystemUUID", text: $uuid)
                TextField("ROM (12 hex digits, usually your en0 MAC)", text: $rom)
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            HStack {
                Button("Write to config.plist…") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(serial.isEmpty || mlb.isEmpty || uuid.isEmpty || rom.count != 12)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .confirmationDialog("Replace the SMBIOS in config.plist?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Replace and save", role: .destructive) { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If this machine's current serial is already registered for iMessage/FaceTime and working, changing it means signing in again. The previous config.plist is backed up first.")
        }
    }

    private func generate() async {
        working = true
        defer { working = false }
        do {
            let pkg = try await OCPackageManager.latest()
            guard let r = await SMBIOSService.generate(model: model, macserial: pkg.macserial) else {
                message = "macserial produced no output."
                return
            }
            serial = r.serial
            mlb = r.mlb
            uuid = UUID().uuidString
            if let mac = await SMBIOSService.en0MAC() { rom = mac.hex } else { message = "Couldn't read en0's MAC — enter ROM by hand."; return }
            message = "Generated."
        } catch {
            message = error.localizedDescription
            state.addLog("SMBIOS generation failed: \(error.localizedDescription)", .error)
        }
    }

    private func apply() async {
        var bytes: [UInt8] = []
        var i = rom.startIndex
        while i < rom.endIndex {
            let j = rom.index(i, offsetBy: 2)
            guard let b = UInt8(rom[i..<j], radix: 16) else { message = "ROM must be hex."; return }
            bytes.append(b)
            i = j
        }
        doc.set(["PlatformInfo", "Generic", "SystemProductName"], model)
        doc.set(["PlatformInfo", "Generic", "SystemSerialNumber"], serial.trimmed)
        doc.set(["PlatformInfo", "Generic", "MLB"], mlb.trimmed)
        doc.set(["PlatformInfo", "Generic", "SystemUUID"], uuid.trimmed)
        doc.set(["PlatformInfo", "Generic", "ROM"], Data(bytes))
        if let err = await doc.save() {
            message = "Save failed: \(err)"
            state.addLog("Saving SMBIOS failed: \(err)", .error)
        } else {
            message = "Saved."
            state.addLog("SMBIOS written to \(doc.url.path) (model \(model)).")
        }
    }
}
