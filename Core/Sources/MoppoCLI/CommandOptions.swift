import Foundation

/// Options that the top-level and plan commands share.
struct CommandOptions {
    private(set) var flags: Set<String> = []
    private(set) var values: [String: String] = [:]

    /// Rejects unknown, repeated, and empty options. A value cannot start with `--`.
    static func parse(_ arguments: [String], flags allowedFlags: Set<String>,
                      values allowedValues: Set<String>) throws -> Self {
        var options = Self()
        var remaining = arguments[...]
        while let option = remaining.popFirst() {
            guard !options.flags.contains(option), options.values[option] == nil else {
                throw CLIError.usage("Supply each option only once.")
            }
            if allowedFlags.contains(option) {
                options.flags.insert(option)
                continue
            }
            guard allowedValues.contains(option), let value = remaining.first, !value.hasPrefix("--") else {
                throw CLIError.usage("An option is unknown, has no value, or does not apply to the command. Use moppo --help.")
            }
            options.values[option] = value
            remaining.removeFirst()
        }
        return options
    }
}

/// Text output can contain file names. File names cannot inject terminal control sequences.
enum TerminalText {
    /// Replaces control and formatting characters, including line breaks, in one value.
    static func field(_ value: String) -> String { replacing(value, keepNewlines: false) }

    /// Replaces control and formatting characters in complete output. Line breaks remain.
    static func lines(_ value: String) -> String { replacing(value, keepNewlines: true) }

    private static func replacing(_ value: String, keepNewlines: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control where keepNewlines && scalar == "\n": scalars.append(scalar)
            case .control, .format, .lineSeparator, .paragraphSeparator: scalars.append("?")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
