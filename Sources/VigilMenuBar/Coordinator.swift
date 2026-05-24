import Foundation
import SwiftUI
import UserNotifications
import VigilCore
import VigilIdentifiers

/// Per-feature view-model. Holds the duration picker state (via
/// `@AppStorage`) and exposes the current `FeatureSession` snapshot read
/// from the shared `StatusReport`.
@MainActor
final class FeatureViewModel: ObservableObject {
    let feature: Feature
    @Published var snapshot: StatusReport.FeatureSnapshot?

    /// Last-used duration, persisted to `UserDefaults` per feature. The CLI
    /// has its own `--duration` flag; this storage is intentionally
    /// menu-app-scoped (it's the picker's remembered value).
    @AppStorage private var durationRawValue: String

    init(feature: Feature) {
        self.feature = feature
        self._durationRawValue = AppStorage(
            wrappedValue: Duration.indefinite.rawValue,
            "duration-\(feature.rawValue)"
        )
    }

    var duration: Duration {
        get { Duration(rawValue: durationRawValue) ?? .indefinite }
        set { durationRawValue = newValue.rawValue }
    }

    var isActive: Bool { snapshot?.active ?? false }
    var agentRunning: Bool { snapshot?.agentRunning ?? false }
    var session: FeatureSession? { snapshot?.session }

    /// Card subtitle copy. Tells the user what protection this feature
    /// provides AND its key limitation, in the same spot so behaviour is
    /// discoverable from the popover.
    var subtitle: String {
        switch feature {
        case .caffeinate:
            return "Prevents display + system idle sleep. Manual Sleep and lid close still send the Mac to sleep."
        case .lidAwake:
            return "Keeps the Mac fully awake with the lid closed. Manual Sleep is also blocked."
        }
    }
}

