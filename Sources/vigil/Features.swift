import Foundation
import IOKit.pwr_mgt
import VigilCore

/// Per-feature definition of which IOKit power assertions to hold.
enum AssertionSet {
    static func definitions(for feature: Feature) -> [(CFString, String)] {
        switch feature {
        case .lidAwake:
            // Stronger set: includes PreventSystemSleep, which keeps the
            // machine alive even when the lid closes. Paired with the
            // privileged `pmset disablesleep 1` profile.
            return [
                (kIOPMAssertionTypePreventSystemSleep as CFString,
                 "Vigil Lid-Awake: prevent system sleep"),
                (kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                 "Vigil Lid-Awake: prevent idle system sleep"),
                (kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                 "Vigil Lid-Awake: prevent idle display sleep"),
            ]

        case .caffeinate:
            // Idle-sleep prevention only. Manual Apple-menu Sleep and lid
            // close still send the machine to sleep — by design.
            return [
                (kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                 "Vigil Caffeinate: prevent idle system sleep"),
                (kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                 "Vigil Caffeinate: prevent idle display sleep"),
            ]
        }
    }
}

// MARK: - Lid-Awake controller

/// Enable / disable / status for the lid-closed-awake feature. Layered on
/// top of:
///   1. A reversible privileged `pmset` profile (snapshotted on first enable,
///      restored on disable / auto-expiry).
///   2. A persistent user LaunchAgent (`com.vigil.app.lid-awake`) that runs
///      `vigil hold lid-awake` and holds three IOKit assertions while the
///      session sentinel exists.
enum LidAwakeController {

    static func enable(duration: Duration, forceBattery: Bool) throws {
        let battery = BatteryState.load()
        if battery.isBatteryPower && !forceBattery {
            throw RuntimeError.refused("""
            Refusing to enable lid-awake while on battery power.
            Power source: \(battery.source)
            Re-run with --force-battery if you really want that.
            """)
        }

        try savePmsetSnapshotIfNeeded()
        try saveVisualStateIfNeeded()

        print("Enabling closed-lid full-awake profile.")
        try Privilege.runPMSetBatch([
            ["-a", "disablesleep", "1", "sleep", "0", "disksleep", "0", "ttyskeepawake", "1", "tcpkeepalive", "1"]
        ])

        try saveVisualOptions(VisualOptions.fromCommandLine())

        // Persist the session BEFORE touching the sentinel so the hold agent
        // can read its expiry on the first run-loop turn.
        let session = FeatureSession(feature: .lidAwake, enabledAt: Date(), duration: duration)
        try FeatureStateStore.shared.write(session)
        try saveInitialLidTelemetry()
        try LaunchAgent.install(for: .lidAwake)
        try FeatureStateStore.shared.touchSentinel(for: .lidAwake)
        LaunchAgent.waitForStartup(of: .lidAwake)

        // Emit the start event AFTER everything is in place — if anything
        // above throws, we don't want a phantom start in the log with no
        // corresponding end.
        StatsLog.shared.append(.sessionStarted(.init(
            sessionID: session.id,
            feature: .lidAwake,
            timestamp: session.enabledAt,
            duration: duration
        )))

        print("SleepDisabled is now \(PowerDomainState.load().sleepDisabled.map(Utility.formatBool) ?? "unknown").")
        print("Lid-awake agent is \(LaunchAgent.isRunning(for: .lidAwake) ? "running" : "not running").")
        if let remaining = session.remainingSeconds() {
            print("Auto-disables in \(remaining) seconds.")
        }
        print("Disable with: vigil lid-awake off")
    }

    static func disable() throws {
        print("Disabling closed-lid full-awake profile.")

        // Emit sessionEnded BEFORE removing the session / telemetry so we
        // have the data to compute durations. The append is idempotent on
        // sessionID, so a race with the agent's signal handler is safe.
        emitSessionEnded(reason: .userDisabled)

        try restoreVisualState(removeSnapshot: true)
        FeatureStateStore.shared.removeSentinel(for: .lidAwake)
        FeatureStateStore.shared.clear(.lidAwake)
        LidTelemetry.remove()
        LaunchAgent.kill(for: .lidAwake)
        try restorePmsetSnapshot()
        print("SleepDisabled is now \(PowerDomainState.load().sleepDisabled.map(Utility.formatBool) ?? "unknown").")
        print("Lid-awake agent is \(LaunchAgent.isRunning(for: .lidAwake) ? "running" : "stopped").")
    }

