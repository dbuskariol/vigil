import AppKit
import Combine
import Sparkle
import SwiftUI
import VigilIdentifiers

struct HelperStatus {
    var sleepDisabled = false
    var assertionAgentRunning = false
    var lidClosed: String = "unknown"
    var powerSource: String = "Unknown"
    var batteryPercent = "Unknown"
    var batteryState = "Unknown"
    var detectedDisplays: String = "0"
    var keyboardBacklightAPI = "unknown"
    var enabledSince: Date?
    var currentLidClosedSince: Date?
    var lastLidClosedSeconds: Int?
    var lidClosedTrackedSeconds = 0

    var isEnabled: Bool {
        sleepDisabled && assertionAgentRunning
    }

    var isBatteryPower: Bool {
        powerSource.localizedCaseInsensitiveContains("Battery Power")
    }

    var lidStateLabel: String {
        switch lidClosed.lowercased() {
        case "yes": "Closed"
        case "no": "Open"
        default: "Unknown"
        }
    }

    var keyboardBacklightLabel: String {
        keyboardBacklightAPI == "available" ? "Available" : "Unavailable"
    }

    var displayLabel: String {
        detectedDisplays == "1" ? "1 Display" : "\(detectedDisplays) Displays"
    }

    var agentLabel: String {
        assertionAgentRunning ? "Running" : "Stopped"
    }

    static func parse(_ output: String) -> HelperStatus {
        var status = HelperStatus()
        let dateFormatter = ISO8601DateFormatter()
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("SleepDisabled:") {
                status.sleepDisabled = line.localizedCaseInsensitiveContains("yes")
            } else if line.hasPrefix("Lid closed:") {
                status.lidClosed = value(after: "Lid closed:", in: line)
            } else if line.hasPrefix("Assertion agent:") {
                status.assertionAgentRunning = line.localizedCaseInsensitiveContains("running")
            } else if line.hasPrefix("Enabled since:") {
                let rawValue = value(after: "Enabled since:", in: line)
                status.enabledSince = rawValue == "none" ? nil : dateFormatter.date(from: rawValue)
            } else if line.hasPrefix("Lid closed tracked seconds:") {
                status.lidClosedTrackedSeconds = Int(value(after: "Lid closed tracked seconds:", in: line)) ?? 0
            } else if line.hasPrefix("Last lid closed seconds:") {
                let rawValue = value(after: "Last lid closed seconds:", in: line)
                status.lastLidClosedSeconds = rawValue == "none" ? nil : Int(rawValue)
            } else if line.hasPrefix("Current lid closed since:") {
                let rawValue = value(after: "Current lid closed since:", in: line)
                status.currentLidClosedSince = rawValue == "none" ? nil : dateFormatter.date(from: rawValue)
            } else if line.hasPrefix("Keyboard backlight API:") {
                status.keyboardBacklightAPI = value(after: "Keyboard backlight API:", in: line)
            } else if line.hasPrefix("Power source:") {
                status.powerSource = value(after: "Power source:", in: line)
            } else if line.hasPrefix("-InternalBattery-") {
                let battery = parseBattery(line)
                status.batteryPercent = battery.percent
                status.batteryState = battery.state
            } else if line.hasPrefix("Detected displays:") {
                status.detectedDisplays = value(after: "Detected displays:", in: line)
            }
        }
        return status
    }

    private static func value(after prefix: String, in line: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseBattery(_ line: String) -> (percent: String, state: String) {
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

struct HelperResult {
    var status: Int32
    var output: String
}

@MainActor
final class UpdateController: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController?
    private let sparkleDelegate: SparkleDelegate?

    init() {
        guard Self.configurationIsPresent else {
            updaterController = nil
            sparkleDelegate = nil
            return
        }

        let delegate = SparkleDelegate()
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        sparkleDelegate = delegate
        updaterController = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    var isConfigured: Bool {
        updaterController != nil
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    private static var configurationIsPresent: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return URL(string: feedURL)?.scheme == "https" && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

final class SparkleDelegate: NSObject, SPUUpdaterDelegate {
    // Sparkle quits the menu app, replaces the .app bundle, and relaunches.
    // The LaunchAgent is a separate launchd-managed process that holds a file
    // handle on the old vigil CLI Mach-O. Bootout before the swap so the
    // post-relaunch path can re-bootstrap with the new binary's plist template.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let domain = "gui/\(getuid())"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "\(domain)/\(VigilIdentifiers.assertionAgentLabel)"]
        try? task.run()
        task.waitUntilExit()
    }
}

enum Helper {
    static let approvedHelperArgument = "--approved-helper"
    static let adminPromptArgument = "--admin-prompt"

    static var executablePath: String {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("vigil"),
           FileManager.default.isExecutableFile(atPath: resourceURL.path) {
            return resourceURL.path
        }

        let localBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/release/vigil")
        if FileManager.default.isExecutableFile(atPath: localBuild.path) {
            return localBuild.path
        }

        return "/usr/local/bin/vigil"
    }

    static func run(_ arguments: [String]) async -> HelperResult {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                return HelperResult(status: process.terminationStatus, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                return HelperResult(status: 1, output: error.localizedDescription)
            }
        }.value
    }
}

enum ApprovedHelperInstaller {
    static let privilegedHelperPath = VigilIdentifiers.privilegedHelperPath

    static var sudoersPath: String { VigilIdentifiers.sudoersPath }

    static func install(helperPath: String) async -> HelperResult {
        await Task.detached {
            runPrivileged(script: installScript(helperPath: helperPath), successMessage: "Approved helper: installed")
        }.value
    }

    static func revoke() async -> HelperResult {
        await Task.detached {
            runPrivileged(script: revokeScript(), successMessage: "Approved helper: removed")
        }.value
    }

    static func installedHelperVersion() async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", privilegedHelperPath, "privileged-version"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let output = String(data: data, encoding: .utf8) ?? ""
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } catch {
                return nil
            }
        }.value
    }

    private static func installScript(helperPath: String) -> String {
        let sudoersLine = "\(NSUserName()) ALL=(root) NOPASSWD: \(privilegedHelperPath) privileged-pmset-batch *, \(privilegedHelperPath) approval-status, \(privilegedHelperPath) privileged-version"
        return """
        set -e
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        install -o root -g wheel -m 755 \(shellQuote(helperPath)) \(shellQuote(privilegedHelperPath))
        umask 022
        printf '%s\\n' \(shellQuote(sudoersLine)) > \(shellQuote(sudoersPath))
        chown root:wheel \(shellQuote(sudoersPath))
        chmod 0440 \(shellQuote(sudoersPath))
        /usr/sbin/visudo -cf \(shellQuote(sudoersPath))
        """
    }

    private static func revokeScript() -> String {
        """
        set -e
        rm -f \(shellQuote(privilegedHelperPath)) \(shellQuote(sudoersPath))
        """
    }

    private static func runPrivileged(script: String, successMessage: String) -> HelperResult {
        let encoded = Data(script.utf8).base64EncodedString()
        let command = "/bin/sh -c \(shellQuote("printf %s \(shellQuote(encoded)) | /usr/bin/base64 -D | /bin/sh"))"
        let source = "do shell script \(appleScriptString(command)) with administrator privileges"

        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            return HelperResult(status: 1, output: message)
        }

        return HelperResult(status: 0, output: result?.stringValue ?? successMessage)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

