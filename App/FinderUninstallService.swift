import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Receives one application from the Finder Services menu.
@MainActor
final class FinderUninstallServiceProvider: NSObject {
    @objc(reviewUninstall:userData:error:)
    func reviewUninstall(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.applicationBundle.identifier],
        ]
        let urls = pasteboard
            .readObjects(forClasses: [NSURL.self], options: options)?
            .compactMap { ($0 as? NSURL)?.absoluteURL } ?? []

        guard urls.count == 1, let applicationURL = urls.first else {
            error.pointee = "Select one application in Finder, then try again."
            return
        }
        guard applicationURL.isFileURL,
              applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        else {
            error.pointee = "Finder did not provide a valid application."
            return
        }

        MainWindowRequestCenter.uninstall.submit(applicationURL.standardizedFileURL)
    }
}