    /// Build and append a `.sessionEnded` event from the current session
    /// and lid-telemetry state. Best-effort — silently no-ops if the
    /// session file is gone.
    static func emitSessionEnded(reason: StatsEvent.EndReason, at endedAt: Date = Date()) {
        guard let session = FeatureStateStore.shared.read(.lidAwake) else { return }
        let elapsed = max(0, endedAt.timeIntervalSince(session.enabledAt))
        let telemetry = LidTelemetry.load()
        var accumulated = telemetry?.accumulatedLidClosedSeconds ?? 0
        // Fold any in-flight lid-closed duration into the accumulator.
        if let closedAt = telemetry?.lidClosedAt {
            accumulated += max(0, endedAt.timeIntervalSince(closedAt))
        }
        StatsLog.shared.append(.sessionEnded(.init(
            sessionID: session.id,
            feature: .lidAwake,
            startedAt: session.enabledAt,
            endedAt: endedAt,
            endReason: reason,
            elapsedSeconds: elapsed,
            lidClosedSeconds: accumulated,
            lastLidCloseSeconds: telemetry?.lastClosedSeconds
        )))
    }

    static func toggle(duration: Duration, forceBattery: Bool) throws {
        let enabled = PowerDomainState.load().sleepDisabled ?? false
        if enabled {
            try disable()
        } else {
            try enable(duration: duration, forceBattery: forceBattery)
        }
    }

    // MARK: - Snapshot / restore

    static func savePmsetSnapshotIfNeeded() throws {
        if FileManager.default.fileExists(atPath: Paths.pmsetSnapshotFile.path) {
            return
        }

        try Paths.ensureAppSupportDirectoryExists()
        let state = StateFile(
            createdAt: Date(),
            sleepDisabled: PowerDomainState.load().sleepDisabled,
            settings: PMSetSnapshot.capture()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: Paths.pmsetSnapshotFile, options: .atomic)
    }

    static func saveVisualStateIfNeeded() throws {
        if FileManager.default.fileExists(atPath: Paths.visualStateFile.path) {
            return
        }

        try Paths.ensureAppSupportDirectoryExists()
        let state = VisualStateFile(
            createdAt: Date(),
            displayBrightness: DisplayBrightness.capture(),
            keyboardBrightness: KeyboardBacklight.capture()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: Paths.visualStateFile, options: .atomic)
    }

    static func saveVisualOptions(_ options: VisualOptions) throws {
        try Paths.ensureAppSupportDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(options).write(to: Paths.visualOptionsFile, options: .atomic)
    }

    static func saveInitialLidTelemetry() throws {
        let telemetry = LidTelemetry(
            enabledAt: Date(),
            lidClosedAt: nil,
            accumulatedLidClosedSeconds: 0,
            lastClosedSeconds: nil
        )
        try telemetry.write()
    }