enum AppLocation {
    // Gatekeeper Path Randomization (App Translocation) sandboxes apps launched
    // from `~/Downloads`, `~/Desktop`, etc. into a randomized read-only path.
    // The LaunchAgent plist Vigil installs would point to that ephemeral path
    // and break the moment the user moves Vigil.app to /Applications.
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    static var translocationMessage: String {
        "Vigil is running from a quarantined location. Move Vigil.app to /Applications before enabling."
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = HelperStatus()
    @Published var isBusy = false
    @Published var lastMessage = "Ready"
    @Published var helperApproved = false
    @Published var helperVersionMismatch = false
    @Published var confirmBatteryEnable = false
    @Published private(set) var isTranslocated = AppLocation.isTranslocated
    @AppStorage("dimDisplayOnClose") var dimDisplayOnClose = true
    @AppStorage("dimKeyboardOnClose") var dimKeyboardOnClose = true

    private var refreshTask: Task<Void, Never>?

    init() {
        if isTranslocated {
            lastMessage = AppLocation.translocationMessage
        }
        refresh()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await refreshAsync(showMessage: false)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func refresh() {
        Task {
            await refreshAsync(showMessage: true)
        }
    }

    func enable() {
        if isTranslocated {
            lastMessage = AppLocation.translocationMessage
            return
        }
        if status.isBatteryPower && !confirmBatteryEnable {
            confirmBatteryEnable = true
            lastMessage = "On battery power. Click Enable on Battery to confirm."
            return
        }
        confirmBatteryEnable = false
        runAction(label: "Enabled", command: "on")
    }

    func disable() {
        confirmBatteryEnable = false
        runAction(label: "Disabled", command: "off")
    }

    func quit() {
        Task {
            confirmBatteryEnable = false
            let currentStatus = await Helper.run(["status"])
            let shouldDisable = currentStatus.status == 0
                ? HelperStatus.parse(currentStatus.output).isEnabled
                : status.isEnabled

            guard shouldDisable else {
                NSApp.terminate(nil)
                return
            }

            isBusy = true
            lastMessage = "Disabling before quit"
            let result = await performAction(command: "off")
            isBusy = false

            if result.status == 0 {
                NSApp.terminate(nil)
            } else {
                lastMessage = result.output
                await refreshAsync(showMessage: false)
            }
        }
    }

    func toggle() {
        status.isEnabled ? disable() : enable()
    }

    func doctor() {
        Task {
            isBusy = true
            let result = await Helper.run(["doctor"])
            lastMessage = result.status == 0 ? "Doctor output copied" : "Doctor failed"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.output, forType: .string)
            isBusy = false
            await refreshAsync(showMessage: false)
        }
    }

    func approveAllActions() {
        Task {
            isBusy = true
            lastMessage = "Installing approved helper"
            let result = await ApprovedHelperInstaller.install(helperPath: Helper.executablePath)
            lastMessage = result.status == 0 ? "Actions approved" : result.output
            isBusy = false
            await refreshAsync(showMessage: false)
        }
    }

    func revokeApproval() {
        Task {
            isBusy = true
            lastMessage = "Revoking approved helper"
            let result = await ApprovedHelperInstaller.revoke()
            lastMessage = result.status == 0 ? "Approval revoked" : result.output
            isBusy = false
            await refreshAsync(showMessage: false)
        }
    }

    private func runAction(label: String, command: String) {
        Task {
            isBusy = true
            lastMessage = helperApproved ? "Applying changes" : "Waiting for administrator approval"
            let result = await performAction(command: command)
            lastMessage = result.status == 0 ? label : result.output
            isBusy = false
            await refreshAsync(showMessage: false)
        }
    }

    private func performAction(command: String) async -> HelperResult {
        let privilegeArgument = helperApproved ? Helper.approvedHelperArgument : Helper.adminPromptArgument
        return await Helper.run(actionArguments(command: command, privilegeArgument: privilegeArgument))
    }

    private func actionArguments(command: String, privilegeArgument: String) -> [String] {
        var arguments = [command, privilegeArgument]
        if command == "on" {
            arguments.append("--force-battery")
            if !dimDisplayOnClose {
                arguments.append("--no-dim-display")
            }
            if !dimKeyboardOnClose {
                arguments.append("--no-dim-keyboard")
            }
        }
        return arguments
    }

    private func refreshAsync(showMessage: Bool) async {
        async let statusResult = Helper.run(["status"])
        async let approvalResult = Helper.run(["approval-status"])
        let result = await statusResult
        if result.status == 0 {
            status = HelperStatus.parse(result.output)
            if status.isEnabled || !status.isBatteryPower {
                confirmBatteryEnable = false
            }
            if showMessage {
                lastMessage = isTranslocated ? AppLocation.translocationMessage : "Updated"
            }
        } else {
            lastMessage = result.output
        }

        let approval = await approvalResult
        let approvalInstalled = Self.approvalIsInstalled(approval)

        if approvalInstalled {
            let installedVersion = await ApprovedHelperInstaller.installedHelperVersion()
            let bundledVersion = VigilVersion.value
            let versionsMatch = installedVersion != nil && installedVersion == bundledVersion
            helperVersionMismatch = !versionsMatch
            helperApproved = versionsMatch
            if !versionsMatch && showMessage {
                lastMessage = "Privileged helper is outdated. Re-approve to update."
            }
        } else {
            helperApproved = false
            helperVersionMismatch = false
        }
    }

    private static func approvalIsInstalled(_ result: HelperResult) -> Bool {
        guard result.status == 0 else { return false }
        return result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains("Approved helper: installed")
    }
}

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updateController: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.isTranslocated {
                translocationBanner
            }

