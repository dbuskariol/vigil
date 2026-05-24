import Foundation

enum ExitCode: Int32 {
    case ok = 0
    case usage = 64
    case failure = 1
}

struct CommandResult {
    let status: Int32
    let output: String
}

enum RuntimeError: Error, CustomStringConvertible {
    case commandFailed(String, String)
    case refused(String)
    case unknownCommand(String)

    var description: String {
        switch self {
        case let .commandFailed(command, output):
            return "Command failed: \(command)\n\(output)"
        case let .refused(message):
            return message
        case let .unknownCommand(command):
            return "Unknown command: \(command)"
        }
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String], requireSuccess: Bool = true) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        let result = CommandResult(
            status: process.terminationStatus,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if requireSuccess && result.status != 0 {
            throw RuntimeError.commandFailed("\(executable) \(arguments.joined(separator: " "))", result.output)
        }

        return result
    }
}

enum Utility {
    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func currentExecutablePath() -> String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    static func formatBool(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}