    static func restorePmsetSnapshot() throws {
        guard FileManager.default.fileExists(atPath: Paths.pmsetSnapshotFile.path) else {
            try Privilege.runPMSetBatch(
                [["-a", "disablesleep", "0"]] + restorePowerSettingCommands(PMSetSnapshot.fallbackSettings)
            )
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(StateFile.self, from: Data(contentsOf: Paths.pmsetSnapshotFile))

        try Privilege.runPMSetBatch(
            [["-a", "disablesleep", (state.sleepDisabled == true ? "1" : "0")]]
                + restorePowerSettingCommands(state.settings)
        )

        try? FileManager.default.removeItem(at: Paths.pmsetSnapshotFile)
    }

    static func restorePowerSettingCommands(_ settingsBySource: [String: [String: Int]]) -> [[String]] {
        var commands: [[String]] = []
        for source in ["AC Power", "Battery Power"] {
            guard let settings = settingsBySource[source], !settings.isEmpty else { continue }
            let flag = source == "AC Power" ? "-c" : "-b"
            var arguments = [flag]
            for key in PMSetSnapshot.argumentsChangedByEnable {
                if let value = settings[key] {
                    arguments += [key, "\(value)"]
                }
            }
            if arguments.count > 1 {
                commands.append(arguments)
            }
        }
        return commands
    }

    static func restoreVisualState(removeSnapshot: Bool) throws {
        guard FileManager.default.fileExists(atPath: Paths.visualStateFile.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(VisualStateFile.self, from: Data(contentsOf: Paths.visualStateFile))
        DisplayBrightness.restore(state.displayBrightness)
        if let keyboardBrightness = state.keyboardBrightness {
            KeyboardBacklight.set(keyboardBrightness)
        }
        if removeSnapshot {
            try? FileManager.default.removeItem(at: Paths.visualStateFile)
        }
    }
}

// MARK: - Caffeinate controller

/// Enable / disable / status for the caffeinate feature.
///
/// No privileged ops, no `pmset` mutation, no visual dim/restore. The
/// LaunchAgent simply holds two IOKit assertions while the sentinel file
/// exists, and the in-agent expiry timer releases them at the deadline.
enum CaffeinateController {

    static func enable(duration: Duration, forceBattery: Bool) throws {
        let battery = BatteryState.load()
        if battery.isBatteryPower && !forceBattery {
            // Caffeinate's default is to allow battery — the menu app passes
            // `--force-battery` automatically. CLI users see the warning
            // unless they pass it. Caffeinate does not refuse hard like
            // lid-awake does, because the user is present.
            print("Note: starting caffeinate on battery power.")
        }

        let session = FeatureSession(feature: .caffeinate, enabledAt: Date(), duration: duration)
        try FeatureStateStore.shared.write(session)
        try LaunchAgent.install(for: .caffeinate)
        try FeatureStateStore.shared.touchSentinel(for: .caffeinate)
        LaunchAgent.waitForStartup(of: .caffeinate)

        StatsLog.shared.append(.sessionStarted(.init(
            sessionID: session.id,
            feature: .caffeinate,
            timestamp: session.enabledAt,
            duration: duration
        )))

        print("Caffeinate agent is \(LaunchAgent.isRunning(for: .caffeinate) ? "running" : "not running").")
        if let remaining = session.remainingSeconds() {
            print("Auto-disables in \(remaining) seconds.")
        }
        print("Disable with: vigil caffeinate off")
    }

    static func disable() throws {
        print("Disabling caffeinate.")
        emitSessionEnded(reason: .userDisabled)
        FeatureStateStore.shared.removeSentinel(for: .caffeinate)
        FeatureStateStore.shared.clear(.caffeinate)
        LaunchAgent.kill(for: .caffeinate)
        print("Caffeinate agent is \(LaunchAgent.isRunning(for: .caffeinate) ? "running" : "stopped").")
    }

    static func emitSessionEnded(reason: StatsEvent.EndReason, at endedAt: Date = Date()) {
        guard let session = FeatureStateStore.shared.read(.caffeinate) else { return }
        let elapsed = max(0, endedAt.timeIntervalSince(session.enabledAt))
        StatsLog.shared.append(.sessionEnded(.init(
            sessionID: session.id,
            feature: .caffeinate,
            startedAt: session.enabledAt,
            endedAt: endedAt,
            endReason: reason,
            elapsedSeconds: elapsed,
            lidClosedSeconds: nil,
            lastLidCloseSeconds: nil
        )))
    }

    static func toggle(duration: Duration, forceBattery: Bool) throws {
        if LaunchAgent.isRunning(for: .caffeinate) {
            try disable()
        } else {
            try enable(duration: duration, forceBattery: forceBattery)
        }
    }
}

// MARK: - Generalised hold engine

/// Runs in the LaunchAgent process. Holds the per-feature IOKit assertions,
/// schedules expiry, watches for the sentinel disappearing, and (for
/// lid-awake) polls lid state to drive visual dim/restore. Never returns.
enum HoldEngine {

    static func run(feature: Feature) -> Never {
        var assertionIDs: [IOPMAssertionID] = []
        for (type, name) in AssertionSet.definitions(for: feature) {
            var id = IOPMAssertionID(0)
            let r = IOPMAssertionCreateWithName(
                type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id
            )
            if r == kIOReturnSuccess {
                assertionIDs.append(id)
            } else {
                fputs("Failed to create assertion \(name): \(r)\n", stderr)
            }
        }

        // Read the persisted session to learn the expiry deadline. If the
        // sentinel exists but no session does (defensive), treat as
        // indefinite.
        let session = FeatureStateStore.shared.read(feature)
        let expiresAt = session?.expiresAt

        // Primary expiry timer: wall-clock-deadline DispatchSourceTimer
        // fires reliably across sleep/wake.
        var primaryTimer: DispatchSourceTimer?
        if let expiresAt {
            let interval = expiresAt.timeIntervalSinceNow
            if interval <= 0 {
                handleExpiry(feature: feature, assertionIDs: assertionIDs)
            }
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(wallDeadline: .now() + max(0, interval))
            t.setEventHandler {
                handleExpiry(feature: feature, assertionIDs: assertionIDs)
            }
            t.resume()
            primaryTimer = t
        }

        // Belt-and-suspenders: a SECOND wall-deadline timer rescheduled every
        // 60 wall-clock seconds checks `expiresAt <= now` independently.
        // Using DispatchSourceTimer(wallDeadline:) — NOT Timer.scheduledTimer
        // — because Timer.scheduledTimer's RunLoop pauses across sleep.
        var beltTimer: DispatchSourceTimer?
        if expiresAt != nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(wallDeadline: .now() + 60, repeating: .seconds(60))
            t.setEventHandler {
                if let s = FeatureStateStore.shared.read(feature), s.isExpired() {
                    handleExpiry(feature: feature, assertionIDs: assertionIDs)
                }
            }
            t.resume()
            beltTimer = t
        }

        // Sentinel watchdog: if a sibling deletes our sentinel (e.g.
        // `vigil <feature> off`), launchd will eventually reap us, but we
        // also self-exit promptly to release assertions.
        let sentinelWatchdog = DispatchSource.makeTimerSource(queue: .main)
        sentinelWatchdog.schedule(wallDeadline: .now() + 1, repeating: .seconds(1))
        sentinelWatchdog.setEventHandler {
            if !FeatureStateStore.shared.sentinelExists(for: feature) {
                releaseAssertions(assertionIDs)
                Foundation.exit(0)
            }
        }
        sentinelWatchdog.resume()

        // Lid-awake-only: 1 Hz lid-state polling for visual dim/restore.
        var lidPollTimer: Timer?
        if feature == .lidAwake {
            let visualOptions = VisualOptions.loadForAssertionAgent()
            var lastLidState = PowerDomainState.load().clamshellClosed
            if lastLidState == true {
                markLidClosed()
                try? dimVisualsForClosedLid(options: visualOptions)
            }

            lidPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let lidClosed = PowerDomainState.load().clamshellClosed
                guard lidClosed != lastLidState else { return }
                lastLidState = lidClosed

                if lidClosed == true {
                    markLidClosed()
                    try? dimVisualsForClosedLid(options: visualOptions)
                } else if lidClosed == false {
                    markLidOpened()
                    try? LidAwakeController.restoreVisualState(removeSnapshot: false)
                }
            }
        }

        // Signal handlers: SIGTERM and SIGINT (sent by launchctl bootout /
        // kill). We use DispatchSource rather than a raw signal() handler
        // so we can do Swift work (file reads, JSON encoding) on a normal
        // GCD queue — `signal()` handlers must be async-signal-safe and
        // can't legitimately call ObjC/Swift runtime code. We mask the
        // signal with SIG_IGN and let DispatchSource handle it.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { handleSignaledExit(feature: feature, assertionIDs: assertionIDs) }
        sigterm.resume()
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { handleSignaledExit(feature: feature, assertionIDs: assertionIDs) }
        sigint.resume()

        // Keep references alive across the run loop.
        _ = primaryTimer
        _ = beltTimer
        _ = sentinelWatchdog
        _ = lidPollTimer
        _ = sigterm
        _ = sigint

        RunLoop.main.run()
        fatalError("RunLoop returned unexpectedly")
    }

