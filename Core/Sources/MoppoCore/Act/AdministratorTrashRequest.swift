import Darwin
import Foundation

public enum AdministratorTrashError: Error, Sendable, Equatable {
    case cancelled
    case invalidRequest
}

/// A single reviewed sound library move. The helper never deletes content.
public struct AdministratorTrashRequest: Codable, Sendable {
    public let source: URL
    public let destination: URL
    public let identity: String
    let userID: uid_t
    let sourceParentIdentity: String
    let destinationParentIdentity: String
    let inventory: AppleSoundLibrary.Inventory?

    public static func canRestore(to url: URL) -> Bool { AppleSoundLibrary.systemContentPaths.contains(url.path) }

    public static func canRetry(_ inventory: AppleSoundLibrary.Inventory) -> Bool {
        let parent = inventory.url.deletingLastPathComponent()
        return inventory.permittedOwner == nil
            && AppleSoundLibrary.systemContentPaths.contains(inventory.url.path)
            && inventory.url.resolvingSymlinksInPath() == inventory.url
            && !FileManager.default.isWritableFile(atPath: parent.path)
    }

    public init(source: URL, destination: URL, identity: String,
                inventory: AppleSoundLibrary.Inventory? = nil) throws {
        self.source = source.standardizedFileURL
        self.destination = destination.standardizedFileURL
        self.identity = identity
        self.inventory = inventory
        userID = getuid()
        guard let sourceParent = FileIdentity.of(source.deletingLastPathComponent()),
              let destinationParent = FileIdentity.of(destination.deletingLastPathComponent()) else {
            throw AdministratorTrashError.invalidRequest
        }
        sourceParentIdentity = sourceParent
        destinationParentIdentity = destinationParent
    }

    public static func read(from path: String) throws -> Self {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AdministratorTrashError.invalidRequest }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 16 * 1024 * 1024,
              let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1), data.count <= 16 * 1024 * 1024 else {
            throw AdministratorTrashError.invalidRequest
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.userID == info.st_uid else { throw AdministratorTrashError.invalidRequest }
        return request
    }

    /// Checks the production scope again after macOS grants administrator approval.
    public func perform() async throws {
        guard userID != 0, let account = getpwuid(userID), let directory = account.pointee.pw_dir else {
            throw AdministratorTrashError.invalidRequest
        }
        let home = URL(fileURLWithPath: String(cString: directory)).resolvingSymlinksInPath()
        let trash = home.appendingPathComponent(".Trash")
        let content = inventory == nil ? destination : source
        guard Self.canRestore(to: content),
              (inventory == nil ? source : destination).deletingLastPathComponent() == trash else {
            throw AdministratorTrashError.invalidRequest
        }
        var info = stat()
        guard lstat(trash.path, &info) == 0, info.st_uid == userID,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw AdministratorTrashError.invalidRequest
        }
        if inventory != nil { try await validateInventory(using: AppleSoundLibrary(home: home)) }
        try moveWithoutReplacing()
    }

    func validateInventory(using library: AppleSoundLibrary) async throws {
        guard let inventory, inventory.url == source, inventory.permittedOwner == nil else {
            throw AdministratorTrashError.invalidRequest
        }
        let current = try await library.scan(context: ScanContext(), installedOwners: [])
        guard current.items.contains(where: { $0.soundLibrary == inventory }),
              inventory.isStillSafe(registeredOwners: AppleSoundLibrary.registeredOwners(inventory.ownerIdentifiers)) else {
            throw AdministratorTrashError.invalidRequest
        }
    }

    /// Opens each parent without following links and keeps both directory descriptors through the move.
    func moveWithoutReplacing() throws {
        guard source.isFileURL, destination.isFileURL,
              source.path == source.standardizedFileURL.path,
              destination.path == destination.standardizedFileURL.path,
              source != destination else { throw AdministratorTrashError.invalidRequest }
        let sourceFD = try Self.openDirectory(source.deletingLastPathComponent())
        defer { close(sourceFD) }
        let destinationFD = try Self.openDirectory(destination.deletingLastPathComponent())
        defer { close(destinationFD) }
        var sourceParent = stat()
        var destinationParent = stat()
        var item = stat()
        guard fstat(sourceFD, &sourceParent) == 0, fstat(destinationFD, &destinationParent) == 0,
              Self.identity(sourceParent) == sourceParentIdentity,
              Self.identity(destinationParent) == destinationParentIdentity,
              fstatat(sourceFD, source.lastPathComponent, &item, AT_SYMLINK_NOFOLLOW) == 0,
              item.st_mode & S_IFMT == S_IFDIR, Self.identity(item) == identity else {
            throw AdministratorTrashError.invalidRequest
        }
        // RENAME_EXCL refuses an occupied destination, including a dangling symbolic link.
        guard renameatx_np(sourceFD, source.lastPathComponent, destinationFD, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func identity(_ value: stat) -> String { "\(value.st_dev):\(value.st_ino)" }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AdministratorTrashError.invalidRequest }
        let physical = URL(fileURLWithPath: FileIdentity.physicalPath(url.path))
        for component in physical.pathComponents.dropFirst() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(descriptor)
            guard next >= 0 else { throw AdministratorTrashError.invalidRequest }
            descriptor = next
        }
        return descriptor
    }
}
