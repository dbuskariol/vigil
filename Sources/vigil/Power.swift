import Foundation
import CoreGraphics
import IOKit.graphics
import IOKit.pwr_mgt
import KeyboardBacklightBridge

@_silgen_name("CGDisplayIOServicePort")
func privateCGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

// MARK: - Power-domain registry state

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

// MARK: - pmset snapshot capture

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

// MARK: - Battery / displays

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

    /// Parses a `-InternalBattery-` line and returns (percent, state).
    static func parseInternalBattery(_ line: String) -> (percent: String, state: String) {
        let parts = line.split(separator: "\t").map { String($0) }
        guard let details = parts.last else { return ("Unknown", "Unknown") }
        let clean = details.replacingOccurrences(of: " present: true", with: "")
        let pieces = clean
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (pieces.first ?? "Unknown", pieces.dropFirst().first ?? "Unknown")
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

// MARK: - Display brightness (CoreDisplay / DisplayServices / IOKit fallback)

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

// MARK: - Keyboard backlight

enum KeyboardBacklight {
    static func capture() -> Float? {
        var value: Float = 0
        guard ANSKeyboardBacklightGetBrightness(&value) else { return nil }
        return value
    }

    static func isAvailable() -> Bool {
        ANSKeyboardBacklightIsAvailable()
    }

    static func set(_ brightness: Float) {
        _ = ANSKeyboardBacklightSetBrightness(min(1.0, max(0.0, brightness)))
    }
}
