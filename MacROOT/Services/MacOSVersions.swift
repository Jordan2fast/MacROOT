import Foundation

enum AppInfo {
    static let name = "MacROOT"
    static let version = "1.2.0"
    static var build: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev" }
}

/// A macOS version such as 13.5 or 26.7.5, with its Darwin (kernel) major number.
struct MacOSVersion: Hashable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ text: String) {
        let p = Version.parts(text)
        guard let m = p.first, m >= 10, m < 100 else { return nil }
        major = m
        minor = p.count > 1 ? p[1] : 0
        patch = p.count > 2 ? p[2] : 0
    }

    var text: String { patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)" }

    /// Darwin major: 10.13 -> 17, 11 -> 20 ... 15 -> 24, 26 -> 25.
    var darwinMajor: Int {
        if major == 10 { return minor + 4 }
        if major <= 15 { return major + 9 }
        return major - 1
    }

    var name: String {
        switch (major, major == 10 ? minor : 0) {
        case (10, 13): return "High Sierra"
        case (10, 14): return "Mojave"
        case (10, 15): return "Catalina"
        case (11, _): return "Big Sur"
        case (12, _): return "Monterey"
        case (13, _): return "Ventura"
        case (14, _): return "Sonoma"
        case (15, _): return "Sequoia"
        case (26, _): return "Tahoe"
        case (27, _): return "Golden Gate"
        default: return "macOS \(major)"
        }
    }

    /// macOS 27 and later are Apple silicon only; there is nothing an x86_64 Hackintosh can boot.
    var supportsIntel: Bool { major <= 26 }
    var minKernel: String { "\(darwinMajor).0.0" }
    var maxKernel: String { "\(darwinMajor).99.99" }
    var display: String { "\(name) \(text)" }

    static func < (a: MacOSVersion, b: MacOSVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    /// Presets offered in pickers (major releases an Intel Hackintosh can run).
    static let presets: [MacOSVersion] = [
        MacOSVersion(major: 10, minor: 15), MacOSVersion(major: 11), MacOSVersion(major: 12),
        MacOSVersion(major: 13), MacOSVersion(major: 14), MacOSVersion(major: 15), MacOSVersion(major: 26)
    ]
}

/// Built-in table of the last macOS that officially supports a given Intel SMBIOS model.
/// Hand-maintained from Apple's compatibility lists; it is deliberately small. Unknown models are reported as unknown.
enum MacModelSupport {
    enum Status {
        case supported
        case unsupported(lastSupported: Int)
        case unknown
    }

    static let lastSupported: [String: Int] = [
        "iMac19,1": 15, "iMac19,2": 15, "iMac20,1": 26, "iMac20,2": 26, "iMacPro1,1": 15, "MacPro7,1": 26,
        "MacBookPro16,1": 26, "MacBookPro16,2": 26, "MacBookPro16,3": 15, "MacBookPro16,4": 26,
        "MacBookPro15,1": 15, "MacBookPro15,2": 15, "MacBookPro15,3": 15, "MacBookPro15,4": 15,
        "MacBookPro14,1": 13, "MacBookPro14,2": 13, "MacBookPro14,3": 13,
        "MacBookPro13,1": 12, "MacBookPro13,2": 12, "MacBookPro13,3": 12,
        "MacBookAir9,1": 15, "MacBookAir8,1": 14, "MacBookAir8,2": 14,
        "Macmini8,1": 15, "Macmini7,1": 12,
        "iMac18,1": 13, "iMac18,2": 13, "iMac18,3": 13, "iMac17,1": 12, "iMac16,1": 12, "iMac16,2": 12, "iMac15,1": 12
    ]

    /// Intel models macOS 26 (Tahoe) supports.
    static let tahoeModels: [String] = ["MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,4", "iMac20,1", "iMac20,2", "MacPro7,1"]

    static func status(model: String, target: Int) -> Status {
        guard let last = lastSupported[model] else { return .unknown }
        return last >= target ? .supported : .unsupported(lastSupported: last)
    }

    /// A model of the same general kind that the target macOS supports (nil if the model is fine or unknown).
    static func suggestion(for model: String, target: Int) -> String? {
        guard case .unsupported = status(model: model, target: target) else { return nil }
        if model.hasPrefix("MacBook") { return "MacBookPro16,1" }
        if model.hasPrefix("MacPro") || model.hasPrefix("iMacPro") { return "MacPro7,1" }
        return "iMac20,1"
    }
}
