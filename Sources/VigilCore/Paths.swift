import Foundation
import VigilIdentifiers

/// Shared filesystem layout used by both the CLI and the menu app.
///
/// Moved here from the CLI in v0.2.0 so the menu app can read session state
/// directly (for countdowns and Sparkle re-arm) instead of going through the
/// CLI for every read.
public enum Paths {
    public static var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Vigil", isDirectory: true)
    }

    public static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    // ---- Lid-awake's privileged-pmset restore state ---------------------------

    public static var pmsetSnapshotFile: URL {
        appSupportDirectory.appendingPathComponent("state.json")
    }

    public static var visualStateFile: URL {
        appSupportDirectory.appendingPathComponent("visual-state.json")
    }

    public static var visualOptionsFile: URL {
        appSupportDirectory.appendingPathComponent("visual-options.json")
    }

    // ---- Per-feature session + launchd sentinel -------------------------------

    /// Mutable per-feature session record (FeatureSession).
    public static func sessionFile(for feature: Feature) -> URL {
        appSupportDirectory.appendingPathComponent("state-\(feature.rawValue).json")
    }

    /// PathState sentinel watched by launchd's KeepAlive. Touch on enable,
    /// remove on disable, NEVER rewrite — atomic rewrites of a session file
    /// briefly unlink the inode and would otherwise risk launchd flapping the
    /// agent. Keeping the sentinel separate from the session is defence in
    /// depth against that class of bug.
    public static func sentinelFile(for feature: Feature) -> URL {
        appSupportDirectory.appendingPathComponent("sentinel-\(feature.rawValue)")
    }

    public static func launchAgentPlist(for feature: Feature) -> URL {
        launchAgentsDirectory.appendingPathComponent("\(launchAgentLabel(for: feature)).plist")
    }

    public static func launchAgentLabel(for feature: Feature) -> String {
        switch feature {
        case .lidAwake: VigilIdentifiers.lidAwakeAgentLabel
        case .caffeinate: VigilIdentifiers.caffeinateAgentLabel
        }
    }

    /// Marker file written by the menu app's onboarding flow to persist the
    /// "Setup window should re-open at this step" hint across the move-and-
    /// relaunch jump. A file on disk (rather than `UserDefaults`) is the
    /// correct vehicle for cross-process handoff: `UserDefaults` writes go
    /// through `cfprefsd` asynchronously and can lag a deliberate relaunch.
    public static var onboardingResumeMarker: URL {
        appSupportDirectory.appendingPathComponent("onboarding-resume-step")
    }

    public static func ensureAppSupportDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: appSupportDirectory,
            withIntermediateDirectories: true
        )
    }
}
