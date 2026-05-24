import Foundation
import VigilCore
import VigilIdentifiers

/// Per-feature LaunchAgent installation, bootstrap, and bootout.
///
/// Both features get their own plist, both gated on a separate
/// `KeepAlive.PathState` sentinel (`Paths.sentinelFile(for:)`). Both run the
/// same `vigil hold <feature>` engine but with feature-specific
/// `ProgramArguments`. Lid-Awake additionally embeds `--approved-helper` so
/// the agent process has a working privilege path when its timer expires and
/// it needs to restore the saved `pmset` profile.
enum LaunchAgent {

    /// Generate the plist contents for a feature.
    ///
    /// `embedApprovedHelperFlag` is true for lid-awake (so on-timer-expiry
    /// pmset-restore can call the privileged helper non-interactively) and
    /// false for caffeinate (no privileged ops).
    static func plistContents(for feature: Feature) -> String {
        let label = Paths.launchAgentLabel(for: feature)
        let executable = Utility.xmlEscape(Utility.currentExecutablePath())
        let sentinelPath = Utility.xmlEscape(Paths.sentinelFile(for: feature).path)
        let bundleID = Utility.xmlEscape(VigilIdentifiers.bundleID)
        let labelEscaped = Utility.xmlEscape(label)

        var programArguments: [String] = ["\(executable)", "hold", "\(feature.rawValue)"]
        if feature == .lidAwake {
            programArguments.append(Privilege.approvedHelperFlag)
        }
        let programArgumentsXML = programArguments
            .map { "                <string>\(Utility.xmlEscape($0))</string>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(labelEscaped)</string>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>\(bundleID)</string>
            </array>
            <key>ProgramArguments</key>
            <array>
        \(programArgumentsXML)
            </array>
            <key>RunAtLoad</key>
            <false/>
            <key>KeepAlive</key>
            <dict>
                <key>PathState</key>
                <dict>
                    <key>\(sentinelPath)</key>
                    <true/>
                </dict>
            </dict>
            <key>StandardOutPath</key>
            <string>/tmp/\(label).out.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/\(label).err.log</string>
        </dict>
        </plist>
        """
    }

    /// Install (or refresh) the LaunchAgent for `feature` and ensure it is
    /// bootstrapped against the current `gui/<uid>` domain.
    ///
    /// Always rewrites the plist with the *current* executable path so that
    /// after a Sparkle install (or any other in-place bundle replacement) the
    /// plist points at the new CLI binary.
    ///
    /// Refuses to operate from a translocated bundle (the plist would bake
    /// in the ephemeral `/private/var/folders/…/AppTranslocation/…` path and
    /// would silently fail the first time the mount tears down).
    static func install(for feature: Feature) throws {
        if VigilIdentifiers.isTranslocated {
            throw RuntimeError.refused("""
            Refusing to install a LaunchAgent from a translocated bundle.
            macOS Gatekeeper has quarantined this launch. Move Vigil.app to /Applications first.
            """)
        }

        try FileManager.default.createDirectory(
            at: Paths.launchAgentsDirectory,
            withIntermediateDirectories: true
        )

        let plistURL = Paths.launchAgentPlist(for: feature)
        let plist = plistContents(for: feature)
        let existingPlist = try? String(contentsOf: plistURL, encoding: .utf8)
        let plistChanged = existingPlist != plist

        if plistChanged {
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        }

        let domain = "gui/\(getuid())"
        let label = Paths.launchAgentLabel(for: feature)
        let registered = isRegistered(for: feature)

        if !registered {
            _ = try Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        } else if plistChanged {
            _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], requireSuccess: false)
            _ = try Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        }
    }

    /// Signal the agent to terminate. Safe to call when not registered.
    static func kill(for feature: Feature) {
        let domain = "gui/\(getuid())"
        let label = Paths.launchAgentLabel(for: feature)
        _ = try? Shell.run("/bin/launchctl", ["kill", "TERM", "\(domain)/\(label)"], requireSuccess: false)
    }

    /// Fully unregister the LaunchAgent from `gui/<uid>`. Distinct from
    /// `kill` — used by `SparkleDelegate` before replacing the CLI binary
    /// on disk.
    static func bootout(label: String) {
        let domain = "gui/\(getuid())"
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], requireSuccess: false)
    }

    static func isRunning(for feature: Feature) -> Bool {
        guard let result = try? Shell.run(
                "/bin/launchctl",
                ["print", "gui/\(getuid())/\(Paths.launchAgentLabel(for: feature))"],
                requireSuccess: false
              ),
              result.status == 0 else {
            return false
        }
        return result.output.contains("state = running") || result.output.contains("pid = ")
    }

    static func isRegistered(for feature: Feature) -> Bool {
        let result = try? Shell.run(
            "/bin/launchctl",
            ["print", "gui/\(getuid())/\(Paths.launchAgentLabel(for: feature))"],
            requireSuccess: false
        )
        return result?.status == 0
    }

    static func waitForStartup(of feature: Feature, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning(for: feature) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
