import Foundation
import VigilCore
import VigilIdentifiers

let usage = """
vigil: keep a Mac awake on demand

Usage:
  vigil status [--json]
  vigil doctor
  vigil lid-awake on [--duration <preset>] [--force-battery] [--battery-floor <int>] [--no-dim-display] [--no-dim-keyboard]
  vigil lid-awake off
  vigil lid-awake toggle [--duration <preset>] [--force-battery] [--battery-floor <int>]
  vigil caffeinate on [--duration <preset>] [--force-battery] [--battery-floor <int>]
  vigil caffeinate off
  vigil caffeinate toggle [--duration <preset>] [--battery-floor <int>]
  vigil approve-all
  vigil approval-status
  vigil --version

Durations:
  <preset> is one of: indefinite | 5m | 10m | 15m | 30m | 1h | 2h | 5h
  Default: indefinite. When a timed session reaches its deadline the feature
  auto-disables and the system returns to its previous behaviour.

Features:
  lid-awake     applies a reversible pmset profile (disablesleep=1, sleep=0,
                disksleep=0, ttyskeepawake=1, tcpkeepalive=1) AND holds three
                IOKit power assertions, keeping a Mac fully awake with the lid
                closed. Refuses battery without --force-battery. Requires
                administrator approval (one-time, via `vigil approve-all`).

  caffeinate    holds two IOKit power assertions (idle system sleep + idle
                display sleep). No pmset, no root, no privileged helper.
                Manual Apple-menu Sleep and lid close still send the machine
                to sleep.

Notes:
  Both features survive `vigil` exit and menu-app quit because the assertions
  are held by a per-feature launchd user agent. Keep the machine ventilated
  when running with the lid closed.

  --battery-floor <int>  (1..99): on battery power, the hold agent disables
                         the feature once the battery drops to this
                         percentage and (for lid-awake) restores the saved
                         pmset profile, so the Mac can sleep normally
                         instead of running flat. Lid-awake requires
                         Approve All; caffeinate does not. AC restored
                         later does NOT re-arm the session.
"""

func dispatch(_ arguments: [String]) -> ExitCode {
    if arguments.first == "--help" || arguments.first == "-h" {
        print(usage)
        return .ok
    }
    if arguments.first == "--version" || arguments.first == "version" {
        print(VigilVersion.value)
        return .ok
    }

    // Hold and privileged-* invocations skip any user-facing setup and go
    // straight through the dispatch — they run inside long-lived agent or
    // sudo contexts.

    do {
        switch arguments.first ?? "status" {
        case "status":
            let report = Status.build()
            if Array(arguments.dropFirst()).contains("--json") {
                Status.printJSON(report)
            } else {
                Status.printHuman(report, verbose: false)
            }

        case "doctor":
            // Doctor emits JSON for machine consumers (the menu-app's
            // clipboard-copy diagnostics flow), then a human summary.
            let report = Status.build()
            Status.printJSON(report)
            print("")
            Status.printHuman(report, verbose: true)

        case "lid-awake":
            try runLidAwake(Array(arguments.dropFirst()))

        case "caffeinate":
            try runCaffeinate(Array(arguments.dropFirst()))

        case "hold":
            try runHold(Array(arguments.dropFirst()))

        case "approve-all":
            try Privilege.installApprovedHelper()

        case "approval-status":
            Privilege.printApprovalStatus()

        case "privileged-pmset-batch":
            try Privilege.runRootPMSetBatch(from: arguments.dropFirst().first)

        case "privileged-version":
            Privilege.printPrivilegedVersion()

        case "privileged-ipc-version":
            Privilege.printPrivilegedIPCContractVersion()

        default:
            throw RuntimeError.unknownCommand(arguments.first ?? "")
        }
        return .ok
    } catch {
        fputs("\(error)\n", stderr)
        return error is RuntimeError ? .failure : .usage
    }
}

// MARK: - Feature subcommand handlers

