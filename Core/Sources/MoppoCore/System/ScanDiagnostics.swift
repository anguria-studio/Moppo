import Foundation
import Darwin

/// Writes local scan diagnostics while work is active. No file contents or environment values are recorded.
public final class ScanDiagnostics: @unchecked Sendable {
    public struct Context: Sendable {
        fileprivate let log: ScanDiagnostics
        fileprivate var category: String?

        public func forCategory(_ category: String) -> Context { Context(log: log, category: category) }
        public func begin(_ operation: String, path: String? = nil, details: [String: String] = [:]) -> UUID {
            log.begin(operation, path: path, category: category, details: details)
        }
        public func end(_ id: UUID?, outcome: String = "completed", details: [String: String] = [:]) {
            if let id { log.end(id, outcome: outcome, details: details) }
        }
        public func update(_ id: UUID?, path: String? = nil, details: [String: String] = [:]) {
            if let id { log.update(id, path: path, details: details) }
        }
        public func record(_ event: String, details: [String: String] = [:]) {
            log.record(event, category: category, details: details)
        }
        public func progress(_ progress: ScanProgress) { log.progress(progress) }
    }

    @TaskLocal public static var current: Context?
    public var context: Context { Context(log: self) }
    public let fileURL: URL

    /// Shared resource counters for application logs and command-line profiles.
    public struct Resources: Encodable, Sendable {
        public let wallSeconds: Double
        public let userCPUSeconds: Double
        public let systemCPUSeconds: Double
        public let diskReadBytes: UInt64?
        public let diskWrittenBytes: UInt64?
        public let residentBytes: UInt64?
        public let physicalFootprintBytes: UInt64?
        public let threadCount: Int32?

