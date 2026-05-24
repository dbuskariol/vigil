import Foundation
import CoreGraphics
import IOKit.graphics
import IOKit.pwr_mgt
import KeyboardBacklightBridge
import VigilIdentifiers

@_silgen_name("CGDisplayIOServicePort")
func privateCGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

enum ExitCode: Int32 {
    case ok = 0
    case usage = 64
    case failure = 1
}

struct CommandResult {
    let status: Int32
    let output: String
}

struct StateFile: Codable {
    var createdAt: Date
    var sleepDisabled: Bool?
    var settings: [String: [String: Int]]
}

struct VisualStateFile: Codable {
    var createdAt: Date
    var displayBrightness: [String: Float]
    var keyboardBrightness: Float?
}

struct VisualOptions: Codable, Equatable {
    let dimDisplay: Bool
    let dimKeyboard: Bool

    static func fromCommandLine() -> VisualOptions {
        VisualOptions(
            dimDisplay: !CommandLine.arguments.contains("--no-dim-display"),
            dimKeyboard: !CommandLine.arguments.contains("--no-dim-keyboard")
        )
    }

    static func loadForAssertionAgent() -> VisualOptions {
        guard let data = try? Data(contentsOf: Paths.visualOptionsFile),
              let options = try? JSONDecoder().decode(VisualOptions.self, from: data) else {
            return fromCommandLine()
        }
        return options
    }
}

struct RuntimeStateFile: Codable {
    var enabledAt: Date
    var lidClosedAt: Date?
    var accumulatedLidClosedSeconds: TimeInterval
    var lastClosedSeconds: TimeInterval?
}

enum Paths {
    static let bundleIdentifier = VigilIdentifiers.bundleID
    static let label = VigilIdentifiers.assertionAgentLabel
    static let privilegedHelperPath = VigilIdentifiers.privilegedHelperPath

    static var sudoersPath: String { VigilIdentifiers.sudoersPath }

    static var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Vigil", isDirectory: true)
    }

    static var stateFile: URL {
        appSupportDirectory.appendingPathComponent("state.json")
    }

    static var visualStateFile: URL {
        appSupportDirectory.appendingPathComponent("visual-state.json")
    }

    static var visualOptionsFile: URL {
        appSupportDirectory.appendingPathComponent("visual-options.json")
    }

    static var runtimeStateFile: URL {
        appSupportDirectory.appendingPathComponent("runtime-state.json")
    }

    static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    static var launchAgentFile: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String], requireSuccess: Bool = true) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        let result = CommandResult(status: process.terminationStatus, output: output.trimmingCharacters(in: .whitespacesAndNewlines))

        if requireSuccess && result.status != 0 {
            throw RuntimeError.commandFailed("\(executable) \(arguments.joined(separator: " "))", result.output)
        }

        return result
    }
}

enum RuntimeError: Error, CustomStringConvertible {
    case commandFailed(String, String)
    case refused(String)
    case unknownCommand(String)

    var description: String {
        switch self {
        case let .commandFailed(command, output):
            return "Command failed: \(command)\n\(output)"
        case let .refused(message):
            return message
        case let .unknownCommand(command):
            return "Unknown command: \(command)"
        }
    }
}

struct PowerDomainState {
    let sleepDisabled: Bool?
    let clamshellClosed: Bool?
    let clamshellCausesSleep: Bool?

    static func load() -> PowerDomainState {
        let output = (try? Shell.run("/usr/sbin/ioreg", ["-r", "-k", "SleepDisabled", "-d", "1"]).output) ?? ""
        return PowerDomainState(
            sleepDisabled: boolValue(named: "SleepDisabled", in: output),
            clamshellClosed: boolValue(named: "AppleClamshellState", in: output),
            clamshellCausesSleep: boolValue(named: "AppleClamshellCausesSleep", in: output)
        )
    }