/// The single top-level @MainActor observable owned by the menu app. It
/// holds the decoded `StatusReport` from `vigil status --json`, drives the
/// 10-second background refresh, exposes per-feature view-models, and
/// dispatches the toggle/approve/quit actions.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var statusReport: StatusReport?
    @Published var isBusy = false
    @Published var lastMessage = "Ready"
    @Published var helperApproved = false
    @Published var helperVersionMismatch = false
    @Published var pendingBatteryConfirmation: Feature?

    @Published private(set) var isTranslocated = AppLocation.isTranslocated

    /// Per-feature countdown notifications are opt-in and never trigger
    /// `requestAuthorization` unless the user explicitly enables them.
    @AppStorage("notifyOnExpiry.caffeinate") var notifyOnExpiryCaffeinate = false
    @AppStorage("notifyOnExpiry.lidAwake")   var notifyOnExpiryLidAwake = false

    let caffeinate: FeatureViewModel
    let lidAwake: FeatureViewModel

    private var refreshTask: Task<Void, Never>?
    private var previousActive: [Feature: Bool] = [:]

    init() {
        self.caffeinate = FeatureViewModel(feature: .caffeinate)
        self.lidAwake = FeatureViewModel(feature: .lidAwake)

        if isTranslocated {
            lastMessage = AppLocation.translocationMessage
        }

        Task { await self.refresh(showMessage: true, reArmIfNeeded: true) }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.refresh(showMessage: false, reArmIfNeeded: false)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Public actions

    func refresh() {
        Task { await refresh(showMessage: true, reArmIfNeeded: false) }
    }

    func toggle(_ feature: Feature) {
        if vm(for: feature).isActive {
            turnOff(feature)
        } else {
            turnOn(feature)
        }
    }

    func turnOn(_ feature: Feature) {
        if isTranslocated {
            lastMessage = AppLocation.translocationMessage
            return
        }

        let viewModel = vm(for: feature)
        let onBattery = statusReport?.battery.isBatteryPower ?? false

        // Lid-awake refuses battery without explicit confirmation, matching
        // v0.1.0-beta.1's safety. Caffeinate's default is to allow battery.
        let requireBatteryConfirm = (feature == .lidAwake)
            && onBattery
            && pendingBatteryConfirmation != feature

        if requireBatteryConfirm {
            pendingBatteryConfirmation = feature
            lastMessage = "On battery power. Click Turn On again to confirm."
            return
        }

        // Lid-awake with a time-limited preset requires approval, because
        // the agent-side auto-restore of pmset settings goes through the
        // privileged helper. Indefinite lid-awake still works without
        // approval (the menu app can run `off` interactively via
        // --admin-prompt to undo it manually).
        if feature == .lidAwake
            && viewModel.duration != .indefinite
            && !helperApproved {
            lastMessage = "Time-limited lid-awake requires Approve All so the timer can restore power settings non-interactively."
            return
        }

        pendingBatteryConfirmation = nil
        runAction(feature: feature) { args in
            args + Self.enableArguments(feature: feature, duration: viewModel.duration)
        }
    }

    func turnOff(_ feature: Feature) {
        pendingBatteryConfirmation = nil
        runAction(feature: feature) { args in args + ["off"] }
    }

    func turnOffAll() {
        Task {
            isBusy = true
            lastMessage = "Turning off all features"
            // Order matters slightly: stop caffeinate (free / unprivileged)
            // before lid-awake (slower because of pmset restore).
            _ = await Helper.run(["caffeinate", "off"])
            _ = await Helper.run(lidAwakeArguments(verb: "off", duration: .indefinite, batteryForce: false))
            isBusy = false
            await refresh(showMessage: false, reArmIfNeeded: false)
        }
    }

    func quit() {
        // Both features are LaunchAgent-backed and survive menu-app quit by
        // design. Users who want to stop a feature use the per-card toggle
        // or "Turn Off All" first.
        NSApp.terminate(nil)
    }

    func doctor() {
        Task {
            isBusy = true
            let result = await Helper.run(["doctor"])
            lastMessage = result.status == 0 ? "Doctor output copied to clipboard" : "Doctor failed"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.output, forType: .string)
            isBusy = false
            await refresh(showMessage: false, reArmIfNeeded: false)
        }
    }

    func approveAllActions() {
        Task {
            isBusy = true
            lastMessage = "Installing approved helper"
            let result = await ApprovedHelperInstaller.install(helperPath: Helper.executablePath)
            lastMessage = result.status == 0 ? "Actions approved" : result.output
            isBusy = false
            await refresh(showMessage: false, reArmIfNeeded: false)
        }
    }

    func revokeApproval() {
        Task {
            isBusy = true
            lastMessage = "Revoking approved helper"
            let result = await ApprovedHelperInstaller.revoke()
            lastMessage = result.status == 0 ? "Approval revoked" : result.output
            isBusy = false
            await refresh(showMessage: false, reArmIfNeeded: false)
        }
    }

    // MARK: - Refresh + re-arm

    private func refresh(showMessage: Bool, reArmIfNeeded: Bool) async {
        async let statusFetch = Helper.run(["status", "--json"])
        async let approvalFetch = Helper.run(["approval-status"])
        let result = await statusFetch
        let approval = await approvalFetch

        var decoded: StatusReport?
        if result.status == 0,
           let data = result.output.data(using: .utf8),
           let report = try? StatusReport.decoder.decode(StatusReport.self, from: data) {
            decoded = report
            self.statusReport = report
            self.caffeinate.snapshot = report.features.first(where: { $0.feature == .caffeinate })
            self.lidAwake.snapshot = report.features.first(where: { $0.feature == .lidAwake })

            if showMessage {
                lastMessage = isTranslocated ? AppLocation.translocationMessage : "Updated"
            }

            // Emit opt-in expiry notifications for features that transitioned
            // active → inactive since the last refresh.
            for feature in Feature.allCases {
                let nowActive = (feature == .caffeinate ? caffeinate.isActive : lidAwake.isActive)
                if previousActive[feature] == true && !nowActive {
                    let shouldNotify = feature == .caffeinate
                        ? notifyOnExpiryCaffeinate
                        : notifyOnExpiryLidAwake
                    if shouldNotify {
                        await ExpiryNotifier.notify(feature: feature)
                    }
                }
                previousActive[feature] = nowActive
            }
        } else if showMessage {
            lastMessage = result.output
        }

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

        if reArmIfNeeded, let report = decoded {
            await reArmAgentsIfNeeded(from: report)
        }
    }

    /// After a Sparkle update (or any in-place CLI replacement), re-bootstrap
    /// per-feature LaunchAgents whose persisted session is still within its
    /// window. This is what makes a 5-hour caffeinate session survive a
    /// Sparkle relaunch.
    private func reArmAgentsIfNeeded(from report: StatusReport) async {
        for snapshot in report.features {
            guard let session = snapshot.session, !session.isExpired() else { continue }
            // If the session is persisted but the agent isn't running, the
            // CLI invocation `vigil <feature> on` re-installs the plist
            // (with the current executable path), touches the sentinel, and
            // bootstraps the agent.
            guard !snapshot.agentRunning else { continue }

            let args = Self.enableArguments(
                feature: snapshot.feature,
                duration: session.duration
            )
            switch snapshot.feature {
            case .caffeinate:
                _ = await Helper.run(["caffeinate"] + args + ["--force-battery"])
            case .lidAwake:
                _ = await Helper.run([
                    "lid-awake",
                    helperApproved ? Helper.approvedHelperFlag : Helper.adminPromptFlag
                ] + args + ["--force-battery"])
            }
        }
    }

    // MARK: - Helpers

    private func vm(for feature: Feature) -> FeatureViewModel {
        switch feature {
        case .caffeinate: return caffeinate
        case .lidAwake: return lidAwake
        }
    }

    private func runAction(feature: Feature, build: @escaping ([String]) -> [String]) {
        Task {
            isBusy = true
            let preface: [String]
            switch feature {
            case .lidAwake:
                preface = ["lid-awake", helperApproved ? Helper.approvedHelperFlag : Helper.adminPromptFlag]
                lastMessage = helperApproved ? "Applying changes" : "Waiting for administrator approval"
            case .caffeinate:
                preface = ["caffeinate"]
                lastMessage = "Applying changes"
            }
            let args = build(preface)
            let result = await Helper.run(args)
            lastMessage = result.status == 0 ? "Updated" : result.output
            isBusy = false
            await refresh(showMessage: false, reArmIfNeeded: false)
        }
    }

    private func lidAwakeArguments(verb: String, duration: Duration, batteryForce: Bool) -> [String] {
        var args = ["lid-awake", helperApproved ? Helper.approvedHelperFlag : Helper.adminPromptFlag, verb]
        if verb == "on" {
            args += ["--duration", duration.rawValue]
            if batteryForce { args.append("--force-battery") }
        }
        return args
    }

    private static func enableArguments(feature: Feature, duration: Duration) -> [String] {
        var args = ["on", "--duration", duration.rawValue]
        switch feature {
        case .lidAwake:
            args.append("--force-battery")
        case .caffeinate:
            args.append("--force-battery")
        }
        return args
    }

    private static func approvalIsInstalled(_ result: HelperResult) -> Bool {
        guard result.status == 0 else { return false }
        return result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains("Approved helper: installed")
    }
}

/// Per-feature expiry notifications. Opt-in. Never requests authorisation
/// unless the user enables the toggle (which calls `requestAuthorization`
/// directly from the SwiftUI view's `onChange` handler).
enum ExpiryNotifier {
    static func notify(feature: Feature) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Vigil"
        content.body = "\(feature.displayName) ended."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "vigil.expiry.\(feature.rawValue)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    /// Called from the SwiftUI Toggle's `onChange`. Requests
    /// `[.alert, .sound]` authorisation if not yet decided; returns whether
    /// the toggle should remain "on".
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }
}
