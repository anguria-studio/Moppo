import AppKit

@main
enum HomebrewAskpassMain {
    @MainActor
    static func main() {
        // This helper runs as the signed-in user. It never runs removal commands.
        guard getuid() != 0, geteuid() == getuid() else { fail("The password helper must run as the signed-in user.") }
        guard let request = HomebrewAskpassRequest(environment: ProcessInfo.processInfo.environment)
        else { fail("The password request is missing or expired.") }
        guard let helper = HomebrewAskpassRequest.identity(getpid())?.executable
        else { fail("The password helper could not check its executable path.") }
        let helperURL = URL(fileURLWithPath: helper)
        guard helperURL.lastPathComponent == "MoppoHomebrewAskpass",
              helperURL.deletingLastPathComponent().lastPathComponent == "Helpers"
        else { fail("The password helper is outside the Moppo application bundle.") }
        let applicationExecutable = helperURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacOS/Moppo").path
        guard request.accepts(parentPID: getppid(), applicationExecutable: applicationExecutable)
        else { fail("The password helper could not verify the Homebrew process chain.") }
        guard HomebrewAskpassRequest.isSignedMoppo(request.applicationPID)
        else { fail("The password helper could not verify the Moppo signature.") }
        exit(HomebrewPasswordPrompt.run(request: request, applicationExecutable: applicationExecutable))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Moppo: \(message)\n".utf8))
        exit(1)
    }
}