    private static func boolValue(named key: String, in text: String) -> Bool? {
        for line in text.split(separator: "\n") {
            let normalized = line.trimmingCharacters(in: .whitespaces)
            guard normalized.hasPrefix("\"\(key)\"") else { continue }
            if normalized.hasSuffix("Yes") { return true }
            if normalized.hasSuffix("No") { return false }
        }
        return nil
    }
}

enum PMSetSnapshot {
    static let argumentsChangedByEnable = ["sleep", "disksleep", "ttyskeepawake", "tcpkeepalive"]

    static let displayNameToArgument = [
        "System Sleep Timer": "sleep",
        "Disk Sleep Timer": "disksleep",
        "TTYSPreventSleep": "ttyskeepawake",
        "TCPKeepAlivePref": "tcpkeepalive"
    ]

    static let fallbackSettings = [
        "AC Power": ["sleep": 10, "disksleep": 10, "ttyskeepawake": 1, "tcpkeepalive": 1],
        "Battery Power": ["sleep": 1, "disksleep": 10, "ttyskeepawake": 1, "tcpkeepalive": 1]
    ]

    static func capture() -> [String: [String: Int]] {
        let output = (try? Shell.run("/usr/bin/pmset", ["-g", "custom"]).output) ?? ""
        var currentSection: String?
        var result: [String: [String: Int]] = [:]

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                currentSection = String(line.dropLast())
                if let currentSection {
                    result[currentSection, default: [:]] = [:]
                }
                continue
            }

            guard let currentSection else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2, argumentsChangedByEnable.contains(parts[0]), let value = Int(parts[1]) {
                result[currentSection, default: [:]][parts[0]] = value
                continue
            }

            for (displayName, argument) in displayNameToArgument where line.hasPrefix(displayName + " ") {
                let valueText = line.dropFirst(displayName.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Int(valueText.split(separator: " ").first ?? "") {
                    result[currentSection, default: [:]][argument] = value
                }
            }
        }

        return result
    }
}

struct BatteryState {
    let source: String
    let detail: String

    var isBatteryPower: Bool {
        source.localizedCaseInsensitiveContains("Battery Power")
    }

    static func load() -> BatteryState {
        let output = (try? Shell.run("/usr/bin/pmset", ["-g", "batt"]).output) ?? ""
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let source = lines.first.flatMap { line -> String? in
            guard let start = line.firstIndex(of: "'"), let end = line.lastIndex(of: "'"), start < end else { return nil }
            return String(line[line.index(after: start)..<end])
        } ?? "Unknown"
        let detail = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return BatteryState(source: source, detail: detail)
    }
}

struct DisplayState {
    let displayCount: Int
    let summary: String

    static func load() -> DisplayState {
        let output = (try? Shell.run("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-detailLevel", "mini"]).output) ?? ""
        let count = output.components(separatedBy: "Display Type:").count - 1
        return DisplayState(displayCount: max(0, count), summary: output)
    }
}

enum DisplayBrightness {
    static func capture() -> [String: Float] {
        onlineDisplays().reduce(into: [:]) { result, displayID in
            guard let brightness = brightness(for: displayID) else { return }
            result[String(displayID)] = brightness
        }
    }

    static func restore(_ values: [String: Float]) {
        for (displayID, brightness) in values {
            guard let rawID = UInt32(displayID) else { continue }
            set(displayID: CGDirectDisplayID(rawID), brightness: brightness)
        }
    }

    static func setAllOnlineDisplays(to brightness: Float) {
        for displayID in onlineDisplays() {
            set(displayID: displayID, brightness: brightness)
        }
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return []
        }

