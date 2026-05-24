import Foundation

/// Canonical machine-readable status snapshot emitted by `vigil status --json`.
///
/// The menu app decodes this directly instead of screen-scraping the human
/// `vigil status` output. `schemaVersion` is incremented on any breaking
/// change to the field shape; consumers can refuse to render a status from a
/// newer schemaVersion than they understand.
public struct StatusReport: Codable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let power: PowerSnapshot
    public let battery: BatterySnapshot
    public let displays: DisplaySnapshot
    public let keyboardBacklight: KeyboardBacklightSnapshot
    public let features: [FeatureSnapshot]
    public let helper: HelperSnapshot

    public static let currentSchemaVersion = 1

    public init(
        version: String,
        power: PowerSnapshot,
        battery: BatterySnapshot,
        displays: DisplaySnapshot,
        keyboardBacklight: KeyboardBacklightSnapshot,
        features: [FeatureSnapshot],
        helper: HelperSnapshot
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.version = version
        self.power = power
        self.battery = battery
        self.displays = displays
        self.keyboardBacklight = keyboardBacklight
        self.features = features
        self.helper = helper
    }

    public struct PowerSnapshot: Codable, Sendable {
        public let sleepDisabled: Bool?
        public let clamshellClosed: Bool?
        public let clamshellCausesSleep: Bool?
        public init(sleepDisabled: Bool?, clamshellClosed: Bool?, clamshellCausesSleep: Bool?) {
            self.sleepDisabled = sleepDisabled
            self.clamshellClosed = clamshellClosed
            self.clamshellCausesSleep = clamshellCausesSleep
        }
    }

    public struct BatterySnapshot: Codable, Sendable {
        public let source: String
        public let percent: String?
        public let state: String?
        public init(source: String, percent: String?, state: String?) {
            self.source = source
            self.percent = percent
            self.state = state
        }
        public var isBatteryPower: Bool {
            source.localizedCaseInsensitiveContains("Battery Power")
        }
    }

    public struct DisplaySnapshot: Codable, Sendable {
        public let count: Int
        public init(count: Int) { self.count = count }
    }

    public struct KeyboardBacklightSnapshot: Codable, Sendable {
        public let apiAvailable: Bool
        public let brightness: Float?
        public init(apiAvailable: Bool, brightness: Float?) {
            self.apiAvailable = apiAvailable
            self.brightness = brightness
        }
    }

    public struct FeatureSnapshot: Codable, Identifiable, Sendable {
        public var id: Feature { feature }
        public let feature: Feature
        public let active: Bool
        public let agentRunning: Bool
        public let session: FeatureSession?
        public let lid: LidExtras?

        public init(feature: Feature, active: Bool, agentRunning: Bool, session: FeatureSession?, lid: LidExtras?) {
            self.feature = feature
            self.active = active
            self.agentRunning = agentRunning
            self.session = session
            self.lid = lid
        }

        public struct LidExtras: Codable, Sendable {
            public let currentClosedSince: Date?
            public let lastClosedSeconds: Int?
            public let accumulatedClosedSeconds: Int
            public init(currentClosedSince: Date?, lastClosedSeconds: Int?, accumulatedClosedSeconds: Int) {
                self.currentClosedSince = currentClosedSince
                self.lastClosedSeconds = lastClosedSeconds
                self.accumulatedClosedSeconds = accumulatedClosedSeconds
            }
        }
    }

    public struct HelperSnapshot: Codable, Sendable {
        public let approved: Bool
        public let installedVersion: String?
        public init(approved: Bool, installedVersion: String?) {
            self.approved = approved
            self.installedVersion = installedVersion
        }
    }
}

extension StatusReport {
    public static var encoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    public static var decoder: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
