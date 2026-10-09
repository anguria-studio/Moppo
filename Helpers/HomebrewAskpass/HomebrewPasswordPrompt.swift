import AppKit

@MainActor
enum HomebrewPasswordPrompt {
    static func makeAlert(package: String) -> (alert: NSAlert, password: NSSecureTextField) {
        let alert = NSAlert()
        alert.messageText = "Homebrew needs administrator access"
        alert.informativeText = "Homebrew needs your login password to remove the “\(package)” package.\n\nAccount: \(NSUserName())\n\nMoppo sends the password to sudo and does not save it."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = false
        alert.buttons[1].keyEquivalent = "\u{1b}"

        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        password.placeholderString = "Login password"
        password.setAccessibilityLabel("Login password for \(NSUserName())")
        alert.accessoryView = password
        alert.window.initialFirstResponder = password
        return (alert, password)
    }

    static func run(request: HomebrewAskpassRequest, applicationExecutable: String) -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let (alert, password) = makeAlert(package: request.package)
        let appURL = URL(fileURLWithPath: applicationExecutable)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        alert.icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let editObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: password, queue: .main
        ) { _ in
            MainActor.assumeIsolated { alert.buttons[0].isEnabled = !password.stringValue.isEmpty }
        }

        // Close the dialog if Homebrew exits or the command reaches its time limit.
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !request.accepts(parentPID: getppid(), applicationExecutable: applicationExecutable) {
                    NSApp.abortModal()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer {
            timer.invalidate()
            NotificationCenter.default.removeObserver(editObserver)
            password.stringValue = ""
            alert.window.orderOut(nil)
        }

        application.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn,
              request.accepts(parentPID: getppid(), applicationExecutable: applicationExecutable)
        else {
            FileHandle.standardError.write(Data("Moppo: administrator authentication was cancelled.\n".utf8))
            return 1
        }
        guard !password.stringValue.isEmpty else { return 1 }

        // stdout is sudo's private input pipe. Never print the password elsewhere.
        var bytes = Array(password.stringValue.utf8)
        bytes.append(10)
        password.stringValue = ""
        defer { _ = bytes.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return 1 }
                offset += count
            }
            return 0
        }
    }
}
