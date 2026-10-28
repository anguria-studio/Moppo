import Foundation
import CoreServices

public enum ProcessError: Error, Equatable {
    case executableMissing(String)
    case timedOut(String)
    case failed(command: String, status: Int32, stderr: String)
}

/// Captures command output after normal exit, timeout, or cancellation.
public struct ProcessResult: Sendable, Equatable {
    public enum Completion: String, Sendable, Codable {
        case exited, timedOut, cancelled
    }

    public let output: Data
    public let standardError: String
    public let exitStatus: Int32
    public let completion: Completion
    public let terminatedBySignal: Bool
    public let outputReadError: Int32?

    public var succeeded: Bool {
        isSuccessful(additionalSuccessExitStatuses: [], requiresEmptyStandardError: false)
    }

    func isSuccessful(additionalSuccessExitStatuses: Set<Int32>, requiresEmptyStandardError: Bool) -> Bool {
        let acceptedStatus = additionalSuccessExitStatuses.contains(exitStatus) && standardError.isEmpty
        return completion == .exited && !terminatedBySignal && outputReadError == nil
            && (exitStatus == 0 || acceptedStatus) && (!requiresEmptyStandardError || standardError.isEmpty)
    }
}

/// Runs external tools with explicit executable paths.
///
/// Executable paths are absolute and explicit. A GUI app does not inherit the
/// shell's `PATH`, so resolving by name works in a terminal and then fails once the
/// app is launched from Finder — a class of bug the Electron version never hit
/// because it was only ever run from a dev shell.
public struct ProcessRunner: Sendable {

    public init() {}

    @discardableResult
    public func run(
        _ executable: String,
        _ arguments: [String],
        timeout: Duration = .seconds(60),
        environment: [String: String] = [:],
        allowsInput: Bool = true,
        additionalSuccessExitStatuses: Set<Int32> = [],
        requiresEmptyStandardError: Bool = false
    ) async throws -> Data {
        let result = try await runResult(executable, arguments, timeout: timeout,
            environment: environment, allowsInput: allowsInput,
            additionalSuccessExitStatuses: additionalSuccessExitStatuses, requiresEmptyStandardError: requiresEmptyStandardError)
        let command = ([executable] + arguments).joined(separator: " ")
        if result.completion == .cancelled { throw CancellationError() }
        if result.completion == .timedOut { throw ProcessError.timedOut(command) }
        if let error = result.outputReadError {
            throw ProcessError.failed(command: executable, status: result.exitStatus,
                                      stderr: "Command output could not be read (error \(error)).")
        }
        guard result.isSuccessful(additionalSuccessExitStatuses: additionalSuccessExitStatuses,
                                  requiresEmptyStandardError: requiresEmptyStandardError) else {
            throw ProcessError.failed(command: command, status: result.exitStatus,
                stderr: result.terminatedBySignal ? "terminated by signal \(result.exitStatus)" : result.standardError)
        }
        return result.output
    }

