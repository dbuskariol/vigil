import Foundation

/// One-shot migration from v0.1.0-beta.1's single-feature layout to v0.2.0's
/// per-feature layout.
///
/// Idempotent and guarded by a file marker on disk (not UserDefaults — the
/// CLI and the menu app live in different defaults domains, so a defaults
/// marker would be written by whichever entry point ran first and the other
/// would still think it had to migrate).
///
/// Runs from both the CLI top-level dispatch and from the menu app's
/// `AppCoordinator.init`, whichever fires first.
public enum LegacyMigration {

    /// Run the migration if it has not yet run on this account.
    ///
    /// `bootoutAgent` is injected so callers can wire it to the same
    /// `launchctl` invocation they use elsewhere; the migration itself does
    /// not link launchctl directly.
    public static func runIfNeeded(
        bootoutAgent: (String) -> Void,
        fileManager: FileManager = .default
    ) {
        guard !fileManager.fileExists(atPath: Paths.legacyMigrationMarker.path) else {
            return
        }

        let legacyPlist = Paths.launchAgentsDirectory
            .appendingPathComponent("com.vigil.app.assertions.plist")
        let legacyRuntimeState = Paths.appSupportDirectory
            .appendingPathComponent("runtime-state.json")

        // 1. Always best-effort bootout the legacy label — safe to call on an
        //    already-gone agent.
        bootoutAgent("com.vigil.app.assertions")

        // 2. Adopt an active legacy session into the new lid-awake model
        //    BEFORE removing the legacy state file, so we don't lose the
        //    enabledAt timestamp.
        if let data = try? Data(contentsOf: legacyRuntimeState),
           let legacy = try? legacyDecoder.decode(LegacyRuntimeState.self, from: data) {
            let session = FeatureSession(
                feature: .lidAwake,
                enabledAt: legacy.enabledAt,
                duration: .indefinite
            )
            try? FeatureStateStore.shared.write(session)
            try? FeatureStateStore.shared.touchSentinel(for: .lidAwake)
        }

        // 3. Remove legacy artefacts.
        try? fileManager.removeItem(at: legacyRuntimeState)
        try? fileManager.removeItem(at: legacyPlist)

        // 4. Mark migration done. The `state.json`, `visual-state.json`, and
        //    `visual-options.json` files are NOT touched — they hold pmset
        //    and brightness snapshots used by LidAwakeController for restore
        //    and are still meaningful in v0.2.0.
        try? Paths.ensureAppSupportDirectoryExists()
        try? Data().write(to: Paths.legacyMigrationMarker, options: .atomic)
    }

    private static let legacyDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    private struct LegacyRuntimeState: Decodable {
        let enabledAt: Date
    }
}
