import Foundation

enum AppVersion {
    static func userAgent(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = normalizedVersion(infoDictionary: infoDictionary) ?? "unknown"
        return "LunaTV-iOS/\(version)"
    }

    static func profileLabel(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String {
        guard let version = normalizedVersion(infoDictionary: infoDictionary) else {
            return "iPhone 版（版本未知）"
        }
        let label = "iPhone 版 \(version)"
        guard let build = infoDictionary?["CFBundleVersion"] as? String,
              !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return label
        }
        return "\(label) · build \(build)"
    }

    private static func normalizedVersion(infoDictionary: [String: Any]?) -> String? {
        guard let value = infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        let version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
}
