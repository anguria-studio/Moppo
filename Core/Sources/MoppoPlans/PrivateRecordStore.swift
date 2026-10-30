import CryptoKit
import Darwin
import Foundation

protocol PrivateRecord: Codable, Sendable {
    static var currentSchemaVersion: Int { get }
    static var prefix: String { get }
    static var lifetime: TimeInterval { get }
    static var retainedCount: Int { get }
    static var maximumBytes: Int { get }
    var recordId: String { get }
    var recordDate: Date { get }
    var expiresAt: Date { get }
    var isValid: Bool { get }
}

public enum RecordStoreError: Error { case invalidId, unavailable, invalidReport, expired, incompatibleSchema, tooLarge, changed, writeFailed }

private struct RecordHeader: Decodable { let schemaVersion: Int }

struct PrivateRecordStore<Record: PrivateRecord>: Sendable {
    let directory: URL
    private static var maximumBytes: Int { Record.maximumBytes }
    typealias StoreError = RecordStoreError

    static func validId(_ id: String, prefix: String) -> Bool {
        id.hasPrefix(prefix) && UUID(uuidString: String(id.dropFirst(prefix.count))) != nil
            && id.count == prefix.count + 36 && !id.contains("/")
    }

    private func withDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T {
        let fd = try PrivateRecordDirectory(url: directory).open(create: create)
        defer { close(fd) }
        guard flock(fd, create ? LOCK_EX : LOCK_SH) == 0 else { throw StoreError.unavailable }
        defer { flock(fd, LOCK_UN) }
        return try body(fd)
    }

    /// Pruning keeps the records in `keeping` in addition to the retained count. Expired records are always removed.
    func save(_ report: Record, now: Date = Date(), keeping: Set<String> = []) throws {
        guard Self.validId(report.recordId, prefix: Record.prefix) else { throw StoreError.invalidId }
        let data = try ScanReport.encoder().encode(report)
        guard data.count <= Self.maximumBytes else { throw StoreError.tooLarge }
        try withDirectory(create: true) { directoryFD in
            let temporary = "." + UUID().uuidString
            let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw StoreError.unavailable }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            defer { close(fd); unlinkat(directoryFD, temporary, 0) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            // An identifier is immutable. Never replace an earlier record.
            guard linkat(directoryFD, temporary, directoryFD, report.recordId + ".json", 0) == 0
            else { throw StoreError.unavailable }
            unlinkat(directoryFD, temporary, 0)
            guard fsync(directoryFD) == 0 else { throw StoreError.writeFailed }
            try prune(directoryFD: directoryFD, now: now, keeping: keeping)
        }
    }

    func load(_ id: String, now: Date = Date()) throws -> Record {
        try loadWithRevision(id, now: now).record
    }

    /// The revision is the digest of the stored bytes. It equals `RecordDigest.of` for a record that this store saved.
    func loadWithRevision(_ id: String, now: Date = Date()) throws -> (record: Record, revision: String) {
        guard Self.validId(id, prefix: Record.prefix) else { throw StoreError.invalidId }
        return try withDirectory(create: false) { try read(id, directoryFD: $0, now: now) }
    }

    func invalidate(_ id: String, revision: String, now: Date) throws {
        guard Self.validId(id, prefix: Record.prefix) else { throw StoreError.invalidId }
        try withDirectory(create: true) { fd in
            guard try read(id, directoryFD: fd, now: now).revision == revision else { throw StoreError.changed }
            guard unlinkat(fd, id + ".json", 0) == 0 else { throw StoreError.unavailable }
        }
    }

    private func read(_ id: String, directoryFD: Int32, now: Date) throws -> (record: Record, revision: String) {
        let fd = openat(directoryFD, id + ".json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              info.st_size <= Self.maximumBytes else { throw StoreError.invalidReport }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw StoreError.tooLarge }
        guard let header = try? ScanReport.decoder().decode(RecordHeader.self, from: data) else { throw StoreError.invalidReport }
        guard header.schemaVersion == Record.currentSchemaVersion else { throw StoreError.incompatibleSchema }
        guard let report = try? ScanReport.decoder().decode(Record.self, from: data),
              report.recordId == id, report.recordDate <= now.addingTimeInterval(60),
              report.expiresAt <= report.recordDate.addingTimeInterval(Record.lifetime),
              report.isValid
        else { throw StoreError.invalidReport }
        guard report.expiresAt > now else { throw StoreError.expired }
        return (report, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func records(now: Date = Date()) throws -> [Record] {
        try withDirectory(create: true) { fd in
            try names(directoryFD: fd).compactMap { name in
                do { return try read(String(name.dropLast(5)), directoryFD: fd, now: now).record }
                catch StoreError.expired { return nil }
            }.sorted { $0.recordDate > $1.recordDate }
        }
    }

    private func names(directoryFD: Int32) throws -> [String] {
        let copy = dup(directoryFD)
        guard copy >= 0 else { throw StoreError.unavailable }
        guard let stream = fdopendir(copy) else { close(copy); throw StoreError.unavailable }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name.hasSuffix(".json"), Self.validId(String(name.dropLast(5)), prefix: Record.prefix) { names.append(name) }
        }
        return names
    }

    private func prune(directoryFD: Int32, now: Date, keeping: Set<String>) throws {
        var retained: [(String, Date)] = []
        for name in try names(directoryFD: directoryFD) {
            let id = String(name.dropLast(5))
            do {
                let report = try read(id, directoryFD: directoryFD, now: now).record
                if !keeping.contains(id) { retained.append((name, report.recordDate)) }
            } catch StoreError.expired {
                unlinkat(directoryFD, name, 0)
            } catch { continue }
        }
        for (name, _) in retained.sorted(by: { $0.1 > $1.1 }).dropFirst(Record.retainedCount) {
            unlinkat(directoryFD, name, 0)
        }
    }
}
