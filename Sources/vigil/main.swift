import Foundation
import VigilCore
import VigilIdentifiers

let usage = """
vigil: keep a Mac awake on demand

Usage:
  vigil status [--json]
  vigil doctor
  vigil lid-awake on [--duration <preset>] [--force-battery] [--no-dim-display] [--no-dim-keyboard]
  vigil lid-awake off
  vigil lid-awake toggle [--duration <preset>] [--force-battery]
  vigil caffeinate on [--duration <preset>] [--force-battery]
  vigil caffeinate off
  vigil caffeinate toggle [--duration <preset>]
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
    let verb = arguments.first ?? "status"
    let rest = Array(arguments.dropFirst())
    let duration = parseDuration(rest)
    let forceBattery = rest.contains("--force-battery")

    switch verb {
    case "on":
        try LidAwakeController.enable(duration: duration, forceBattery: forceBattery)
    case "off":
        try LidAwakeController.disable()
    case "toggle":
        try LidAwakeController.toggle(duration: duration, forceBattery: forceBattery)
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
    let verb = arguments.first ?? "status"
    let rest = Array(arguments.dropFirst())
    let duration = parseDuration(rest)
    let forceBattery = rest.contains("--force-battery")

    switch verb {
    case "on":
        try CaffeinateController.enable(duration: duration, forceBattery: forceBattery)
    case "off":
        try CaffeinateController.disable()
    case "toggle":
        try CaffeinateController.toggle(duration: duration, forceBattery: forceBattery)
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
    guard let featureName = arguments.first,
          let feature = Feature(rawValue: featureName) else {
        throw RuntimeError.unknownCommand("hold \(arguments.first ?? "")")
    }
    HoldEngine.run(feature: feature)
}

// MARK: - Duration parsing

func parseDuration(_ arguments: [String]) -> Duration {
    guard let index = arguments.firstIndex(of: "--duration"),
          index + 1 < arguments.count,
          let parsed = Duration(rawValue: arguments[index + 1]) else {
        return .indefinite
    }
    return parsed
}

exit(dispatch(Array(CommandLine.arguments.dropFirst())).rawValue)