        return Array(displays.prefix(Int(count)))
    }

    private static func brightness(for displayID: CGDirectDisplayID) -> Float? {
        if let brightness = CoreDisplayBrightness.get(displayID: displayID) {
            return brightness
        }
        if let brightness = DisplayServicesBrightness.get(displayID: displayID) {
            return brightness
        }

        let service = privateCGDisplayIOServicePort(displayID)
        guard service != 0 else { return nil }
        var brightness: Float = 0
        let result = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
        return result == kIOReturnSuccess ? brightness : nil
    }

    private static func set(displayID: CGDirectDisplayID, brightness: Float) {
        if CoreDisplayBrightness.set(displayID: displayID, brightness: brightness) {
            return
        }
        if DisplayServicesBrightness.set(displayID: displayID, brightness: brightness) {
            return
        }

        let service = privateCGDisplayIOServicePort(displayID)
        guard service != 0 else { return }
        let clamped = min(1.0, max(0.0, brightness))
        _ = IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, clamped)
    }
}

enum CoreDisplayBrightness {
    typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Double>) -> Int32
    typealias SetFunction = @convention(c) (CGDirectDisplayID, Double) -> Int32

    private static let framework = dlopen("/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
    private static let getFunction: GetFunction? = load("CoreDisplay_Display_GetUserBrightness")
    private static let setFunction: SetFunction? = load("CoreDisplay_Display_SetUserBrightness")

    static func get(displayID: CGDirectDisplayID) -> Float? {
        guard let getFunction else { return nil }
        var value = 0.0
        let result = getFunction(displayID, &value)
        return result == 0 ? Float(value) : nil
    }

    static func set(displayID: CGDirectDisplayID, brightness: Float) -> Bool {
        guard let setFunction else { return false }
        let clamped = Double(min(1.0, max(0.0, brightness)))
        return setFunction(displayID, clamped) == 0
    }

    private static func load<T>(_ symbol: String) -> T? {
        guard let framework, let pointer = dlsym(framework, symbol) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

enum DisplayServicesBrightness {
    typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFunction: GetFunction? = load("DisplayServicesGetBrightness")
    private static let setFunction: SetFunction? = load("DisplayServicesSetBrightness")

    static func get(displayID: CGDirectDisplayID) -> Float? {
        guard let getFunction else { return nil }
        var value: Float = 0
        let result = getFunction(displayID, &value)
        return result == 0 ? value : nil
    }

    static func set(displayID: CGDirectDisplayID, brightness: Float) -> Bool {
        guard let setFunction else { return false }
        let clamped = min(1.0, max(0.0, brightness))
        return setFunction(displayID, clamped) == 0
    }

    private static func load<T>(_ symbol: String) -> T? {
        guard let framework, let pointer = dlsym(framework, symbol) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

enum KeyboardBacklight {
    static func capture() -> Float? {
        var value: Float = 0
        guard ANSKeyboardBacklightGetBrightness(&value) else { return nil }
        return value
    }

    static func set(_ brightness: Float) {
        _ = ANSKeyboardBacklightSetBrightness(min(1.0, max(0.0, brightness)))
    }
}

enum Vigil {
    static let usage = """
    vigil: keep a Mac laptop awake with the lid closed

    Usage:
      vigil on [--force-battery]
      vigil off
      vigil toggle [--force-battery]
      vigil status
      vigil doctor
      vigil approve-all
      vigil approval-status
      vigil --version

    Notes:
      on      snapshots current settings, applies an awake profile, and starts assertions
      off     stops assertions and restores the saved settings
      status  reads private IOPMrootDomain registry state, including SleepDisabled

    Keep the machine ventilated when the lid is closed. This setting persists until disabled.
    """

    static func main(arguments: [String]) -> ExitCode {
        guard arguments.first != "--help", arguments.first != "-h" else {
            print(usage)
            return .ok
        }

        if arguments.first == "--version" || arguments.first == "version" {
            print(VigilVersion.value)
            return .ok
        }

        do {
            switch arguments.first ?? "status" {
            case "on":
                try enable(forceBattery: arguments.contains("--force-battery"))
            case "off":
                try disable()
            case "toggle":
                try toggle(forceBattery: arguments.contains("--force-battery"))
            case "status":
                printStatus(verbose: false)
            case "doctor":
                printStatus(verbose: true)
            case "hold":
                holdAssertions()
            case "approve-all":
                try installApprovedHelper()
            case "approval-status":
                printApprovalStatus()
            case "privileged-pmset-batch":
                try runRootPMSetBatch(from: arguments.dropFirst().first)
            case "privileged-version":
                printPrivilegedVersion()
            default:
                throw RuntimeError.unknownCommand(arguments.first ?? "")
            }
            return .ok
        } catch {
            fputs("\(error)\n", stderr)
            return error is RuntimeError ? .failure : .usage
        }
    }

    static func enable(forceBattery: Bool) throws {
        let battery = BatteryState.load()
        if battery.isBatteryPower && !forceBattery {
            throw RuntimeError.refused("""
            Refusing to enable while on battery power.
            Power source: \(battery.source)
            Re-run with --force-battery if you really want that.
            """)
        }

        try saveStateIfNeeded()
        try saveVisualStateIfNeeded()

        print("Enabling closed-lid full-awake profile.")
        try runPrivilegedPMSetBatch([
            ["-a", "disablesleep", "1", "sleep", "0", "disksleep", "0", "ttyskeepawake", "1", "tcpkeepalive", "1"]
        ])
        try installAssertionAgent(options: VisualOptions.fromCommandLine())
        try saveInitialRuntimeState()
        waitForAssertionAgentStartup()

        print("SleepDisabled is now \(PowerDomainState.load().sleepDisabled.map(formatBool) ?? "unknown").")
        print("Assertion agent is \(assertionAgentIsRunning() ? "running" : "not running").")
        print("Disable with: vigil off")
    }

    static func disable() throws {
        print("Disabling closed-lid full-awake profile.")
        try restoreVisualState(removeSnapshot: true)
        try? FileManager.default.removeItem(at: Paths.runtimeStateFile)
        try uninstallAssertionAgent()
        try restoreState()
        print("SleepDisabled is now \(PowerDomainState.load().sleepDisabled.map(formatBool) ?? "unknown").")
        print("Assertion agent is \(assertionAgentIsRunning() ? "running" : "not running").")
    }

    static func toggle(forceBattery: Bool) throws {
        let enabled = PowerDomainState.load().sleepDisabled ?? false
        if enabled {
            try disable()
        } else {
            try enable(forceBattery: forceBattery)
        }
    }

    static func printStatus(verbose: Bool) {
        let power = PowerDomainState.load()
        let battery = BatteryState.load()
        let displays = DisplayState.load()

        print("SleepDisabled: \(power.sleepDisabled.map(formatBool) ?? "unknown")")
        print("Lid closed: \(power.clamshellClosed.map(formatBool) ?? "unknown")")
        print("Lid close causes sleep: \(power.clamshellCausesSleep.map(formatBool) ?? "unknown")")
        print("Assertion agent: \(assertionAgentIsRunning() ? "running" : "stopped")")
        print("Saved restore state: \(FileManager.default.fileExists(atPath: Paths.stateFile.path) ? Paths.stateFile.path : "none")")
        print("Saved visual state: \(FileManager.default.fileExists(atPath: Paths.visualStateFile.path) ? Paths.visualStateFile.path : "none")")
        printRuntimeState()
        print("Keyboard backlight API: \(ANSKeyboardBacklightIsAvailable() ? "available" : "unavailable")")
        print("Keyboard brightness: \(KeyboardBacklight.capture().map { String(format: "%.3f", $0) } ?? "unknown")")
        print("Power source: \(battery.source)")
        if !battery.detail.isEmpty {
            print(battery.detail)
        }
        print("Detected displays: \(displays.displayCount)")

        if verbose {
            print("\nPower settings:")
            print((try? Shell.run("/usr/bin/pmset", ["-g"]).output) ?? "Unable to read pmset state.")

            print("\nPower assertions:")
            print((try? Shell.run("/usr/bin/pmset", ["-g", "assertions"]).output) ?? "Unable to read assertions.")

            print("\nDisplay summary:")
            print(displays.summary)
        }
    }

    static func saveStateIfNeeded() throws {
        if FileManager.default.fileExists(atPath: Paths.stateFile.path) {
            return
        }

        try FileManager.default.createDirectory(at: Paths.appSupportDirectory, withIntermediateDirectories: true)
        let state = StateFile(
            createdAt: Date(),
            sleepDisabled: PowerDomainState.load().sleepDisabled,
            settings: PMSetSnapshot.capture()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: Paths.stateFile, options: .atomic)
    }

    static func saveVisualStateIfNeeded() throws {
        if FileManager.default.fileExists(atPath: Paths.visualStateFile.path) {
            return
        }

        try FileManager.default.createDirectory(at: Paths.appSupportDirectory, withIntermediateDirectories: true)
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

    static func saveInitialRuntimeState() throws {
        try FileManager.default.createDirectory(at: Paths.appSupportDirectory, withIntermediateDirectories: true)
        let state = RuntimeStateFile(enabledAt: Date(), lidClosedAt: nil, accumulatedLidClosedSeconds: 0, lastClosedSeconds: nil)
        try writeRuntimeState(state)
    }

    static func readRuntimeState() -> RuntimeStateFile? {
        guard FileManager.default.fileExists(atPath: Paths.runtimeStateFile.path),
              let data = try? Data(contentsOf: Paths.runtimeStateFile) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RuntimeStateFile.self, from: data)
    }

    static func writeRuntimeState(_ state: RuntimeStateFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: Paths.runtimeStateFile, options: .atomic)
    }

    static func printRuntimeState() {
        guard let state = readRuntimeState() else {
            print("Enabled since: none")
            print("Lid closed tracked seconds: 0")
            print("Last lid closed seconds: none")
            return
        }

        let now = Date()
        let currentClosed = state.lidClosedAt.map { now.timeIntervalSince($0) } ?? 0
        print("Enabled since: \(ISO8601DateFormatter().string(from: state.enabledAt))")
        print("Lid closed tracked seconds: \(Int(state.accumulatedLidClosedSeconds + currentClosed))")
        if let lastClosedSeconds = state.lastClosedSeconds {
            print("Last lid closed seconds: \(Int(lastClosedSeconds))")
        } else {
            print("Last lid closed seconds: none")
        }
        if let lidClosedAt = state.lidClosedAt {
            print("Current lid closed since: \(ISO8601DateFormatter().string(from: lidClosedAt))")
        } else {
            print("Current lid closed since: none")
        }
    }

    static func restoreState() throws {
        guard FileManager.default.fileExists(atPath: Paths.stateFile.path) else {
            try runPrivilegedPMSetBatch(
                [["-a", "disablesleep", "0"]] + restorePowerSettingCommands(PMSetSnapshot.fallbackSettings)
            )
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(StateFile.self, from: Data(contentsOf: Paths.stateFile))

        try runPrivilegedPMSetBatch(
            [["-a", "disablesleep", (state.sleepDisabled == true ? "1" : "0")]] + restorePowerSettingCommands(state.settings)
        )

        try? FileManager.default.removeItem(at: Paths.stateFile)
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

    static func installAssertionAgent(options: VisualOptions) throws {
        try FileManager.default.createDirectory(at: Paths.launchAgentsDirectory, withIntermediateDirectories: true)
        try saveVisualOptions(options)
        let executable = assertionAgentExecutablePath()
        let escapedExecutable = xmlEscape(executable)
        let escapedRuntimeState = xmlEscape(Paths.runtimeStateFile.path)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Paths.label)</string>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>\(Paths.bundleIdentifier)</string>
            </array>
            <key>ProgramArguments</key>
            <array>
                <string>\(escapedExecutable)</string>
                <string>hold</string>
            </array>
            <key>RunAtLoad</key>
            <false/>
            <key>KeepAlive</key>
            <dict>
                <key>PathState</key>
                <dict>
                    <key>\(escapedRuntimeState)</key>
                    <true/>
                </dict>
            </dict>
            <key>StandardOutPath</key>
            <string>/tmp/\(Paths.label).out.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/\(Paths.label).err.log</string>
        </dict>
        </plist>
        """

        let domain = "gui/\(getuid())"
        let existingPlist = try? String(contentsOf: Paths.launchAgentFile, encoding: .utf8)
        let plistChanged = existingPlist != plist
        if plistChanged {
            try plist.write(to: Paths.launchAgentFile, atomically: true, encoding: .utf8)
        }

        let registered = assertionAgentIsRegistered()
        if !registered {
            _ = try Shell.run("/bin/launchctl", ["bootstrap", domain, Paths.launchAgentFile.path])
        } else if plistChanged {
            _ = try? Shell.run("/bin/launchctl", ["bootout", domain, Paths.launchAgentFile.path], requireSuccess: false)
            _ = try Shell.run("/bin/launchctl", ["bootstrap", domain, Paths.launchAgentFile.path])
        }
    }

    static func saveVisualOptions(_ options: VisualOptions) throws {
        try FileManager.default.createDirectory(at: Paths.appSupportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(options).write(to: Paths.visualOptionsFile, options: .atomic)
    }

    static func assertionAgentExecutablePath() -> String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    static func uninstallAssertionAgent() throws {
        let domain = "gui/\(getuid())"
        _ = try? Shell.run("/bin/launchctl", ["kill", "TERM", "\(domain)/\(Paths.label)"], requireSuccess: false)
    }

    static func assertionAgentIsRunning() -> Bool {
        guard let result = try? Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(Paths.label)"], requireSuccess: false),
              result.status == 0 else {
            return false
        }
        return result.output.contains("state = running") || result.output.contains("pid = ")
    }

    static func assertionAgentIsRegistered() -> Bool {
        let result = try? Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(Paths.label)"], requireSuccess: false)
        return result?.status == 0
    }

    static func waitForAssertionAgentStartup(timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if assertionAgentIsRunning() {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    static func runPrivilegedPMSetBatch(_ commands: [[String]]) throws {
        guard !commands.isEmpty else { return }

        if getuid() == 0 {
            for arguments in commands {
                _ = try Shell.run("/usr/bin/pmset", arguments)
            }
        } else if useAdminPrompt {
            let script = (["set -e"] + commands.map { arguments in
                shellQuote("/usr/bin/pmset") + " " + arguments.map(shellQuote).joined(separator: " ")
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

    static var useAdminPrompt: Bool {
        CommandLine.arguments.contains("--admin-prompt")
    }

    static var useApprovedHelper: Bool {
        CommandLine.arguments.contains("--approved-helper") && approvedHelperIsUsable()
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
                throw RuntimeError.commandFailed("privileged-pmset-batch", "Rejected pmset arguments: \(arguments.joined(separator: " "))")
            }
            _ = try Shell.run("/usr/bin/pmset", arguments)
        }
    }

    static func runApprovedHelperPMSetBatch(_ commands: [[String]]) throws {
        let data = try JSONSerialization.data(withJSONObject: commands)
        let encoded = data.base64EncodedString()
        _ = try Shell.run("/usr/bin/sudo", ["-n", Paths.privilegedHelperPath, "privileged-pmset-batch", encoded])
    }

    static func approvedHelperIsUsable() -> Bool {
        FileManager.default.isExecutableFile(atPath: Paths.privilegedHelperPath)
            && (try? Shell.run("/usr/bin/sudo", ["-n", Paths.privilegedHelperPath, "approval-status"], requireSuccess: false).status) == 0
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

        let user = NSUserName()
        let sudoersLine = "\(user) ALL=(root) NOPASSWD: \(Paths.privilegedHelperPath) privileged-pmset-batch *, \(Paths.privilegedHelperPath) approval-status, \(Paths.privilegedHelperPath) privileged-version"
        let script = """
        set -e
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        install -o root -g wheel -m 755 \(shellQuote(currentExecutablePath())) \(shellQuote(Paths.privilegedHelperPath))
        umask 022
        printf '%s\\n' \(shellQuote(sudoersLine)) > \(shellQuote(Paths.sudoersPath))
        chown root:wheel \(shellQuote(Paths.sudoersPath))
        chmod 0440 \(shellQuote(Paths.sudoersPath))
        /usr/sbin/visudo -cf \(shellQuote(Paths.sudoersPath))
        """

        try runPrivilegedShellCommand(script)
        print("Approved helper: installed")
    }

    static func printPrivilegedVersion() {
        print(VigilVersion.value)
    }

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

    static func runPrivilegedShellCommand(_ command: String) throws {
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        _ = try Shell.run("/usr/bin/osascript", ["-e", script])
    }

    static func holdAssertions() -> Never {
        let assertions: [(CFString, String)] = [
            (kIOPMAssertionTypePreventSystemSleep as CFString, "Vigil: prevent system sleep"),
            (kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, "Vigil: prevent idle system sleep"),
            (kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, "Vigil: prevent idle display sleep")
        ]

        for (type, name) in assertions {
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &assertionID)
            if result != kIOReturnSuccess {
                fputs("Failed to create assertion \(name): \(result)\n", stderr)
            }
        }

        var lastLidState = PowerDomainState.load().clamshellClosed
        let visualOptions = VisualOptions.loadForAssertionAgent()

        if lastLidState == true {
            markLidClosed()
            try? dimVisualsForClosedLid(options: visualOptions)
        }

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let lidClosed = PowerDomainState.load().clamshellClosed
            guard lidClosed != lastLidState else { return }
            lastLidState = lidClosed

            if lidClosed == true {
                markLidClosed()
                try? dimVisualsForClosedLid(options: visualOptions)
            } else if lidClosed == false {
                markLidOpened()
                try? restoreVisualState(removeSnapshot: false)
            }
        }

        let restoreOnExit: @convention(c) (Int32) -> Void = { _ in
            try? Vigil.restoreVisualState(removeSnapshot: false)
            Foundation.exit(0)
        }
        signal(SIGTERM, restoreOnExit)
        signal(SIGINT, restoreOnExit)

        RunLoop.main.run()
        fatalError("RunLoop returned unexpectedly")
    }

    static func dimVisualsForClosedLid(options: VisualOptions) throws {
        try saveVisualStateIfNeeded()
        if options.dimDisplay {
            DisplayBrightness.setAllOnlineDisplays(to: 0.0)
        }
        if options.dimKeyboard {
            KeyboardBacklight.set(0.0)
        }
    }

    static func markLidClosed() {
        var state = readRuntimeState() ?? RuntimeStateFile(enabledAt: Date(), lidClosedAt: nil, accumulatedLidClosedSeconds: 0, lastClosedSeconds: nil)
        if state.lidClosedAt == nil {
            state.lidClosedAt = Date()
            try? writeRuntimeState(state)
        }
    }

    static func markLidOpened() {
        guard var state = readRuntimeState(), let closedAt = state.lidClosedAt else { return }
        let closedDuration = Date().timeIntervalSince(closedAt)
        state.accumulatedLidClosedSeconds += closedDuration
        state.lastClosedSeconds = closedDuration
        state.lidClosedAt = nil
        try? writeRuntimeState(state)
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

    static func formatBool(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func currentExecutablePath() -> String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }
}

exit(Vigil.main(arguments: Array(CommandLine.arguments.dropFirst())).rawValue)