    public func runResult(
        _ executable: String,
        _ arguments: [String],
        timeout: Duration = .seconds(60),
        environment: [String: String] = [:],
        allowsInput: Bool = false,
        additionalSuccessExitStatuses: Set<Int32> = [],
        requiresEmptyStandardError: Bool = false
    ) async throws -> ProcessResult {
        let diagnostics = ScanDiagnostics.current
        let span = diagnostics?.begin("process", path: executable, details: [
            "arguments": arguments.joined(separator: "\n"), "timeout_seconds": "\(ScanDiagnostics.Resources.seconds(timeout))"
        ])
        var diagnosticOutcome = "failed"
        defer { diagnostics?.end(span, outcome: Task.isCancelled ? "cancelled" : diagnosticOutcome) }
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.executableMissing(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        if !allowsInput { process.standardInput = FileHandle.nullDevice }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputReader = try ProcessOutputReader(outputPipe.fileHandleForReading)
        let errorReader = try ProcessOutputReader(errorPipe.fileHandleForReading)

        // Set before launching, or an immediate exit could beat the handler into
        // place and the wait below would never be woken.
        let exit = ExitWaiter()
        process.terminationHandler = { _ in exit.markExited() }

        try process.run()
        diagnostics?.update(span, details: ["pid": "\(process.processIdentifier)"])

        // Every signal goes through here, and none is sent once the child has been
        // reaped: after that its pid is just a number the kernel may have handed to
        // somebody else.
        let signals = ChildSignals(process)

        // The watchdog owns the "took too long" verdict. A signal death alone is
        // not evidence of a timeout — crashes die by signal too — so the flag
        // records whether it was us who pulled the trigger. SIGTERM first, and two
        // seconds later SIGKILL for the process that ignores polite requests (a
        // wedged `docker` was the motivating case).
        let timedOut = ExpiryFlag()
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            timedOut.raise()
            diagnostics?.record("process_timeout", details: ["pid": "\(process.processIdentifier)", "executable": executable])
            signals.send(SIGTERM)
            try await Task.sleep(for: .seconds(2))
            signals.send(SIGKILL)
        }
        defer { watchdog.cancel() }

        // A cancelled caller takes the child with it — an orphaned `docker system
        // df` grinding on with nobody to read its answer serves no one — with the
        // same escalation the watchdog uses, owned so it can be called off the
        // moment the child is reaped.
        let escalation = KillEscalation(signals: signals)

        // Wait for the child *before* draining to the end. Reading first was the
        // hang: a descendant that inherited stdout keeps the pipe open long after
        // the child it was forked from is dead, and `readToEnd` waits for the pipe,
        // not for the process.
        //
        // Awaited through `terminationHandler`, never `waitUntilExit()`: that call
        // blocks its thread, and blocking a cooperative-pool thread starves the
        // libdispatch source Foundation uses to notice the exit — a deadlock this
        // suite reproduced immediately.
        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            diagnostics?.record("process_cancel_requested", details: ["pid": "\(process.processIdentifier)"])
            signals.send(SIGTERM)
            escalation.arm()
        }
        signals.markReaped()
        escalation.disarm()
        watchdog.cancel()

        // The child has exited. Collect buffered bytes without waiting for descendants to close their pipes.
        let outputResult = await outputReader.finish()
        let errorResult = await errorReader.finish()
        let output = outputResult.data
        let errorOutput = errorResult.data
        diagnostics?.update(span, details: ["exit_status": "\(process.terminationStatus)",
            "termination_reason": "\(process.terminationReason.rawValue)", "stdout_bytes": "\(output.count)",
            "stderr_bytes": "\(errorOutput.count)", "stderr": String(decoding: errorOutput.prefix(4096), as: UTF8.self),
            "stdout_read_error": "\(outputResult.error ?? 0)", "stderr_read_error": "\(errorResult.error ?? 0)"])

        let completion: ProcessResult.Completion = Task.isCancelled ? .cancelled : timedOut.isRaised ? .timedOut : .exited
        let result = ProcessResult(output: output, standardError: String(decoding: errorOutput, as: UTF8.self),
            exitStatus: process.terminationStatus, completion: completion,
            terminatedBySignal: process.terminationReason == .uncaughtSignal,
            outputReadError: outputResult.error ?? errorResult.error)
        switch completion {
        case .cancelled: diagnosticOutcome = "cancelled"
        case .timedOut: diagnosticOutcome = "timed_out"
        case .exited:
            diagnosticOutcome = result.isSuccessful(additionalSuccessExitStatuses: additionalSuccessExitStatuses,
                requiresEmptyStandardError: requiresEmptyStandardError) ? "completed" : "failed"
        }
        return result
    }

}

/// Drains each pipe without blocking a thread or discarding bytes when a descendant keeps it open.
private final class ProcessOutputReader: @unchecked Sendable {
    struct Output: Sendable {
        var data = Data()
        var error: Int32?
    }

    private let queue = DispatchQueue(label: "Moppo.process-output", qos: .userInitiated)
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private var output = Output()
    private var ended = false

