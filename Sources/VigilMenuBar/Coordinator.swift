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

    /// Lid-Awake battery-floor toggle. Default-enabled at 20% so users get
    /// the "don't run my Mac flat" safety net by default. The disclosure
    /// surface for this is the always-visible caption on the
    /// `BatteryFloorMenu` plus the battery-confirmation modal copy in
    /// `AppCoordinator.turnOn` — together they make the default-on choice
    /// defensible without a one-shot toast.
    ///
    /// Only used for `.lidAwake`. Caffeinate ignores these values even if
    /// the keys happen to exist (e.g. user-edited defaults plist).
    @AppStorage private var batteryFloorEnabledRaw: Bool
    @AppStorage private var batteryFloorPercentRaw: Int

    init(feature: Feature) {
        self.feature = feature
        self._durationRawValue = AppStorage(
            wrappedValue: Duration.indefinite.rawValue,
            "duration-\(feature.rawValue)"
        )
        self._batteryFloorEnabledRaw = AppStorage(
            wrappedValue: true,
            "batteryFloor.\(feature.rawValue).enabled"
        )
        self._batteryFloorPercentRaw = AppStorage(
            wrappedValue: 20,
            "batteryFloor.\(feature.rawValue).percent"
        )
    }

    var duration: Duration {
        get { Duration(rawValue: durationRawValue) ?? .indefinite }
        set { durationRawValue = newValue.rawValue }
    }

    var batteryFloorEnabled: Bool {
        get { batteryFloorEnabledRaw }
        set { batteryFloorEnabledRaw = newValue }
    }

    var batteryFloorPercent: Int {
        get { batteryFloorPercentRaw }
        set { batteryFloorPercentRaw = newValue }
    }

    /// The effective floor passed to the CLI on enable: `nil` when the
    /// toggle is off OR when the feature is not lid-awake.
    var effectiveBatteryFloor: Int? {
        guard feature == .lidAwake, batteryFloorEnabled else { return nil }
        return batteryFloorPercent
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
    @Published var helperContractMismatch = false
    @Published var pendingBatteryConfirmation: Feature?

    @Published private(set) var isTranslocated = AppLocation.isTranslocated

    /// Per-feature countdown notifications are opt-in and never trigger
    /// `requestAuthorization` unless the user explicitly enables them.
    @AppStorage("notifyOnExpiry.caffeinate") var notifyOnExpiryCaffeinate = false
    @AppStorage("notifyOnExpiry.lidAwake")   var notifyOnExpiryLidAwake = false

    let caffeinate: FeatureViewModel
    let lidAwake: FeatureViewModel
    let permissions = PermissionState()
    let loginItem = LoginItemController()
    let onboarding = OnboardingModel()

    private var refreshTask: Task<Void, Never>?
    private var previousActive: [Feature: Bool] = [:]
    private var activeObserver: NSObjectProtocol?

    init() {
        self.caffeinate = FeatureViewModel(feature: .caffeinate)
        self.lidAwake = FeatureViewModel(feature: .lidAwake)

        if isTranslocated {
            lastMessage = AppLocation.translocationMessage
        }

        Task {
            await self.refresh(showMessage: true, reArmIfNeeded: true)
            await self.permissions.refresh(loginItemController: self.loginItem)
        }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                await self.refresh(showMessage: false, reArmIfNeeded: false)
                await self.permissions.refresh(loginItemController: self.loginItem)
            }
        }

        // Refresh permissions when the user returns to Vigil — covers the
        // "open Settings, change a permission, switch back" loop.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.loginItem.refresh()
                await self.permissions.refresh(loginItemController: self.loginItem)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
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

        // Lid-awake refuses battery without explicit confirmation; the
        // user must opt in. Caffeinate's default is to allow battery.
        //
        // When a battery-floor is configured, the modal copy discloses it
        // so the user opts in fully informed — this is what makes the
        // default-enabled battery-floor toggle (FeatureViewModel) a
        // non-silent behaviour change in 0.2.2.
        let requireBatteryConfirm = (feature == .lidAwake)
            && onBattery
            && pendingBatteryConfirmation != feature

        if requireBatteryConfirm {
            pendingBatteryConfirmation = feature
            if let floor = viewModel.effectiveBatteryFloor {
                lastMessage = "On battery — Lid-Awake will auto-disable below \(floor)%. Click Turn On again to confirm."
            } else {
                lastMessage = "On battery — no battery floor configured. Lid-Awake will run until you stop it. Click Turn On again to confirm."
            }
            return
        }

        // Lid-awake with a time-limited preset requires approval, because
        // the agent-side auto-restore of pmset settings goes through the
        // privileged helper. Indefinite lid-awake still works without
        // approval (the menu app can run `off` interactively via
        // --admin-prompt to undo it manually). Same gate applies if the
        // user wants a battery floor — the agent's trip path also needs
        // non-interactive privilege.
        if feature == .lidAwake
            && (viewModel.duration != .indefinite || viewModel.effectiveBatteryFloor != nil)
            && !helperApproved {
            if viewModel.effectiveBatteryFloor != nil && viewModel.duration == .indefinite {
                lastMessage = "Battery floor requires Approve All so the agent can restore power settings non-interactively."
            } else {
                lastMessage = "Time-limited lid-awake requires Approve All so the timer can restore power settings non-interactively."
            }
            return
        }

        pendingBatteryConfirmation = nil
        runAction(feature: feature) { args in
            args + Self.enableArguments(
                feature: feature,
                duration: viewModel.duration,
                batteryFloor: viewModel.effectiveBatteryFloor
            )
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

    func openSetup(focusOn step: OnboardingStep = .welcome) {
        onboarding.requestOpen(mode: .setup, focusOn: step)
    }

    /// First missing permission step, used by the popover ⚠️ button to
    /// open Setup focused on the right card.
    var firstMissingStep: OnboardingStep {
        if permissions.location == .missingRequired { return .moveToApplications }
        if permissions.helperContract == .missingRequired { return .approveAdmin }
        if permissions.appManagement == .missingRequired { return .allowAutoUpdates }
        if permissions.notifications == .missingRequired { return .notifications }
        if permissions.loginItem == .missingRequired { return .openAtLogin }
        return .welcome
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
        let result = await Helper.run(["status", "--json"])

        var decoded: StatusReport?
        if result.status == 0,
           let data = result.output.data(using: .utf8),
           let report = try? StatusReport.decoder.decode(StatusReport.self, from: data) {
            decoded = report
            self.statusReport = report
            self.caffeinate.snapshot = report.features.first(where: { $0.feature == .caffeinate })
            self.lidAwake.snapshot = report.features.first(where: { $0.feature == .lidAwake })

            // Helper / IPC-contract state read straight out of the status
            // report. The CLI's `Status.build` does the `sudo -n
            // privileged-ipc-version` probe; we just consume the result.
            // `helperApproved` is the "fully ready" predicate (installed +
            // contract matches what this build of the menu app expects).
            let approved = report.helper.approved
            let contractMatches = report.helper.contractMatches
            helperApproved = approved && contractMatches
            helperContractMismatch = approved && !contractMatches
            permissions.apply(report: report)

            if showMessage {
                if isTranslocated {
                    lastMessage = AppLocation.translocationMessage
                } else if helperContractMismatch {
                    lastMessage = "Privileged helper sudoers rule is out of date. Re-approve from Setup."
                } else {
                    lastMessage = "Updated"
                }
            }

            // Emit opt-in expiry notifications for features that transitioned
            // active → inactive since the last refresh. The notification
            // body is reason-aware AND restore-aware — if `.batteryThreshold`
            // fired but `power.sleepDisabled` is still true, the agent's
            // retry-cap exhausted and the user is in a stuck-pmset state.
            // Saying "battery low — disabled cleanly" would lie about the
            // safety feature working.
            for feature in Feature.allCases {
                let nowActive = (feature == .caffeinate ? caffeinate.isActive : lidAwake.isActive)
                if previousActive[feature] == true && !nowActive {
                    let shouldNotify = feature == .caffeinate
                        ? notifyOnExpiryCaffeinate
                        : notifyOnExpiryLidAwake
                    if shouldNotify {
                        let snapshot = report.features.first(where: { $0.feature == feature })
                        let lastEndReason = snapshot?.stats.lastEndReason
                        let sleepStillDisabled = report.power.sleepDisabled ?? false
                        await ExpiryNotifier.notify(
                            feature: feature,
                            lastEndReason: lastEndReason,
                            sleepStillDisabled: sleepStillDisabled
                        )
                    }
                }
                previousActive[feature] = nowActive
            }
        } else if showMessage {
            lastMessage = result.output
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

            // Rebuild from the persisted session's own fields — not from
            // the menu app's `@AppStorage`. The on-disk session is the
            // truth for the currently-running session; AppStorage is only
            // the picker default for the *next* enable. This is what makes
            // a CLI-originated session (which never touched AppStorage)
            // round-trip correctly through a Sparkle relaunch.
            let args = Self.enableArguments(
                feature: snapshot.feature,
                duration: session.duration,
                batteryFloor: session.batteryFloorPercent
            )
            switch snapshot.feature {
            case .caffeinate:
                _ = await Helper.run(["caffeinate"] + args + ["--force-battery"])
            case .lidAwake:
                // `--rearm` bypasses the CLI's pre-arm refusal so a session
                // that's now at-or-below its floor (battery dropped while
                // we were Sparkle-relaunching) still gets re-armed. The
                // agent's immediate startup sample then fires a clean
                // `.batteryThreshold` trip instead of orphaning the
                // on-disk session record.
                _ = await Helper.run([
                    "lid-awake"
                ] + args + [
                    "--force-battery",
                    "--rearm",
                    helperApproved ? Helper.approvedHelperFlag : Helper.adminPromptFlag
                ])
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
            // Build "vigil <feature> <verb> [flags...]" with the privilege
            // flag appended at the end so the verb is always argv[2].
            let baseArgs: [String] = [feature == .lidAwake ? "lid-awake" : "caffeinate"]
            let withVerb = build(baseArgs)
            let needsPrivilege = feature == .lidAwake
            let privilegeFlag = helperApproved ? Helper.approvedHelperFlag : Helper.adminPromptFlag
            let finalArgs = needsPrivilege ? (withVerb + [privilegeFlag]) : withVerb

            switch feature {
            case .lidAwake:
                lastMessage = helperApproved ? "Applying changes" : "Waiting for administrator approval"
            case .caffeinate:
                lastMessage = "Applying changes"
            }
            let result = await Helper.run(finalArgs)
            lastMessage = result.status == 0 ? "Updated" : result.output
            isBusy = false
            await refresh(showMessage: false, reArmIfNeeded: false)
        }
    }

    private func lidAwakeArguments(verb: String, duration: Duration, batteryForce: Bool) -> [String] {
        var args = ["lid-awake", verb]
        if verb == "on" {
            args += ["--duration", duration.rawValue]
            if batteryForce { args.append("--force-battery") }
        }
        args.append(helperApproved ? Helper.approvedHelperFlag : Helper.adminPromptFlag)
        return args
    }

    /// Build the `on --duration <preset> [--battery-floor <int>]` argument
    /// suffix. The leading `<feature>` verb is prepended by the caller; the
    /// trailing `--force-battery` / privilege flag is appended by the caller.
    /// Caffeinate ignores `batteryFloor` even if a value is passed — the CLI
    /// flag is lid-awake-only.
    private static func enableArguments(feature: Feature, duration: Duration, batteryFloor: Int? = nil) -> [String] {
        var args = ["on", "--duration", duration.rawValue]
        switch feature {
        case .lidAwake:
            args.append("--force-battery")
            if let batteryFloor {
                args.append(contentsOf: ["--battery-floor", "\(batteryFloor)"])
            }
        case .caffeinate:
            args.append("--force-battery")
        }
        return args
    }
}

/// Per-feature expiry notifications. Opt-in. Never requests authorisation
/// unless the user enables the toggle (which calls `requestAuthorization`
/// directly from the SwiftUI view's `onChange` handler).
enum ExpiryNotifier {
    static func notify(
        feature: Feature,
        lastEndReason: StatsEvent.EndReason? = nil,
        sleepStillDisabled: Bool = false
    ) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Vigil"
        content.body = body(for: feature, reason: lastEndReason, sleepStillDisabled: sleepStillDisabled)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "vigil.expiry.\(feature.rawValue)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    /// Notification body. Reason-aware AND restore-aware — when
    /// `.batteryThreshold` fires but `sleepDisabled` is still true, the
    /// agent's pmset-restore retry cap exhausted and the Mac is in a
    /// stuck-pmset state. Lying about success would defeat the whole
    /// point of the safety feature; surface the real state and point
    /// the user at `vigil doctor`.
    static func body(
        for feature: Feature,
        reason: StatsEvent.EndReason?,
        sleepStillDisabled: Bool
    ) -> String {
        switch (feature, reason) {
        case (.lidAwake, .batteryThreshold) where sleepStillDisabled:
            return "Lid-Awake ended — power settings could not be restored. Run `vigil doctor`."
        case (.lidAwake, .batteryThreshold):
            return "Lid-Awake disabled — battery low."
        default:
            return "\(feature.displayName) ended."
        }
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
