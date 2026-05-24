import AppKit
import Foundation
import VigilCore
import VigilIdentifiers

/// Result of invoking the bundled `vigil` CLI from the menu app.
struct HelperResult {
    var status: Int32
    var output: String
}

/// Resolves and invokes the bundled `vigil` CLI as a subprocess.
enum Helper {
    static let approvedHelperFlag = "--approved-helper"
    static let adminPromptFlag = "--admin-prompt"

    static var executablePath: String {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("vigil"),
           FileManager.default.isExecutableFile(atPath: resourceURL.path) {
            return resourceURL.path
        }

        let localBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/release/vigil")
        if FileManager.default.isExecutableFile(atPath: localBuild.path) {
            return localBuild.path
        }

        return "/usr/local/bin/vigil"
    }

    static func run(_ arguments: [String]) async -> HelperResult {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                return HelperResult(
                    status: process.terminationStatus,
                    output: output.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } catch {
                return HelperResult(status: 1, output: error.localizedDescription)
            }
        }.value
    }
}

/// Installs and revokes the privileged helper / sudoers entry. Identical
/// scope to v0.1.0-beta.1: three allowlisted verbs, `visudo -cf`-validated.
enum ApprovedHelperInstaller {
    static let privilegedHelperPath = VigilIdentifiers.privilegedHelperPath

    static var sudoersPath: String { VigilIdentifiers.sudoersPath }

    static func install(helperPath: String) async -> HelperResult {
        await Task.detached {
            runPrivileged(script: installScript(helperPath: helperPath), successMessage: "Approved helper: installed")
        }.value
    }

    static func revoke() async -> HelperResult {
        await Task.detached {
            runPrivileged(script: revokeScript(), successMessage: "Approved helper: removed")
        }.value
    }

    static func installedHelperVersion() async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", privilegedHelperPath, "privileged-version"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let output = String(data: data, encoding: .utf8) ?? ""
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } catch {
                return nil
            }
        }.value
    }

    private static func installScript(helperPath: String) -> String {
        let sudoersLine = "\(NSUserName()) ALL=(root) NOPASSWD: \(privilegedHelperPath) privileged-pmset-batch *, \(privilegedHelperPath) approval-status, \(privilegedHelperPath) privileged-version"
        return """
        set -e
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        install -o root -g wheel -m 755 \(shellQuote(helperPath)) \(shellQuote(privilegedHelperPath))
        umask 022
        printf '%s\\n' \(shellQuote(sudoersLine)) > \(shellQuote(sudoersPath))
        chown root:wheel \(shellQuote(sudoersPath))
        chmod 0440 \(shellQuote(sudoersPath))
        /usr/sbin/visudo -cf \(shellQuote(sudoersPath))
        """
    }

    private static func revokeScript() -> String {
        """
        set -e
        rm -f \(shellQuote(privilegedHelperPath)) \(shellQuote(sudoersPath))
        """
    }

    private static func runPrivileged(script: String, successMessage: String) -> HelperResult {
        let encoded = Data(script.utf8).base64EncodedString()
        let command = "/bin/sh -c \(shellQuote("printf %s \(shellQuote(encoded)) | /usr/bin/base64 -D | /bin/sh"))"
        let source = "do shell script \(appleScriptString(command)) with administrator privileges"

        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            return HelperResult(status: 1, output: message)
        }

        return HelperResult(status: 0, output: result?.stringValue ?? successMessage)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

/// Gatekeeper Path Randomization (App Translocation) sandboxes apps launched
/// from `~/Downloads`, `~/Desktop`, etc. into a randomised read-only path.
/// The LaunchAgent plists Vigil installs would point at that ephemeral path
/// and break the moment the user moves Vigil.app to /Applications.
enum AppLocation {
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    static var translocationMessage: String {
        "Vigil is running from a quarantined location. Move Vigil.app to /Applications before enabling."
    }
}
