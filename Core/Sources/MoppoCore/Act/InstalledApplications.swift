import Foundation

/// An application the uninstaller would agree to review.
public struct InstalledApplication: Sendable, Identifiable, Equatable {
    public let url: URL
    public let name: String
    public let bundleIdentifier: String?

    public var id: String { url.path }
}

extension AppUninstallPlanner {
    /// Lists applications in all folders below the configured roots.
    /// Discovery stops at each application bundle and skips excluded paths and symbolic links.
    /// The list applies the same initial protection checks as the uninstall plan.
    /// The plan checks bundle contents and package ownership during review.
    /// Cancellation returns an empty list. Callers must discard cancelled results.
    public func installedApplications(
        context: ScanContext = ScanContext()
    ) -> [InstalledApplication] {
        let fm = FileManager.default
        var seen = Set<String>()
        var applications: [InstalledApplication] = []

        guard let discovered = try? Self.installedApplications(
            in: applicationRoots, fileManager: fm,
            excluding: context.isWithinExclusion,
            checkCancellation: { try Task.checkCancellation() }
        ) else { return [] }

        for url in discovered {
            guard !Task.isCancelled else { return [] }
            guard seen.insert(url.path).inserted,
                  url.resolvingSymlinksInPath().standardizedFileURL == url,
                  let bundle = Bundle(url: url),
                  !Self.isChromiumApplicationShim(bundle)
            else { continue }

            let identifier = Self.verifiedBundleIdentifier(bundle.bundleIdentifier)
            // Each listed application must support an uninstall review.
            guard uninstallScope(identifier: identifier, applicationURL: url) != .refused,
                  !context.isExcluded(url)
            else { continue }

            var displayName = url.deletingPathExtension().lastPathComponent
            if displayName.isEmpty { displayName = url.lastPathComponent }
            applications.append(InstalledApplication(
                url: url, name: displayName, bundleIdentifier: identifier
            ))
        }

        return applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
