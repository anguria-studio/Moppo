import Foundation

/// Contains application and macOS versions without file paths or library contents.
struct SupportReport {
    static let email = "hello@anguria.studio"

    static func text(bundle: Bundle = .main, systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Unknown")
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "Unknown")
        let osVersion = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
        return String(localized: """
        Moppo support report
        App version: \(version) (\(build))
        macOS: \(osVersion)

        Steps to repeat:

        Expected result:

        Actual result:

        This report contains no file paths, photos, or removal logs.
        """, comment: "Support email template. Values are the app version, build number, and macOS version.")
    }

    static func emailURL(report: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: String(localized: "Moppo support request")),
            URLQueryItem(name: "body", value: report)
        ]
        return components.url
    }
}
