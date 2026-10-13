import Foundation
import Testing

@Suite("Support reports")
struct SupportReportTests {
    @Test("Reports use an allowlist and email drafts preserve the reviewed text")
    func reportContents() throws {
        let folder = try TemporaryFolder(prefix: "support-report")
        let bundleURL = folder.url.appendingPathComponent("Report.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
            "PrivatePath": "/Users/private/Photos", "RemovalLog": "private removal data"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: bundleURL))
        let text = SupportReport.text(bundle: bundle, systemVersion: .init(majorVersion: 15, minorVersion: 2, patchVersion: 1))
        #expect(text.contains("0.2.0 (2)"))
        #expect(text.contains("15.2.1"))
        #expect(!text.contains(info["PrivatePath"]!))
        #expect(!text.contains(info["RemovalLog"]!))
        let url = try #require(SupportReport.emailURL(report: text))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        #expect(components.path == "hello@anguria.studio")
        #expect(components.queryItems?.first { $0.name == "body" }?.value == text)
    }
}