            if !model.helperApproved {
                approvalBanner
            }

            metrics

            visualControls

            Divider()

            HStack(spacing: 8) {
                Button {
                    model.toggle()
                } label: {
                    Label(primaryActionTitle, systemImage: primaryActionIcon)
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .tint(model.confirmBatteryEnable ? .orange : nil)
                .disabled(model.isBusy || model.isTranslocated)

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(model.isBusy)

                Button {
                    model.doctor()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .help("Copy diagnostics")
                .disabled(model.isBusy)

                if updateController.isConfigured {
                    Button {
                        updateController.checkForUpdates()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .help("Check for Updates")
                    .disabled(model.isBusy || !updateController.canCheckForUpdates)
                }
            }

            HStack {
                Text(model.lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Spacer()

                Button {
                    model.quit()
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit")
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 42, height: 42)
                Image(systemName: model.status.isEnabled ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(model.status.isEnabled ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Vigil")
                    .font(.system(size: 18, weight: .semibold))
                Text("Closed lid, agents live")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var primaryActionTitle: String {
        if model.status.isEnabled {
            return "Disable"
        }
        return model.confirmBatteryEnable ? "Enable on Battery" : "Enable"
    }

    private var primaryActionIcon: String {
        if model.status.isEnabled {
            return "stop.fill"
        }
        return model.confirmBatteryEnable ? "exclamationmark.triangle.fill" : "bolt.fill"
    }

    private var approvalBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: model.helperVersionMismatch ? "exclamationmark.triangle.fill" : "lock.open")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.helperVersionMismatch ? "Helper outdated" : "One-time approval available")
                    .font(.caption.weight(.semibold))
                Text(model.helperVersionMismatch
                    ? "Re-approve to update the privileged helper to the current Vigil version."
                    : "Enable and Disable can run without password prompts.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.helperVersionMismatch ? "Re-approve" : "Approve All") {
                model.approveAllActions()
            }
            .disabled(model.isBusy)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var translocationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Move Vigil to /Applications")
                    .font(.caption.weight(.semibold))
                Text("macOS Gatekeeper has quarantined this launch. Quit Vigil, drag Vigil.app into /Applications, then reopen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var metrics: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                metric("State", model.status.isEnabled ? "Awake" : "Normal", model.status.isEnabled ? .green : .secondary)
                metric("Lid", model.status.lidStateLabel, model.status.lidClosed == "yes" ? .orange : .secondary)
                metric("Agent", model.status.agentLabel, model.status.assertionAgentRunning ? .green : .secondary)
            }

            HStack(spacing: 8) {
                metric("Enabled For", enabledDurationLabel, .primary)
                metric("Last Closed", lastClosedDurationLabel, model.status.lastLidClosedSeconds == nil ? .secondary : .primary)
                metric("Total Closed", formattedDuration(model.status.lidClosedTrackedSeconds), .primary)
            }

            HStack(spacing: 8) {
                metric("Power Source", model.status.powerSource, .primary)
                metric("Battery", model.status.batteryPercent, .primary)
                metric("Charge State", model.status.batteryState.capitalized, .primary)
            }

            HStack(spacing: 8) {
                metric("Display", model.status.displayLabel, .primary)
                metric("Backlight", model.status.keyboardBacklightLabel, model.status.keyboardBacklightAPI == "available" ? .primary : .orange)
                permissionsMetric
            }
        }
    }

    private var enabledDurationLabel: String {
        guard let enabledSince = model.status.enabledSince else {
            return "Off"
        }
        return formattedDuration(max(0, Int(Date().timeIntervalSince(enabledSince))))
    }

    private var lastClosedDurationLabel: String {
        if let currentLidClosedSince = model.status.currentLidClosedSince {
            return formattedDuration(max(0, Int(Date().timeIntervalSince(currentLidClosedSince))))
        }
        guard let lastLidClosedSeconds = model.status.lastLidClosedSeconds else {
            return "None"
        }
        return formattedDuration(lastLidClosedSeconds)
    }

    private var permissionsMetric: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Permissions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 2)

                if model.helperApproved {
                    Button {
                        model.revokeApproval()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Revoke approval")
                    .disabled(model.isBusy)
                }
            }

            Text(model.helperApproved ? "Approved" : "Needs Approval")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.helperApproved ? .green : .orange)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var visualControls: some View {
        HStack(spacing: 8) {
            toggleCard(
                title: "Display",
                subtitle: "Dim to black on close",
                systemImage: "display",
                isOn: $model.dimDisplayOnClose
            )
            toggleCard(
                title: "Keyboard Backlight",
                subtitle: "Dim keys on lid close",
                systemImage: "keyboard",
                isOn: $model.dimKeyboardOnClose
            )
        }
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggleCard(title: String, subtitle: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Toggle(isOn: isOn) {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .disabled(model.status.isEnabled || model.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func formattedDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return "\(hours)h \(remainingMinutes)m"
        }
        let days = hours / 24
        return "\(days)d \(hours % 24)h"
    }
}

@main
struct VigilMenuBarApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updateController = UpdateController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model, updateController: updateController)
        } label: {
            Image(systemName: model.status.isEnabled ? "bolt.fill" : "bolt.slash.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(model.status.isEnabled ? .green : .secondary)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 24, height: 22)
        }
        .menuBarExtraStyle(.window)
    }
}