    // MARK: - Exit paths

    /// Called from the primary or belt-and-suspenders timer. For lid-awake
    /// this MUST be able to run the privileged `pmset` restore, which is why
    /// the lid-awake LaunchAgent's `ProgramArguments` includes
    /// `--approved-helper` — `Privilege.useApprovedHelper` reads
    /// `CommandLine.arguments` directly.
    private static func handleExpiry(feature: Feature, assertionIDs: [IOPMAssertionID]) {
        // Emit FIRST while session/telemetry are still on disk; the
        // per-controller helper computes elapsed + lid-closed from them.
        // StatsLog.append is idempotent on sessionID, so a race with the
        // signal handler is safe.
        switch feature {
        case .lidAwake:   LidAwakeController.emitSessionEnded(reason: .timerExpired)
        case .caffeinate: CaffeinateController.emitSessionEnded(reason: .timerExpired)
        }

        releaseAssertions(assertionIDs)

        switch feature {
        case .lidAwake:
            try? LidAwakeController.restoreVisualState(removeSnapshot: true)
            FeatureStateStore.shared.removeSentinel(for: .lidAwake)
            FeatureStateStore.shared.clear(.lidAwake)
            LidTelemetry.remove()
            do {
                try LidAwakeController.restorePmsetSnapshot()
            } catch {
                fputs("Lid-awake auto-expiry: pmset restore failed: \(error)\n", stderr)
            }

        case .caffeinate:
            FeatureStateStore.shared.removeSentinel(for: .caffeinate)
            FeatureStateStore.shared.clear(.caffeinate)
        }

        Foundation.exit(0)
    }

