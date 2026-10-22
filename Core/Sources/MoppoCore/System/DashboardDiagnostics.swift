import Foundation

/// Records Dashboard phases without enabling file or command diagnostics.
public enum DashboardDiagnostics {
    @TaskLocal public static var current: ScanDiagnostics.Context?

    public static func phase<T>(
        _ name: String, details: [String: String] = [:], work: () throws -> T
    ) rethrows -> T {
        let context = current
        let span = context?.begin(name, details: details)
        do {
            let result = try work()
            context?.end(span, outcome: Task.isCancelled ? "cancelled" : "completed")
            return result
        } catch {
            context?.end(span, outcome: error is CancellationError || Task.isCancelled ? "cancelled" : "failed",
                         details: errorDetails(error))
            throw error
        }
    }

    public static func phase<T>(
        _ name: String,
        details: [String: String] = [:],
        isolation: isolated (any Actor)? = #isolation,
        work: () async throws -> T
    ) async rethrows -> T {
        let context = current
        let span = context?.begin(name, details: details)
        do {
            let result = try await work()
            context?.end(span, outcome: Task.isCancelled ? "cancelled" : "completed")
            return result
        } catch {
            context?.end(span, outcome: error is CancellationError || Task.isCancelled ? "cancelled" : "failed",
                         details: errorDetails(error))
            throw error
        }
    }

    /// Uses fixed error names and numeric codes. Error text can contain private data.
    public static func errorDetails(_ error: any Error) -> [String: String] {
        if error is CancellationError { return ["error_kind": "cancelled"] }
        if let error = error as? ProcessError {
            switch error {
            case .executableMissing: return ["error_kind": "executable_missing"]
            case .timedOut: return ["error_kind": "process_timeout"]
            case .failed(_, let status, _):
                return ["error_kind": "process_failed", "error_code": "\(status)"]
            }
        }
        if error is DecodingError { return ["error_kind": "decoding"] }
        if error is EncodingError { return ["error_kind": "encoding"] }
        let error = error as NSError
        let kind: String
        switch error.domain {
        case NSCocoaErrorDomain: kind = "cocoa"
        case NSPOSIXErrorDomain: kind = "posix"
        case NSURLErrorDomain: kind = "url"
        default: return ["error_kind": "other"]
        }
        return ["error_kind": kind, "error_code": "\(error.code)"]
    }

    public static func breakdownDetails(_ breakdown: StorageBreakdown) -> [String: String] {
        [
            "capacity_bytes": "\(breakdown.capacityBytes)",
            "segment_total_bytes": "\(breakdown.segments.reduce(0) { $0 + $1.bytes })",
            "free_bytes": "\(breakdown.freeBytes)",
            "allocation_excess_bytes": "\(breakdown.allocationExcessBytes)",
            "consistent": "\(breakdown.isConsistent)",
            "unreadable_count": "\(breakdown.unreadableCount)"
        ]
    }

    public static func measurementDetails(_ measurement: StorageMeasurement) -> [String: String] {
        var details = breakdownDetails(measurement.breakdown)
        details["physical_used_bytes"] = "\(measurement.volume.usedBytes)"
        details["physical_free_bytes"] = "\(measurement.volume.freeBytes)"
        let allocated = measurement.rawSegments.filter {
            $0.key != .free && $0.key != .unmeasured
        }.values.reduce(0, +)
        details["allocated_category_bytes"] = "\(allocated)"
        for id in StorageSegmentID.allCases {
            details["raw_\(id.rawValue)_bytes"] = "\(measurement.rawSegments[id] ?? 0)"
        }
        return details
    }
}
