import CoreServices
import Foundation
import Security

/// Code-signing evidence for app group containers.
///
/// An app group is a `com.apple.security.application-groups` entitlement. Several
/// applications from one developer can claim the same group, so a group container
/// is exclusive only when no other application claims it. A signature that Moppo
/// cannot read, or an inventory that Moppo cannot complete, is not evidence.
/// Then the container stays on disk.
struct ApplicationGroupClaims: Sendable {
    static let entitlementKey = "com.apple.security.application-groups"

    /// Gives the Launch Services locations of an application identifier.
    let registeredApplications: @Sendable (String) -> [URL]

    /// Uses Launch Services. It finds applications outside the application roots.
    static let live = ApplicationGroupClaims { identifier in
        LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?
            .takeRetainedValue() as? [URL] ?? []
    }

    /// Uses the application roots only. Fixture tests must not read this Mac's applications.
    static let applicationRootsOnly = ApplicationGroupClaims { _ in [] }

    enum ReadError: Error, Equatable {
        case unreadableSignature(String)
        case malformedEntitlement(String)
    }

    /// The groups that the signature of one bundle or executable claims.
    ///
    /// Unsigned code has no entitlements, so it claims no group.
    /// The signature is read, not validated: the question is what it claims.
    static func signedGroups(of url: URL) throws -> Set<String> {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw ReadError.unreadableSignature(url.path)
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSRequirementInformation), &information
        ) == errSecSuccess, let information = information as? [String: Any]
        else { throw ReadError.unreadableSignature(url.path) }
        guard information[kSecCodeInfoIdentifier as String] != nil else { return [] }
        guard let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let value = entitlements[entitlementKey]
        else { return [] }
        guard let groups = value as? [String] else { throw ReadError.malformedEntitlement(url.path) }
        return Set(groups)
    }

    /// The groups that the application and each code item in it claim.
    ///
    /// Code items are nested `.app`, `.appex`, `.xpc`, and `.systemextension`
    /// bundles, and executable files in `MacOS`, `Helpers`, and `LaunchServices`
    /// folders. The walk does not follow symbolic links. It does not go into
    /// folders that cannot hold code that runs, such as an SDK or a localization.
    static func claimedGroups(
        in application: URL, checkCancellation: () throws -> Void
    ) throws -> Set<String> {
        let diagnostics = ScanDiagnostics.current
        let span = diagnostics?.begin("application_group_claims", path: application.path)
        defer { diagnostics?.end(span) }
        try checkCancellation()
        var result = Set<String>()
        var readExecutables = Set<String>()
        func readBundle(_ bundle: URL) throws {
            guard let executable = executable(of: bundle) else { return }
            readExecutables.insert(executable.path)
            result.formUnion(try signedGroups(of: bundle))
        }
        try readBundle(application)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isExecutableKey]
        var readError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: application, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, error in
                readError = error
                return false
            }
        ) else { throw ReadError.unreadableSignature(application.path) }
        for case let url as URL in enumerator {
            try checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if folderWithoutCode(url) {
                    enumerator.skipDescendants()
                } else if codeBundleExtensions.contains(url.pathExtension.lowercased()) {
                    try readBundle(url)
                }
            } else if values.isRegularFile == true, values.isExecutable == true,
                      helperFolders.contains(url.deletingLastPathComponent().lastPathComponent),
                      !readExecutables.contains(url.standardizedFileURL.path) {
                result.formUnion(try signedGroups(of: url))
            }
        }
        if let readError { throw readError }
        return result
    }

    /// Nil for a folder without an executable. Such a folder cannot run, so it
    /// cannot claim a group. Examples are the `.xpc` stubs in an SDK and a
    /// `Microsoft.NETCore.App` resource folder.
    static func executable(of bundle: URL) -> URL? {
        guard let executable = Bundle(url: bundle)?.executableURL?.standardizedFileURL,
              FileManager.default.fileExists(atPath: executable.path)
        else { return nil }
        return executable
    }

    static let codeBundleExtensions: Set<String> = ["app", "appex", "xpc", "systemextension"]
    static let helperFolders: Set<String> = ["MacOS", "Helpers", "LaunchServices"]

    /// SDK stubs, localizations, headers, and module interfaces.
    /// Xcode keeps most of its files in these folders.
    static func folderWithoutCode(_ url: URL) -> Bool {
        ["sdk", "lproj", "swiftmodule", "docc", "doccarchive"].contains(url.pathExtension.lowercased())
            || ["Headers", "PrivateHeaders"].contains(url.lastPathComponent)
    }

    /// The groups in `groups` that an application other than `selectedApplication` claims.
    ///
    /// Moppo reads every application in `applicationRoots`. It also reads each
    /// application that Launch Services finds for `identifiers` and for the names
    /// in `groups`. An application in the Trash is not installed.
    /// - Throws: When the inventory of an application root or a signature cannot be read.
    func groupsClaimedElsewhere(
        _ groups: Set<String>,
        selectedApplication: URL,
        applicationRoots: [URL],
        identifiers: Set<String>
    ) async throws -> Set<String> {
        guard !groups.isEmpty else { return [] }
        let selectedPath = selectedApplication.resolvingSymlinksInPath().standardizedFileURL.path
        var applications = try AppUninstallPlanner.installedApplications(
            in: applicationRoots, fileManager: .default,
            requireCompleteInventory: true, checkCancellation: Task.checkCancellation
        )
        for identifier in identifiers.union(groups.flatMap(Self.ownerIdentifiers)).sorted() {
            try Task.checkCancellation()
            applications += registeredApplications(identifier).filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
        var paths: [String] = []
        for application in applications {
            let path = application.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != selectedPath, !path.hasPrefix(selectedPath + "/"),
                  !Self.isInTrash(path), !paths.contains(path)
            else { continue }
            paths.append(path)
        }
        // Xcode alone takes seconds, so the applications are read at the same time.
        return try await withThrowingTaskGroup(of: Set<String>.self) { group in
            var next = 0
            func submit() {
                guard next < paths.count else { return }
                let url = URL(fileURLWithPath: paths[next], isDirectory: true)
                next += 1
                group.addTask {
                    try Self.claimedGroups(in: url, checkCancellation: Task.checkCancellation)
                        .intersection(groups)
                }
            }
            for _ in 0..<min(ProcessInfo.processInfo.activeProcessorCount, paths.count) { submit() }
            var claimed = Set<String>()
            for try await groupsOfOneApplication in group {
                claimed.formUnion(groupsOfOneApplication)
                if claimed == groups {
                    group.cancelAll()
                    return claimed
                }
                submit()
            }
            return claimed
        }
    }

    /// Application identifiers that a group name can contain.
    /// `group.com.vendor.app.shared` gives `com.vendor.app.shared` and `com.vendor.app`.
    static func ownerIdentifiers(of group: String) -> [String] {
        let name = group.hasPrefix("group.") ? String(group.dropFirst("group.".count)) : group
        var parts = name.split(separator: ".").map(String.init)
        var result: [String] = []
        while parts.count >= 3 {
            result.append(parts.joined(separator: "."))
            parts.removeLast()
        }
        return result
    }

    static func isInTrash(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}
