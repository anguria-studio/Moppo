import Darwin
import Foundation

/// Supplies metadata to the shared measurement walker.
enum MeasurementReader: String, Sendable {
    case foundation
    case filesystem

    func metadata(at url: URL, keys: Set<URLResourceKey>) throws -> MeasurementMetadata {
        switch self {
        case .foundation:
            return MeasurementMetadata(try url.resourceValues(forKeys: keys))
        case .filesystem:
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError.current }
            let type = info.st_mode & S_IFMT
            let bytes = type == S_IFREG ? try allocatedBytes(at: url, identity: info) : nil
            return MeasurementMetadata(
                isDirectory: type == S_IFDIR, isRegularFile: type == S_IFREG,
                isSymbolicLink: type == S_IFLNK, linkCount: Int(info.st_nlink),
                fileResourceIdentifier: "\(info.st_dev):\(info.st_ino)" as NSString,
                volumeIdentifier: NSNumber(value: info.st_dev), allocatedBytes: bytes,
                isCloudOnly: false, resourceValues: nil
            )
        }
    }

    func contents(of url: URL, keys: [URLResourceKey], cancelled: CancellationFlag) throws -> [URL] {
        if cancelled.isCancelled { throw CancellationError() }
        if self == .foundation {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError.current }
        guard let directory = fdopendir(descriptor) else {
            let error = POSIXError.current
            close(descriptor)
            throw error
        }
        defer { closedir(directory) }
        var entries: [URL] = []
        while true {
            if cancelled.isCancelled { throw CancellationError() }
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw POSIXError.current }
                return entries
            }
            guard let name = withUnsafeBytes(of: entry.pointee.d_name, { bytes in
                String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
            }) else { throw POSIXError(.EILSEQ) }
            if name == "." || name == ".." { continue }
            // Supply the type hint to prevent URL construction from querying Foundation metadata.
            entries.append(url.appendingPathComponent(name, isDirectory: entry.pointee.d_type == DT_DIR))
        }
    }

    /// Reads allocated bytes across all forks. Logical size is not a fallback for cloud placeholders.
    private func allocatedBytes(at url: URL, identity: stat) throws -> Int64 {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_DEVID | ATTR_CMN_FILEID)
        list.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        // Attributes use four-byte alignment, even when a value occupies eight bytes.
        let deviceOffset = MemoryLayout<UInt32>.size
        let inodeOffset = deviceOffset + MemoryLayout<dev_t>.size
        let bytesOffset = inodeOffset + MemoryLayout<UInt64>.size
        let expected = bytesOffset + MemoryLayout<off_t>.size
        var buffer = [UInt8](repeating: 0, count: expected)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(url.path, &list, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW))
        }
        guard status == 0 else { throw POSIXError.current }
        return try buffer.withUnsafeBytes { raw in
            guard raw.loadUnaligned(as: UInt32.self) == expected else { throw POSIXError(.EIO) }
            guard raw.loadUnaligned(fromByteOffset: deviceOffset, as: dev_t.self) == identity.st_dev,
                  raw.loadUnaligned(fromByteOffset: inodeOffset, as: UInt64.self) == identity.st_ino
            else { throw POSIXError(.ESTALE) }
            let bytes = raw.loadUnaligned(fromByteOffset: bytesOffset, as: off_t.self)
            guard bytes >= 0 else { throw POSIXError(.EIO) }
            return Int64(bytes)
        }
    }
}

struct MeasurementMetadata {
    let isDirectory: Bool
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let linkCount: Int
    let fileResourceIdentifier: NSObject?
    let volumeIdentifier: NSObject?
    let allocatedBytes: Int64?
    let isCloudOnly: Bool
    let resourceValues: URLResourceValues?
}

extension MeasurementMetadata {
    init(_ values: URLResourceValues) {
        self.init(
            isDirectory: values.isDirectory == true, isRegularFile: values.isRegularFile == true,
            isSymbolicLink: values.isSymbolicLink == true, linkCount: values.linkCount ?? 1,
            fileResourceIdentifier: values.fileResourceIdentifier as? NSObject,
            volumeIdentifier: values.volumeIdentifier as? NSObject,
            allocatedBytes: AllocatedSizeMeasurer.allocatedSize(of: values),
            isCloudOnly: AllocatedSizeMeasurer.isCloudOnly(values),
            resourceValues: values
        )
    }
}

private extension POSIXError {
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
