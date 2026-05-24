import Foundation

public enum VigilIdentifiers {
    public static let bundleID = "com.vigil.app"

    // v0.2.0+ per-feature LaunchAgent labels. The CLI installs one plist per
    // feature; both share the same AssociatedBundleIdentifiers so that macOS
    // System Settings → General → Login Items shows a single "Vigil" entry
    // that toggles both background agents together.
    public static let lidAwakeAgentLabel = "\(bundleID).lid-awake"
    public static let caffeinateAgentLabel = "\(bundleID).caffeinate"

    public static let privilegedHelperPath = "/Library/PrivilegedHelperTools/\(bundleID).helper"

    public static var sudoersPath: String {
        "/etc/sudoers.d/vigil-\(getuid())"
    }

    // MARK: - IPC contract version
    //
    // INTEGER VERSION OF THE PRIVILEGED-IPC CONTRACT SURFACE.
    //
    // Bump ONLY when one of the following changes:
    //   - A sudoers verb is added, removed, or renamed in `sudoersVerbs`.
    //   - The in-binary allowlist in `Privilege.argumentsAreAllowedPMSetBatch`
    //     gains or loses an option, setting, or value range.
    //   - The wire format of `privileged-pmset-batch <base64>` changes
    //     (e.g. switching from `[[String]]` JSON to something else).
    //
    // Do NOT bump for routine bug-fix releases, refactors that leave the
    // contract semantically identical, or menu-app-only changes. The
    // helper-contract-mismatch handshake reads THIS constant, not
    // `VigilVersion.value`, so bumping here is what forces a user re-approval.
    public static let IPCContractVersion: Int = 1

    // MARK: - Sudoers (single source of truth)
    //
    // Both the CLI's `Privilege.installApprovedHelper` and the menu app's
    // `ApprovedHelperInstaller.installScript` must produce byte-identical
    // sudoers lines. Centralising the verb list here avoids the duplicate-
    // string-literal drift risk.
    //
    // ADDING A VERB REQUIRES BUMPING `IPCContractVersion`.
    // REMOVING OR RENAMING A VERB REQUIRES BUMPING `IPCContractVersion`.
    public static let sudoersVerbs: [String] = [
        "privileged-pmset-batch *",
        "approval-status",
        "privileged-version",
        "privileged-ipc-version",
    ]

    public static func sudoersLine(for user: String) -> String {
        let verbs = sudoersVerbs.map { "\(privilegedHelperPath) \($0)" }.joined(separator: ", ")
        return "\(user) ALL=(root) NOPASSWD: \(verbs)"
    }

    // MARK: - Translocation detection (shared between CLI and menu app)
    //
    // App Translocation: macOS Gatekeeper Path Randomization mounts a
    // quarantined .app under `/private/var/folders/.../AppTranslocation/...`
    // as a read-only volume. Any LaunchAgent plist written from this context
    // would bake in the ephemeral mount path; when the mount tears down the
    // agent's `ProgramArguments[0]` points at nothing. Both the menu app's
    // safety guard and the CLI's `LaunchAgent.install` refuse to operate
    // from a translocated bundle.
    public static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }
}
