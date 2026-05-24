import Foundation
import VigilCore
import VigilIdentifiers

/// Privileged `pmset` execution + scoped one-time-approval helper install.
///
/// The sudoers allowlist surface is intentionally narrow and gated on a
/// single set of verbs (see `VigilIdentifiers.sudoersVerbs`); the in-binary
/// `argumentsAreAllowedPMSetBatch` adds a second layer of validation on
/// the pmset arguments themselves. Caffeinate uses none of this surface.
enum Privilege {
    static let approvedHelperFlag = "--approved-helper"
    static let adminPromptFlag = "--admin-prompt"

    static var useAdminPrompt: Bool {
        CommandLine.arguments.contains(adminPromptFlag)
    }

    static var useApprovedHelper: Bool {
        CommandLine.arguments.contains(approvedHelperFlag) && approvedHelperIsUsable()
    }

    static func runPMSetBatch(_ commands: [[String]]) throws {
        guard !commands.isEmpty else { return }

        if getuid() == 0 {
            for arguments in commands {
                _ = try Shell.run("/usr/bin/pmset", arguments)
            }
        } else if useAdminPrompt {
            let script = (["set -e"] + commands.map { arguments in
                Utility.shellQuote("/usr/bin/pmset") + " " + arguments.map(Utility.shellQuote).joined(separator: " ")
            }).joined(separator: "\n")
            try runPrivilegedShellCommand(script)
        } else if useApprovedHelper {
            try runApprovedHelperPMSetBatch(commands)
        } else {
            _ = try Shell.run("/usr/bin/sudo", ["-v"])
            for arguments in commands {
                _ = try Shell.run("/usr/bin/sudo", ["/usr/bin/pmset"] + arguments)
            }
        }
    }

    static func runRootPMSetBatch(from encodedPayload: String?) throws {
        guard getuid() == 0 else {
            throw RuntimeError.commandFailed("privileged-pmset-batch", "This command must run as root.")
        }
        guard let encodedPayload,
              let data = Data(base64Encoded: encodedPayload),
              let commands = try JSONSerialization.jsonObject(with: data) as? [[String]] else {
            throw RuntimeError.commandFailed("privileged-pmset-batch", "Invalid command payload.")
        }

        for arguments in commands {
            guard argumentsAreAllowedPMSetBatch(arguments) else {
                throw RuntimeError.commandFailed(
                    "privileged-pmset-batch",
                    "Rejected pmset arguments: \(arguments.joined(separator: " "))"
                )
            }
            _ = try Shell.run("/usr/bin/pmset", arguments)
        }
    }

    static func runApprovedHelperPMSetBatch(_ commands: [[String]]) throws {
        let data = try JSONSerialization.data(withJSONObject: commands)
        let encoded = data.base64EncodedString()
        _ = try Shell.run("/usr/bin/sudo", ["-n", VigilIdentifiers.privilegedHelperPath, "privileged-pmset-batch", encoded])
    }

    static func approvedHelperIsUsable() -> Bool {
        FileManager.default.isExecutableFile(atPath: VigilIdentifiers.privilegedHelperPath)
            && (try? Shell.run("/usr/bin/sudo", ["-n", VigilIdentifiers.privilegedHelperPath, "approval-status"], requireSuccess: false).status) == 0
    }

    static func printApprovalStatus() {
        if getuid() == 0 {
            print("Approved helper can run as root.")
        } else if approvedHelperIsUsable() {
            print("Approved helper: installed")
        } else {
            print("Approved helper: not installed")
        }
    }

    static func installApprovedHelper() throws {
        guard getuid() != 0 else {
            throw RuntimeError.commandFailed("approve-all", "Run approval from the menu app or a normal user shell.")
        }

        if VigilIdentifiers.isTranslocated {
            throw RuntimeError.refused("""
            Refusing to install the privileged helper from a translocated bundle.
            macOS Gatekeeper has quarantined this launch under /private/var/folders/…/AppTranslocation/….
            Move Vigil.app to /Applications first, then re-run `vigil approve-all`.
            """)
        }

        let sudoersLine = VigilIdentifiers.sudoersLine(for: NSUserName())
        let helperPath = VigilIdentifiers.privilegedHelperPath
        let script = """
        set -e
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        install -o root -g wheel -m 755 \(Utility.shellQuote(Utility.currentExecutablePath())) \(Utility.shellQuote(helperPath))
        umask 022
        printf '%s\\n' \(Utility.shellQuote(sudoersLine)) > \(Utility.shellQuote(VigilIdentifiers.sudoersPath))
        chown root:wheel \(Utility.shellQuote(VigilIdentifiers.sudoersPath))
        chmod 0440 \(Utility.shellQuote(VigilIdentifiers.sudoersPath))
        /usr/sbin/visudo -cf \(Utility.shellQuote(VigilIdentifiers.sudoersPath))
        """

        try runPrivilegedShellCommand(script)
        print("Approved helper: installed")
    }

    static func printPrivilegedVersion() {
        print(VigilVersion.value)
    }

    static func printPrivilegedIPCContractVersion() {
        print(String(VigilIdentifiers.IPCContractVersion))
    }

    static func runPrivilegedShellCommand(_ command: String) throws {
        let script = "do shell script \(Utility.appleScriptString(command)) with administrator privileges"
        _ = try Shell.run("/usr/bin/osascript", ["-e", script])
    }

    // MARK: - Allowlist (defence-in-depth on top of sudoers verb scoping)

    static func argumentsAreAllowedPMSetBatch(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return false }
        let allowedOptions = Set(["-a", "-b", "-c"])
        let allowedSettings = Set(["disablesleep", "sleep", "disksleep", "ttyskeepawake", "tcpkeepalive"])

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if allowedOptions.contains(argument) {
                index += 1
                continue
            }
            guard allowedSettings.contains(argument),
                  index + 1 < arguments.count,
                  valueIsAllowed(arguments[index + 1], for: argument) else {
                return false
            }
            index += 2
        }
        return true
    }

    static func valueIsAllowed(_ value: String, for setting: String) -> Bool {
        guard let integer = Int(value), integer >= 0 else { return false }
        switch setting {
        case "disablesleep", "ttyskeepawake", "tcpkeepalive":
            return integer == 0 || integer == 1
        case "sleep", "disksleep":
            return integer <= 86400
        default:
            return false
        }
    }
}