    /// SIGTERM / SIGINT handler. Distinguishes "user-disable through the
    /// CLI" (which already emitted .userDisabled before SIGTERM-ing us)
    /// from "external bootout" (e.g. Sparkle update) by checking whether
    /// the session file is still on disk. The StatsLog de-dup also catches
    /// any race.
    private static func handleSignaledExit(feature: Feature, assertionIDs: [IOPMAssertionID]) {
        if FeatureStateStore.shared.read(feature) != nil {
            switch feature {
            case .lidAwake:   LidAwakeController.emitSessionEnded(reason: .interrupted)
            case .caffeinate: CaffeinateController.emitSessionEnded(reason: .interrupted)
            }
        }
        // Visual restore is best-effort and only meaningful for lid-awake;
        // IOKit assertions are released by the kernel on task termination,
        // but we do it explicitly anyway for promptness.
        try? LidAwakeController.restoreVisualState(removeSnapshot: false)
        releaseAssertions(assertionIDs)
        Foundation.exit(0)
    }

    private static func releaseAssertions(_ ids: [IOPMAssertionID]) {
        for id in ids where id != 0 {
            IOPMAssertionRelease(id)
        }
    }

    // MARK: - Lid telemetry (lid-awake only)

    private static func markLidClosed() {
        var t = LidTelemetry.load() ?? LidTelemetry(
            enabledAt: Date(),
            lidClosedAt: nil,
            accumulatedLidClosedSeconds: 0,
            lastClosedSeconds: nil
        )
        if t.lidClosedAt == nil {
            t.lidClosedAt = Date()
            try? t.write()
        }
    }

    private static func markLidOpened() {
        guard var t = LidTelemetry.load(), let closedAt = t.lidClosedAt else { return }
        let closedDuration = Date().timeIntervalSince(closedAt)
        t.accumulatedLidClosedSeconds += closedDuration
        t.lastClosedSeconds = closedDuration
        t.lidClosedAt = nil
        try? t.write()
    }

    private static func dimVisualsForClosedLid(options: VisualOptions) throws {
        try LidAwakeController.saveVisualStateIfNeeded()
        if options.dimDisplay {
            DisplayBrightness.setAllOnlineDisplays(to: 0.0)
        }
        if options.dimKeyboard {
            KeyboardBacklight.set(0.0)
        }
    }
}
