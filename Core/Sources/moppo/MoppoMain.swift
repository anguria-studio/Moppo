import Darwin
import Foundation
import MoppoCLI

@main
struct MoppoMain {
    /// The signal queue is serial. Only that queue reads or changes the count.
    private final class Interrupts: @unchecked Sendable { var count = 0 }

    static func main() async {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let task = Task {
            await CommandLineInterface.run(arguments: arguments, version: version, progress: { progress in
                let text = "Scan progress: \(progress.percent)%\n"
                try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
            })
        }
        // The first interrupt stops the command cleanly. A removal finishes its current item and saves its outcome.
        // A second interrupt stops other commands at once. Those commands do not change cleanup targets.
        let removal = arguments.starts(with: ["plan", "remove"])
        let interrupts = Interrupts()
        let queue = DispatchQueue(label: "moppo.signals")
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { @Sendable in
                interrupts.count += 1
                if interrupts.count == 1 {
                    task.cancel()
                    let text = removal ? "Stopping after the current item.\n" : "Stopping. Interrupt again to stop now.\n"
                    try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
                } else if !removal {
                    exit(130)
                }
            }
            source.resume()
            return source
        }
        let result = await task.value
        sources.forEach { $0.cancel() }
        let output = result.exitCode >= 64 && !arguments.contains("--json")
            ? FileHandle.standardError : FileHandle.standardOutput
        do { try output.write(contentsOf: result.output) }
        catch { exit(74) }
        exit(result.exitCode)
    }
}