        public static func capture() -> Self {
            var cpu = rusage()
            getrusage(RUSAGE_SELF, &cpu)
            var io = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &io) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2,
                    UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
            }
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let taskResult = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, taskSize)
            return Self(wallSeconds: 0,
                userCPUSeconds: Double(cpu.ru_utime.tv_sec) + Double(cpu.ru_utime.tv_usec) / 1e6,
                systemCPUSeconds: Double(cpu.ru_stime.tv_sec) + Double(cpu.ru_stime.tv_usec) / 1e6,
                diskReadBytes: result == 0 ? io.ri_diskio_bytesread : nil,
                diskWrittenBytes: result == 0 ? io.ri_diskio_byteswritten : nil,
                residentBytes: result == 0 ? io.ri_resident_size : nil,
                physicalFootprintBytes: result == 0 ? io.ri_phys_footprint : nil,
                threadCount: taskResult == taskSize ? task.pti_threadnum : nil)
        }

        public func difference(from previous: Self, wallSeconds: Double) -> Self {
            Self(wallSeconds: wallSeconds,
                userCPUSeconds: userCPUSeconds - previous.userCPUSeconds,
                systemCPUSeconds: systemCPUSeconds - previous.systemCPUSeconds,
                diskReadBytes: diskReadBytes.flatMap { value in previous.diskReadBytes.map { value &- $0 } },
                diskWrittenBytes: diskWrittenBytes.flatMap { value in previous.diskWrittenBytes.map { value &- $0 } },
                residentBytes: residentBytes, physicalFootprintBytes: physicalFootprintBytes, threadCount: threadCount)
        }

        public static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
    }

    private struct Activity: Encodable {
        let id: UUID
        let operation: String
        let category: String?
        var path: String?
        var details: [String: String]
        let startedSeconds: Double
    }

    private struct Event: Encodable, Sendable {
        let sequence: Int
        let timestamp: Date
        let elapsedSeconds: Double
        let event: String
        let category: String?
        let details: [String: String]
    }

    private let started = ContinuousClock.now
    private let baseline = Resources.capture()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "studio.anguria.Moppo.scan-diagnostics", qos: .utility)
    private let handle: FileHandle
    private let maximumDetailBytes: Int
    private var timer: DispatchSourceTimer?
    private var sequence = 0
    private var active: [UUID: Activity] = [:]
    private var lastProgress = 0
    private var lastProgressSeconds = 0.0
    private var closed = false
    private var detailBudgetReached = false
    private var omittedDetailEvents = 0
    // These fields are used only on the writer queue.
    private var detailBytes = 0
    private var writeFailed = false

    public init(directory: URL, metadata: [String: String] = [:],
                heartbeatInterval: Double = 1, maximumDetailBytes: Int = 128 * 1024 * 1024) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent("scan-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).jsonl")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        self.maximumDetailBytes = max(0, maximumDetailBytes)
        var details = metadata
        let process = ProcessInfo.processInfo
        details.merge([
            "format_version": "1", "pid": "\(getpid())", "macOS": process.operatingSystemVersionString,
            "processor_count": "\(process.processorCount)", "active_processors": "\(process.activeProcessorCount)",
            "physical_memory_bytes": "\(process.physicalMemory)", "machine_model": Self.machineModel,
            "detail_limit_bytes": "\(self.maximumDetailBytes)",
            "privacy": "Contains local paths, command arguments, and bounded standard error. Does not contain file contents, standard output, or environment values."
        ], uniquingKeysWith: { _, value in value })
        record("scan_start", details: details)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0.05, heartbeatInterval), repeating: max(0.05, heartbeatInterval))
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        self.timer = timer
        timer.resume()
    }

    private static var machineModel: String {
        var count = 0
        guard sysctlbyname("hw.model", nil, &count, nil, 0) == 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: count)
        guard sysctlbyname("hw.model", &buffer, &count, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private var elapsed: Double { Resources.seconds(started.duration(to: .now)) }

    private func begin(_ operation: String, path: String?, category: String?, details: [String: String]) -> UUID {
        let id = UUID()
        lock.withLock {
            guard !closed else { return }
            let activity = Activity(id: id, operation: operation, category: category, path: path,
                details: details, startedSeconds: elapsed)
            active[id] = activity
            if operation == "directory", detailBudgetReached { omittedDetailEvents += 1; return }
            var fields = details
            fields["operation"] = operation
            fields["span_id"] = id.uuidString
            fields["path"] = path
            emitLocked("span_start", category: category, details: fields, detail: operation == "directory")
        }
        return id
    }

    private func update(_ id: UUID, path: String?, details: [String: String]) {
        lock.withLock {
            guard active[id] != nil else { return }
            if let path { active[id]?.path = path }
            active[id]?.details.merge(details, uniquingKeysWith: { _, value in value })
        }
    }

    private func end(_ id: UUID, outcome: String, details: [String: String]) {
        lock.withLock {
            guard let activity = active.removeValue(forKey: id), !closed else { return }
            if activity.operation == "directory", detailBudgetReached { omittedDetailEvents += 1; return }
            var fields = activity.details.merging(details, uniquingKeysWith: { _, value in value })
            fields["span_id"] = id.uuidString
            fields["operation"] = activity.operation
            fields["path"] = activity.path
            fields["outcome"] = outcome
            fields["duration_seconds"] = "\(elapsed - activity.startedSeconds)"
            emitLocked("span_end", category: activity.category, details: fields, detail: activity.operation == "directory")
        }
    }

    private func record(_ event: String, category: String? = nil, details: [String: String] = [:]) {
        lock.withLock {
            guard !closed else { return }
            emitLocked(event, category: category, details: details)
        }
    }

    private func progress(_ progress: ScanProgress) {
        lock.withLock {
            guard !closed else { return }
            let now = elapsed
            emitLocked("progress", details: ["percent": "\(progress.percent)",
                "completed_categories": "\(progress.completedCategories)", "total_categories": "\(progress.totalCategories)",
                "seconds_since_progress": "\(now - lastProgressSeconds)", "phase": progress.phase ?? ""])
            lastProgress = progress.percent
            lastProgressSeconds = now
        }
    }

    private func heartbeat() {
        lock.withLock {
            guard !closed else { return }
            let now = elapsed
            let encoder = JSONEncoder()
            let activities = active.values.sorted { $0.startedSeconds < $1.startedSeconds }
            func json<T: Encodable>(_ value: T) -> String {
                (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "unavailable"
            }
            let resources = Resources.capture()
            emitLocked("heartbeat", details: [
                "progress_percent": "\(lastProgress)", "seconds_since_progress": "\(now - lastProgressSeconds)",
                "active_operations": json(activities), "workers": json(AllocatedSizeMeasurer.workerActivity),
                "resources": json(resources.difference(from: baseline, wallSeconds: now)),
                "thermal_state": "\(ProcessInfo.processInfo.thermalState.rawValue)",
                "low_power_mode": "\(ProcessInfo.processInfo.isLowPowerModeEnabled)",
                "omitted_detail_events": "\(omittedDetailEvents)"
            ])
        }
    }

    /// Ends the log after scan workers return. Pending operations remain visible in the final record.
    public func finish(outcome: String) {
        timer?.cancel()
        lock.withLock {
            guard !closed else { return }
            emitLocked("scan_end", details: ["outcome": outcome, "active_operations": "\(active.count)"])
            closed = true
            queue.async { [self] in try? handle.synchronize(); try? handle.close() }
        }
    }

    /// Waits for pending records before a test or export reads the file.
    public func flush() { queue.sync {} }

    private func emitLocked(_ event: String, category: String? = nil, details: [String: String], detail: Bool = false) {
        if detail && (detailBudgetReached || maximumDetailBytes == 0) {
            omittedDetailEvents += 1
            if !detailBudgetReached {
                detailBudgetReached = true
                emitLocked("detail_limit_reached", details: ["limit_bytes": "\(maximumDetailBytes)",
                    "continuing": "Heartbeats, measurements, commands, and category results remain enabled."])
            }
            return
        }
        sequence += 1
        let value = Event(sequence: sequence, timestamp: Date(), elapsedSeconds: elapsed,
            event: event, category: category, details: details)
        queue.async { [self] in
            guard !writeFailed else { return }
            if detail && detailBytes >= maximumDetailBytes {
                lock.withLock { omittedDetailEvents += 1 }
                return
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var data = try? encoder.encode(value) else { return }
            data.append(10)
            if detail && detailBytes + data.count >= maximumDetailBytes {
                detailBytes = maximumDetailBytes
                lock.withLock { detailBudgetReached = true; omittedDetailEvents += 1 }
                let warning = Event(sequence: value.sequence, timestamp: value.timestamp,
                    elapsedSeconds: value.elapsedSeconds, event: "detail_limit_reached", category: nil,
                    details: ["limit_bytes": "\(maximumDetailBytes)",
                        "continuing": "Heartbeats, measurements, commands, and category results remain enabled."])
                if var warningData = try? encoder.encode(warning) {
                    warningData.append(10)
                    try? handle.write(contentsOf: warningData)
                }
                return
            }
            do {
                try handle.write(contentsOf: data)
                if detail { detailBytes += data.count }
            } catch { writeFailed = true }
        }
    }

    deinit { timer?.cancel(); try? handle.close() }
}
