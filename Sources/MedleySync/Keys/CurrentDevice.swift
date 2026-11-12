import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension DeviceInfo {
    /// This device: its user-visible name, platform, hardware model and the app's version.
    @MainActor
    public static func current(bundle: Bundle = .main) -> DeviceInfo {
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        #if os(macOS)
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return DeviceInfo(name: clean(name, fallback: "Mac"), platform: .mac, model: sysctlString("hw.model") ?? "Mac", appVersion: version)
        #elseif canImport(UIKit)
        let env = ProcessInfo.processInfo.environment
        let model = env["SIMULATOR_MODEL_IDENTIFIER"] ?? machineIdentifier() ?? UIDevice.current.model
        return DeviceInfo(name: clean(UIDevice.current.name, fallback: "iPhone"), platform: .ios, model: model, appVersion: version)
        #else
        return DeviceInfo(name: "Device", platform: .ios, model: "unknown", appVersion: version)
        #endif
    }

    private static func clean(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(64))
    }

    #if os(macOS)
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    #endif

    private static func machineIdentifier() -> String? {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
    }
}
