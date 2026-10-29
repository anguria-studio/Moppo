import AppKit
import MoppoCore

/// Shares cached application icons across cleanup rows and uninstall cards.
@MainActor
enum ApplicationIcons {
    private final class BundleToken {}

    struct Icon {
        let image: NSImage
        let includesPadding: Bool
        var size: CGFloat { includesPadding ? 28 : 22 }
    }

    private static let cache = NSCache<NSString, NSImage>()
    private static let identifiers: [FileEntry.AITool: String] = [
        .chatGPT: "com.openai.codex",
        .claude: "com.anthropic.claudefordesktop",
        .cursor: "com.todesktop.230313mzl4w4u92",
        .grokBot: "com.anysphere.sand",
        .antigravity: "com.google.antigravity"
    ]

    static func icon(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: url.path as NSString)
        return icon
    }

    static func icon(for tool: FileEntry.AITool) -> Icon? {
        if let identifier = identifiers[tool],
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
           FileManager.default.fileExists(atPath: url.path) {
            return Icon(image: icon(for: url), includesPadding: true)
        }
        let key = "tool:\(tool.rawValue)" as NSString
        if let image = cache.object(forKey: key) {
            return Icon(image: image, includesPadding: tool == .codex)
        }
        let fallback = tool == .chatGPT
            ? NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
            : Bundle(for: BundleToken.self).image(forResource: tool.rawValue + "ToolIcon")
        guard let image = fallback else { return nil }
        // Keep the same image during animated row updates.
        cache.setObject(image, forKey: key)
        return Icon(image: image, includesPadding: tool == .codex)
    }

    static func icon(for identifier: String) -> Icon? {
        if let tool = identifiers.first(where: { $0.value == identifier })?.key {
            return icon(for: tool)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Icon(image: icon(for: url), includesPadding: true)
    }
}
