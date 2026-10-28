import Darwin
import Foundation

struct PrivateRecordDirectory {
    let url: URL

    func open(create: Bool) throws -> Int32 {
        if create {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw RecordStoreError.unavailable }
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RecordStoreError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(fd)
            throw RecordStoreError.unavailable
        }
        return fd
    }
}

/// One app or terminal client can change cleanup targets at a time. Process exit releases the lock.
public final class PlanExecutionLease: @unchecked Sendable {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Moppo/plan-execution")
    private let fd: Int32

    public init(directory: URL = defaultDirectory) throws {
        let descriptor = try PrivateRecordDirectory(url: directory).open(create: true)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PlanExecutionError.busy
        }
        fd = descriptor
    }

    deinit { flock(fd, LOCK_UN); close(fd) }
}
