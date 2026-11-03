import Foundation

/// One folder in `~/Library/Developer/CoreSimulator/Devices`.
///
/// A device folder holds the installed test apps and their data. That data does not
/// come back, so a device is safe to remove only when Xcode cannot start it.
public struct SimulatorDevice: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        /// Xcode can start the device. Removal deletes its apps and app data.
        case available
        /// The runtime of the device is not installed. Xcode cannot start it.
        case unavailable
        /// The device is not shut down.
        case running
        /// Moppo could not read the device details or its availability.
        case unknown
    }

    /// The runtime name from `device.plist`, such as `iOS 18.1`.
    public let runtime: String?
    public let availability: Availability

    public init(runtime: String?, availability: Availability) {
        self.runtime = runtime
        self.availability = availability
    }

    /// Only an unavailable device counts as safe.
    public var isSafeToRemove: Bool { availability == .unavailable }

    /// The device runs now, or Xcode can start it. Its apps and app data are still in use.
    /// Moppo does not classify a device with unknown availability.
    public var holdsAppData: Bool { availability == .available || availability == .running }

    /// The status text for the row and for the scan report.
    public var status: String {
        switch availability {
        case .available: "Removal deletes the apps and app data in this simulator"
        case .unavailable: "Runtime not installed"
        case .running: "Simulator is running"
        case .unknown: "Availability could not be checked"
        }
    }

    /// The identity that `device.plist` records for a device folder.
    struct Record: Decodable, Equatable {
        let udid: String
        let name: String
        let runtimeIdentifier: String

        enum CodingKeys: String, CodingKey {
            case udid = "UDID", name, runtimeIdentifier = "runtime"
        }

        /// Reads `device.plist`, or returns `nil` when the file is missing, too large, or
        /// names a different device.
        static func read(folder: URL) -> Record? {
            let url = folder.appendingPathComponent("device.plist")
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: url),
                  let record = try? PropertyListDecoder().decode(Record.self, from: data),
                  UUID(uuidString: record.udid) != nil,
                  record.udid.caseInsensitiveCompare(folder.lastPathComponent) == .orderedSame,
                  !record.name.isEmpty
            else { return nil }
            return record
        }

        /// `com.apple.CoreSimulator.SimRuntime.iOS-18-1` becomes `iOS 18.1`.
        var runtimeName: String {
            let prefix = "com.apple.CoreSimulator.SimRuntime."
            let parts = runtimeIdentifier.dropFirst(prefix.count).split(separator: "-")
            guard runtimeIdentifier.hasPrefix(prefix), let platform = parts.first, parts.count > 1,
                  parts.dropFirst().allSatisfy({ Int($0) != nil })
            else { return runtimeIdentifier }
            return (platform == "xrOS" ? "visionOS" : String(platform)) + " " + parts.dropFirst().joined(separator: ".")
        }
    }
}
