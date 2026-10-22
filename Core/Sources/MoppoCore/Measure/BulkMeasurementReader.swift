import Darwin
import Foundation

/// Reads directory names and allocation metadata in batches.
enum BulkMeasurementReader {
    private static let common = ATTR_CMN_RETURNED_ATTRS | UInt32(
        ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID
    )

    static func entries(of url: URL, cancelled: CancellationFlag) throws -> [MeasurementEntry] {
        if cancelled.isCancelled { throw CancellationError() }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = common
        attributes.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
        attributes.fileattr = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var entries: [MeasurementEntry] = []
        while true {
            if cancelled.isCancelled { throw CancellationError() }
            let count = buffer.withUnsafeMutableBytes {
                getattrlistbulk(descriptor, &attributes, $0.baseAddress, $0.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
            }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { return entries }
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                for _ in 0..<count {
                    guard offset <= raw.count - 4 else { throw POSIXError(.EIO) }
                    let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    guard length >= 56, length.isMultiple(of: 8), length <= raw.count - offset
                    else { throw POSIXError(.EIO) }
                    let record = UnsafeRawBufferPointer(rebasing: raw[offset..<offset + length])
                    entries.append(try entry(in: record, parent: url))
                    offset += length
                }
            }
        }
    }

    /// Packed attributes use four-byte alignment. Validate offsets before reading a record.
    static func entry(in record: UnsafeRawBufferPointer, parent: URL) throws -> MeasurementEntry {
        guard record.count >= 56 else { throw POSIXError(.EIO) }
        let returned = record.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
        let error = record.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
        let reference = record.loadUnaligned(fromByteOffset: 28, as: attrreference_t.self)
        let nameOffset = 28 + Int(reference.attr_dataoffset)
        let nameLength = Int(reference.attr_length)
        guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0,
              nameOffset >= 56, nameOffset <= record.count,
              nameLength > 1, nameLength <= record.count - nameOffset else { throw POSIXError(.EIO) }
        let nameBytes = record[nameOffset..<nameOffset + nameLength]
        guard nameBytes.last == 0, !nameBytes.dropLast().contains(0),
              let name = String(bytes: nameBytes.dropLast(), encoding: .utf8),
              name != ".", name != "..", !name.contains("/") else { throw POSIXError(.EILSEQ) }

        let device = record.loadUnaligned(fromByteOffset: 36, as: dev_t.self)
        let type = record.loadUnaligned(fromByteOffset: 40, as: fsobj_type_t.self)
        let flags = record.loadUnaligned(fromByteOffset: 44, as: UInt32.self)
        let inode = record.loadUnaligned(fromByteOffset: 48, as: UInt64.self)
        let isDirectory = type == VDIR.rawValue
        let isFile = type == VREG.rawValue
        // The kernel omits directory attributes for files and file attributes for directories.
        let fixedLength = isFile ? 68 : (isDirectory ? 60 : 56)
        guard record.count >= fixedLength, nameOffset >= fixedLength else { throw POSIXError(.EIO) }
        let mount = isDirectory ? record.loadUnaligned(fromByteOffset: 56, as: UInt32.self) : 0
        let links = isFile ? record.loadUnaligned(fromByteOffset: 56, as: UInt32.self) : 0
        let bytes = isFile ? record.loadUnaligned(fromByteOffset: 60, as: off_t.self) : 0

        // Mounts and firmlinks need target metadata to preserve the volume boundary.
        let requiredCommon = UInt32(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
        guard error == 0, returned.commonattr & requiredCommon == requiredCommon,
              flags & UInt32(SF_FIRMLINK) == 0,
              !isDirectory || (returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0
                              && mount & UInt32(DIR_MNTSTATUS_MNTPOINT) == 0),
              !isFile || (returned.fileattr & UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
                          == UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE) && bytes >= 0)
        else { return .bulk(parent: parent, name: name, isDirectory: isDirectory, metadata: nil) }

        return .bulk(parent: parent, name: name, isDirectory: isDirectory, metadata: MeasurementMetadata(
            isDirectory: isDirectory, isRegularFile: isFile, isSymbolicLink: type == VLNK.rawValue,
            linkCount: Int(links),
            fileResourceIdentifier: links > 1 ? "\(device):\(inode)" as NSString : nil,
            volumeIdentifier: NSNumber(value: device), allocatedBytes: isFile ? Int64(bytes) : nil,
            isCloudOnly: false, resourceValues: nil
        ))
    }
}
