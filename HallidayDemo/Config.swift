import Foundation

enum Config {
    static let hallidayKey = value("HALLIDAY_API_KEY")
    static let serverURL = value("SERVER_URL")

    // The scheme's environment variables only reach the app when Xcode launches it, so they
    // are absent when the app is opened from the home screen. Info.plist carries the same
    // values, substituted from Signing.xcconfig at build time; the environment still wins so
    // a scheme can override them during development.
    private static func value(_ key: String) -> String {
        if let injected = ProcessInfo.processInfo.environment[key], !injected.isEmpty {
            return injected
        }
        let bundled = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        // An unset build setting leaves the placeholder behind rather than an empty string.
        return bundled.hasPrefix("$(") ? "" : bundled
    }
}
