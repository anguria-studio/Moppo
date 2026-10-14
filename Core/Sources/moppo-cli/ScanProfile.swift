import Foundation
import MoppoCore

extension CLI {
    /// Compares two runs without saving scan results or printing private paths.
    static func profileScan(arguments: [String]) async throws {
        var mode = "cleanup"
        var cancelAfter: Double?
        var skipDocker = false
        var remaining = arguments[...]
        if let first = remaining.first, ["cleanup", "dashboard", "concurrent"].contains(first) {
            mode = first
            remaining = remaining.dropFirst()
        }
        while let option = remaining.first {
            remaining = remaining.dropFirst()
            switch option {
            case "--skip-docker": skipDocker = true
            case "--cancel-after":
                guard let value = remaining.first, let seconds = Double(value),
                      seconds.isFinite, seconds > 0, seconds <= 3600 else {
                    throw CLIError.usage("--cancel-after needs seconds greater than zero and at most 3600")
                }
                cancelAfter = seconds
                remaining = remaining.dropFirst()
            default: throw CLIError.usage("Unknown profile-scan option: \(option)")
            }
        }

        let volume = try await DiskInfoService().volumeInfo()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var outputs: [ScanProfileOutput] = []
        for run in 1...2 {
            let cleanup = ScanProfileRecorder()
            let dashboard = ScanProfileRecorder()
            let selectedMode = mode
            let enabled = Set(CategoryID.allCases.filter { !skipDocker || $0 != .docker })
            let task = Task {
                await withTaskGroup(of: ScanProfileRecorder.Report.self) { group in
                    if selectedMode != "dashboard" {
                        group.addTask {
                            do {
                                var context = await scanContext()
                                try Task.checkCancellation()
                                context.measurer.onMeasurement = { cleanup.record($0, $1, $2) }
                                let result = try await ScanCoordinator.standard().scan(
                                    enabled: enabled,
                                    context: context,
                                    onProgress: { cleanup.recordProgress($0.percent) },
                                    onCategory: { cleanup.recordCategory($0) },
                                    onCategoryTiming: { cleanup.recordTiming($0, $1) }
                                )
                                return cleanup.report(operation: "cleanup", outcome: "completed", bytes: result.totalBytes)
                            } catch is CancellationError {
                                return cleanup.report(operation: "cleanup", outcome: "cancelled")
                            } catch {
                                return cleanup.report(operation: "cleanup", outcome: "failed")
                            }
                        }
                    }
                    if selectedMode != "cleanup" {
                        group.addTask {
                            do {
                                let measurer = AllocatedSizeMeasurer(onMeasurement: { dashboard.record($0, $1, $2) })
                                let result = try await StorageBreakdownService(measurer: measurer).measure(
                                    progress: { dashboard.recordProgress(Int($0 * 100)) }
                                )
                                return dashboard.report(
                                    operation: "dashboard", outcome: "completed", bytes: result.breakdown.usedBytes
                                )
                            } catch is CancellationError {
                                return dashboard.report(operation: "dashboard", outcome: "cancelled")
                            } catch {
                                return dashboard.report(operation: "dashboard", outcome: "failed")
                            }
                        }
                    }
                    var reports: [ScanProfileRecorder.Report] = []
                    for await report in group { reports.append(report) }
                    return reports.sorted { $0.operation < $1.operation }
                }
            }
            let cancellation = Task {
                guard let cancelAfter else { return }
                do { try await Task.sleep(for: .seconds(cancelAfter)) }
                catch { return }
                cleanup.recordCancellation()
                dashboard.recordCancellation()
                task.cancel()
            }
            let reports = await task.value
            cancellation.cancel()
            let output = ScanProfileOutput(
                run: run, mode: mode, capacityBytes: volume.capacityBytes,
                usedBytes: volume.usedBytes, skipDocker: skipDocker, operations: reports
            )
            outputs.append(output)
        }
        print(String(decoding: try encoder.encode(outputs), as: UTF8.self))
    }
}

private struct ScanProfileOutput: Encodable {
    let run: Int
    let mode: String
    let capacityBytes: Int64
    let usedBytes: Int64
    let skipDocker: Bool
    let operations: [ScanProfileRecorder.Report]
}

private final class ScanProfileRecorder: @unchecked Sendable {
    struct Progress: Encodable {
        let percent: Int
        let seconds: Double
    }

