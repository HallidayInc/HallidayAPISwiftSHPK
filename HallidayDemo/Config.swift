import Foundation

enum Config {
    static let hallidayKey = value("HALLIDAY_API_KEY")
    static let serverURL = value("SERVER_URL")

    private static func value(_ key: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? ""
    }
}
