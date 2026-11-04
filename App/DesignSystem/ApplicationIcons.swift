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
    private static let identifiers = ToolIcons.bundleIdentifiers
    private static let paddedFallbacks = ToolIcons.paddedFallbacks

    static func icon(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: url.path as NSString)
        return icon
    }

    /// Returns an icon for each tool, so that no AI Tools row shows an empty square.
    static func icon(for tool: FileEntry.AITool) -> Icon {
        if let identifier = identifiers[tool],
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
           FileManager.default.fileExists(atPath: url.path) {
            return Icon(image: icon(for: url), includesPadding: true)
        }
        let key = "tool:\(tool.rawValue)" as NSString
        let image = cache.object(forKey: key) ?? fallbackImage(for: tool)
        // Keep the same image during animated row updates.
        cache.setObject(image, forKey: key)
        return Icon(image: image, includesPadding: paddedFallbacks.contains(tool))
    }

    private static func fallbackImage(for tool: FileEntry.AITool) -> NSImage {
        if tool != .chatGPT, let image = Bundle(for: BundleToken.self).image(forResource: tool.rawValue + "ToolIcon") {
            return image
        }
        // A tool without a bundled icon, such as GitHub Copilot CLI, uses a neutral symbol.
        let symbol = tool == .chatGPT ? "bubble.left.and.bubble.right" : "sparkles"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
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
