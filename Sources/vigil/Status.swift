import Foundation
import VigilCore
import VigilIdentifiers

/// Builds `StatusReport` from live system state plus persisted session
/// records, and emits it as either machine-readable JSON or human-readable
/// text.
enum Status {

    static func build() -> StatusReport {
        let power = PowerDomainState.load()
        let battery = BatteryState.load()
        let displays = DisplayState.load()
        let internalBatteryLine = battery.detail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first(where: { $0.hasPrefix("-InternalBattery-") })

        let batteryParts = internalBatteryLine.map { BatteryState.parseInternalBattery($0) }

        let lidSession = FeatureStateStore.shared.read(.lidAwake)
        let caffSession = FeatureStateStore.shared.read(.caffeinate)
        let lidTelemetry = LidTelemetry.load()

        let lidExtras = StatusReport.FeatureSnapshot.LidExtras(
            currentClosedSince: lidTelemetry?.lidClosedAt,
            lastClosedSeconds: lidTelemetry?.lastClosedSeconds.map { Int($0) },
            accumulatedClosedSeconds: Int(lidTelemetry?.accumulatedLidClosedSeconds ?? 0)
        )

        let features = Feature.allCases.map { f -> StatusReport.FeatureSnapshot in
            let agentRunning = LaunchAgent.isRunning(for: f)
            let sentinelExists = FeatureStateStore.shared.sentinelExists(for: f)
            let session = f == .lidAwake ? lidSession : caffSession

            // "Active" means the feature is providing protection right now.
            // For lid-awake we also accept the `SleepDisabled` indicator
            // (pmset's actual user-facing effect); the assertion agent
            // corroborates it.
            let active: Bool
            switch f {
            case .lidAwake:
                // pmset's `disablesleep` flag is the actual user-facing
                // effect; the assertion agent corroborates it.
                active = (power.sleepDisabled ?? false) && (agentRunning || sentinelExists)
            case .caffeinate:
                active = agentRunning && sentinelExists
            }

            return StatusReport.FeatureSnapshot(
                feature: f,
                active: active,
                agentRunning: agentRunning,
                session: session,
                lid: f == .lidAwake ? lidExtras : nil
            )
        }

        let helperApproved = Privilege.approvedHelperIsUsable()
        let installedHelperVersion: String? = {
            guard helperApproved else { return nil }
            let result = try? Shell.run(
                "/usr/bin/sudo",
                ["-n", VigilIdentifiers.privilegedHelperPath, "privileged-version"],
                requireSuccess: false
            )
            guard let r = result, r.status == 0 else { return nil }
            let trimmed = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let installedIPCContractVersion: Int? = {
            guard helperApproved else { return nil }
            let result = try? Shell.run(
                "/usr/bin/sudo",
                ["-n", VigilIdentifiers.privilegedHelperPath, "privileged-ipc-version"],
                requireSuccess: false
            )
            guard let r = result, r.status == 0 else { return nil }
            return Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }()

        return StatusReport(
            version: VigilVersion.value,
            power: .init(
                sleepDisabled: power.sleepDisabled,
                clamshellClosed: power.clamshellClosed,
                clamshellCausesSleep: power.clamshellCausesSleep
            ),
            battery: .init(
                source: battery.source,
                percent: batteryParts?.percent,
                state: batteryParts?.state
            ),
            displays: .init(count: displays.displayCount),
            keyboardBacklight: .init(
                apiAvailable: KeyboardBacklight.isAvailable(),
                brightness: KeyboardBacklight.capture()
            ),
            features: features,
            helper: .init(
                approved: helperApproved,
                installedVersion: installedHelperVersion,
                installedIPCContractVersion: installedIPCContractVersion,
                expectedIPCContractVersion: VigilIdentifiers.IPCContractVersion
            )
        )
    }

    static func printJSON(_ report: StatusReport) {
        guard let data = try? StatusReport.encoder.encode(report),
              let text = String(data: data, encoding: .utf8) else {
            fputs("Failed to encode status as JSON\n", stderr)
            return
        }
        print(text)
    }

    static func printHuman(_ report: StatusReport, verbose: Bool) {
        print("Vigil \(report.version)")
        print("")
        print("Power:")
        print("  SleepDisabled: \(report.power.sleepDisabled.map(Utility.formatBool) ?? "unknown")")
        print("  Lid closed: \(report.power.clamshellClosed.map(Utility.formatBool) ?? "unknown")")
        print("  Lid close causes sleep: \(report.power.clamshellCausesSleep.map(Utility.formatBool) ?? "unknown")")

        print("")
        for snapshot in report.features {
            print("\(snapshot.feature.displayName):")
            print("  Active: \(Utility.formatBool(snapshot.active))")
            print("  Agent running: \(Utility.formatBool(snapshot.agentRunning))")
            if let session = snapshot.session {
                print("  Enabled since: \(ISO8601DateFormatter().string(from: session.enabledAt))")
                print("  Duration: \(session.duration.displayName)")
                if let expiresAt = session.expiresAt {
                    print("  Expires at: \(ISO8601DateFormatter().string(from: expiresAt))")
                    if let remaining = session.remainingSeconds() {
                        print("  Remaining: \(remaining) seconds")
                    }
                }
            } else {
                print("  Enabled since: none")
            }
            if let lid = snapshot.lid {
                print("  Lid closed tracked seconds: \(lid.accumulatedClosedSeconds)")
                if let last = lid.lastClosedSeconds {
                    print("  Last lid closed seconds: \(last)")
                }
                if let since = lid.currentClosedSince {
                    print("  Current lid closed since: \(ISO8601DateFormatter().string(from: since))")
                }
            }
            print("")
        }

        print("Power source: \(report.battery.source)")
        if let percent = report.battery.percent {
            print("Battery: \(percent) \(report.battery.state ?? "")")
        }
        print("Detected displays: \(report.displays.count)")
        print("Keyboard backlight API: \(report.keyboardBacklight.apiAvailable ? "available" : "unavailable")")
        if let brightness = report.keyboardBacklight.brightness {
            print("Keyboard brightness: \(String(format: "%.3f", brightness))")
        }
        print("Approved helper: \(report.helper.approved ? "installed" : "not installed")")
        if let version = report.helper.installedVersion {
            print("Approved helper version: \(version)")
        }
        if let installed = report.helper.installedIPCContractVersion {
            print("IPC contract version: \(installed) (expected \(report.helper.expectedIPCContractVersion))")
            if !report.helper.contractMatches {
                print("  (contract version mismatch — re-approve to update sudoers rule)")
            }
        } else if report.helper.approved {
            print("IPC contract version: unknown (sudoers rule predates contract probe; re-approve to update)")
        }

        if verbose {
            print("")
            print("Power settings:")
            print((try? Shell.run("/usr/bin/pmset", ["-g"]).output) ?? "Unable to read pmset state.")

            print("")
            print("Power assertions:")
            print((try? Shell.run("/usr/bin/pmset", ["-g", "assertions"]).output) ?? "Unable to read assertions.")
        }
    }
}