func runLidAwake(_ arguments: [String]) throws {
    let verb = firstNonFlag(arguments) ?? "status"
    let rest = arguments.filter { $0 != verb }
    let duration = parseDuration(rest)
    let forceBattery = rest.contains("--force-battery")
    let batteryFloor = try parseBatteryFloor(rest)
    let isRearm = rest.contains("--rearm")

    switch verb {
    case "on":
        try LidAwakeController.enable(
            duration: duration,
            forceBattery: forceBattery,
            batteryFloorPercent: batteryFloor,
            isRearm: isRearm
        )
    case "off":
        try LidAwakeController.disable()
    case "toggle":
        try LidAwakeController.toggle(
            duration: duration,
            forceBattery: forceBattery,
            batteryFloorPercent: batteryFloor
        )
    case "status":
        let report = Status.build()
        if rest.contains("--json") {
            Status.printJSON(report)
        } else {
            Status.printHuman(report, verbose: false)
        }
    default:
        throw RuntimeError.unknownCommand("lid-awake \(verb)")
    }
}

func runCaffeinate(_ arguments: [String]) throws {
    let verb = firstNonFlag(arguments) ?? "status"
    let rest = arguments.filter { $0 != verb }
    let duration = parseDuration(rest)
    let forceBattery = rest.contains("--force-battery")
    let batteryFloor = try parseBatteryFloor(rest)
    let isRearm = rest.contains("--rearm")

    switch verb {
    case "on":
        try CaffeinateController.enable(
            duration: duration,
            forceBattery: forceBattery,
            batteryFloorPercent: batteryFloor,
            isRearm: isRearm
        )
    case "off":
        try CaffeinateController.disable()
    case "toggle":
        try CaffeinateController.toggle(
            duration: duration,
            forceBattery: forceBattery,
            batteryFloorPercent: batteryFloor
        )
    case "status":
        let report = Status.build()
        if rest.contains("--json") {
            Status.printJSON(report)
        } else {
            Status.printHuman(report, verbose: false)
        }
    default:
        throw RuntimeError.unknownCommand("caffeinate \(verb)")
    }
}

func runHold(_ arguments: [String]) throws {
    guard let featureName = firstNonFlag(arguments),
          let feature = Feature(rawValue: featureName) else {
        throw RuntimeError.unknownCommand("hold \(arguments.first ?? "")")
    }
    HoldEngine.run(feature: feature)
}

// MARK: - Argument parsing helpers

/// Find the first argument that is not a `--flag`. The verb-vs-flag
/// distinction is positional in spirit but we don't enforce ordering —
/// privilege flags (`--approved-helper`, `--admin-prompt`) and the like
/// are read globally via `CommandLine.arguments.contains(...)` and can
/// appear anywhere.
private func firstNonFlag(_ arguments: [String]) -> String? {
    arguments.first { !$0.hasPrefix("--") }
}

func parseDuration(_ arguments: [String]) -> Duration {
    guard let index = arguments.firstIndex(of: "--duration"),
          index + 1 < arguments.count,
          let parsed = Duration(rawValue: arguments[index + 1]) else {
        return .indefinite
    }
    return parsed
}

/// Parse `--battery-floor <int>` from the argument vector. Returns `nil`
/// when the flag is absent. Throws when the value is missing or out of
/// the `1...99` range — `0` and `100` are degenerate (never trip / always
/// trip) and rejected loudly rather than silently.
func parseBatteryFloor(_ arguments: [String]) throws -> Int? {
    guard let index = arguments.firstIndex(of: "--battery-floor") else {
        return nil
    }
    guard index + 1 < arguments.count else {
        throw RuntimeError.refused("--battery-floor requires an integer value in the range 1..99.")
    }
    let raw = arguments[index + 1]
    guard let value = Int(raw) else {
        throw RuntimeError.refused("--battery-floor value '\(raw)' is not an integer.")
    }
    guard (1...99).contains(value) else {
        throw RuntimeError.refused("--battery-floor must be between 1 and 99 (got \(value)).")
    }
    return value
}

exit(dispatch(Array(CommandLine.arguments.dropFirst())).rawValue)