    init(_ handle: FileHandle) throws {
        descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? handle.close() }
        source.resume()
    }

    deinit { source.cancel() }

    func finish() async -> Output {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                drain()
                ended = true
                source.cancel()
                continuation.resume(returning: output)
            }
        }
    }

    private func drain() {
        guard !ended else { return }
        var remaining: Int32 = 0
        // Darwin's FIONREAD macro is not imported into Swift.
        let bytesAvailable: UInt = 0x4004667f
        guard ioctl(descriptor, bytesAvailable, &remaining) == 0 else {
            output.error = errno
            ended = true
            source.cancel()
            return
        }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        repeat {
            let count = read(descriptor, &buffer, min(buffer.count, max(1, Int(remaining))))
            if count > 0 {
                output.data.append(contentsOf: buffer.prefix(count))
                remaining -= Int32(count)
                continue
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                output.error = errno
            }
            ended = true
            source.cancel()
            return
        } while remaining > 0
    }
}

/// Bridges `Process.terminationHandler` to `await`.
///
/// The handler can fire before anyone is waiting — a fast child beats the first
/// suspension — so the flag is what the waiter reads, and the continuation is only
/// parked when the child is still alive.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markExited() {
        lock.lock()
        exited = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// The one place this file signals a child.
///
/// A pid identifies a process only until it is reaped; after that the kernel is
/// free to hand the same number to something else, and a stray `kill` would land
/// on a stranger. Both delayed-SIGKILL paths route through here, and both are shut
/// off by `markReaped()` — taken under the same lock the sends use, so a send that
/// is already inside the lock finishes before the flag is set and one that arrives
/// afterwards is refused.
private final class ChildSignals: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var reaped = false

    init(_ process: Process) { self.process = process }

    func send(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        // `isRunning` is the second guard: Foundation clears it as the child exits,
        // which covers a process that died on its own before we were reaped.
        guard !reaped, process.isRunning else { return }
        kill(process.processIdentifier, signal)
    }

    func markReaped() {
        lock.lock()
        reaped = true
        lock.unlock()
    }
}

/// A SIGKILL scheduled for a process that ignored SIGTERM, cancellable the moment
/// the process is reaped.
private final class KillEscalation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var disarmed = false
    private let signals: ChildSignals

    init(signals: ChildSignals) { self.signals = signals }

    func arm() {
        lock.lock()
        defer { lock.unlock() }
        guard !disarmed, task == nil else { return }
        let signals = self.signals
        task = Task.detached {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return   // disarmed: the child is already gone.
            }
            // Refused outright if the child has been reaped meanwhile.
            signals.send(SIGKILL)
        }
    }

    func disarm() {
        lock.lock()
        let pending = task
        task = nil
        disarmed = true
        lock.unlock()
        pending?.cancel()
    }
}

/// Set once by the watchdog, read after the child exits, possibly from another
/// thread — hence the lock rather than a plain `var` the compiler would rightly
/// refuse to share.
private final class ExpiryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock(); raised = true; lock.unlock()
    }

    var isRaised: Bool {
        lock.lock(); defer { lock.unlock() }; return raised
    }
}

public enum SystemExecutable {
    public static let diskutil = "/usr/sbin/diskutil"

    /// Docker Desktop installs to several locations and is often absent entirely.
    public static let dockerCandidates = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        NSHomeDirectory() + "/.docker/bin/docker"
    ]

    public static func resolveDocker() -> String? {
        if let path = dockerCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        guard let app = dockerDesktopApplicationURL() else { return nil }
        let path = app.appendingPathComponent("Contents/Resources/bin/docker").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    public static func dockerDesktopApplicationURL() -> URL? {
        let registered = LSCopyApplicationURLsForBundleIdentifier("com.docker.docker" as CFString, nil)?
            .takeRetainedValue() as? [URL] ?? []
        let candidates = registered + [URL(fileURLWithPath: "/Applications/Docker.app"),
            URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Docker.app")]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path) && Bundle(url: $0)?.bundleIdentifier == "com.docker.docker"
        }
    }
}