    struct Category: Encodable {
        let availability: String
        let entries: Int
        let unreadableCount: Int
    }

    struct Report: Encodable, Sendable {
        let operation: String
        let outcome: String
        let wallSeconds: Double
        let cancellationSeconds: Double?
        let bytes: Int64?
        let measurementCalls: Int
        let measuredFileVisits: Int
        let unreadableVisits: Int
        let repeatedRoots: Int
        let overlappingRootPairs: Int
        let measurementSecondsByLocation: [String: Double]
        let categorySeconds: [String: Double]
        let categories: [String: Category]
        let longestProgressGapSeconds: Double
        let progress: [Progress]
    }

    private let started = ContinuousClock.now
    private let lock = NSLock()
    private var cancelledAt: ContinuousClock.Instant?
    private var roots: [String: Int] = [:]
    private var fileVisits = 0
    private var unreadableVisits = 0
    private var locationSeconds: [String: Double] = [:]
    private var categorySeconds: [String: Double] = [:]
    private var categories: [String: Category] = [:]
    private var progress: [Progress] = []

    func record(_ url: URL, _ duration: Duration, _ measurement: SizeMeasurement) {
        let path = url.standardizedFileURL.path
        let location = Self.location(of: path)
        lock.lock()
        defer { lock.unlock() }
        roots[path, default: 0] += 1
        fileVisits += measurement.fileCount
        unreadableVisits += measurement.unreadableCount
        locationSeconds[location, default: 0] += Self.seconds(duration)
    }

    func recordTiming(_ category: CategoryID, _ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        categorySeconds[category.rawValue] = Self.seconds(duration)
    }

    func recordCategory(_ category: ScanCategoryResult) {
        lock.lock()
        defer { lock.unlock() }
        let availability = switch category.availability {
        case .available: "available"
        case .empty: "empty"
        case .unavailable: "unavailable"
        }
        categories[category.categoryID.rawValue] = Category(
            availability: availability, entries: category.entries.count, unreadableCount: category.unreadableCount
        )
    }

    func recordProgress(_ percent: Int) {
        lock.lock()
        defer { lock.unlock() }
        progress.append(Progress(percent: percent, seconds: Self.seconds(started.duration(to: .now))))
    }

    func recordCancellation() {
        lock.lock()
        defer { lock.unlock() }
        cancelledAt = .now
    }

    func report(operation: String, outcome: String, bytes: Int64? = nil) -> Report {
        let finished = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        let paths = roots.keys.sorted()
        let overlapCount = paths.enumerated().reduce(0) { count, item in
            count + paths.dropFirst(item.offset + 1).filter { $0.hasPrefix(item.element + "/") }.count
        }
        let elapsed = Self.seconds(started.duration(to: finished))
        let times = [0] + progress.map(\.seconds) + [elapsed]
        let gap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
        return Report(
            operation: operation, outcome: outcome, wallSeconds: elapsed,
            cancellationSeconds: outcome == "cancelled"
                ? cancelledAt.map { Self.seconds($0.duration(to: finished)) } : nil, bytes: bytes,
            measurementCalls: roots.values.reduce(0, +), measuredFileVisits: fileVisits,
            unreadableVisits: unreadableVisits, repeatedRoots: roots.values.filter { $0 > 1 }.count,
            overlappingRootPairs: overlapCount, measurementSecondsByLocation: locationSeconds,
            categorySeconds: categorySeconds, categories: categories,
            longestProgressGapSeconds: gap, progress: progress
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Use fixed location names so the report excludes account and file names.
    private static func location(of path: String) -> String {
        let home = NSHomeDirectory()
        for root in ["Library/Caches", "Library/Application Support", "Library/Containers", "Library/Group Containers",
                     "Library/Developer", "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies"] {
            let full = home + "/" + root
            if path == full || path.hasPrefix(full + "/") { return "Home/" + root }
        }
        if path == home { return "Home" }
        if path.hasPrefix(home + "/") { return "Other home folders" }
        for root in ["/Applications", "/System/Volumes/Data/System", "/Library", "/private", "/opt", "/usr/local", "/Users/Shared"] {
            if path == root || path.hasPrefix(root + "/") { return root }
        }
        return "Other system folders"
    }
}
