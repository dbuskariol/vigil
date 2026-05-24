import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import VigilCore
import VigilIdentifiers

// MARK: - Reusable row pieces

/// Renders a check / cross / dash status row used inside every screen.
struct PermissionRow: View {
    let title: String
    let detail: String
    let state: PermissionState.Value
    let actionLabel: String?
    let action: (() -> Void)?

    init(title: String, detail: String, state: PermissionState.Value, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.detail = detail
        self.state = state
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .missingRequired: "xmark.circle.fill"
        case .missingSkipped: "minus.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .ok: .green
        case .missingRequired: .orange
        case .missingSkipped: .secondary
        case .unknown: .secondary
        }
    }
}

// MARK: - Screen: Welcome

struct ScreenWelcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vigil keeps your Mac awake on demand, in two distinct modes.")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "eye.fill").frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Caffeinate").font(.system(size: 13, weight: .semibold))
                        Text("Stop the display and system from going to sleep on idle. Manual Sleep and lid close still work.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "laptopcomputer").frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lid-Awake").font(.system(size: 13, weight: .semibold))
                        Text("Keep the Mac fully awake with the lid closed. Includes display + keyboard backlight dimming on close.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            Text("Vigil sends no telemetry. The only network call is a daily check for app updates against this repository's release feed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
    }
}

// MARK: - Screen: Move to /Applications

struct ScreenMoveToApplications: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var coordinator: AppCoordinator
    @State private var error: String?
    @State private var inProgress = false
    @State private var showReplaceConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vigil needs to live in /Applications.")
                .font(.system(size: 14, weight: .semibold))
            Text("Background agents and the auto-update flow both rely on a stable location. Running from a quarantined download path (~/Downloads, ~/Desktop) or any other folder leaves agent plists pointing at paths that disappear on the next reboot.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                title: "Location",
                detail: locationDetail,
                state: coordinator.permissions.location
            )

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    if AppRelocator.existingApplicationsCopyIsVigil() {
                        showReplaceConfirm = true
                    } else {
                        performMove(replaceExisting: false)
                    }
                } label: {
                    if inProgress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Moving…")
                        }
                    } else {
                        Text(AppRelocator.isAlreadyInApplications ? "Already in /Applications" : "Move to /Applications and restart")
                    }
                }
                .disabled(AppRelocator.isAlreadyInApplications || inProgress)
                .keyboardShortcut(.defaultAction)
            }

            Spacer()
        }
        .alert("Replace existing Vigil.app?", isPresented: $showReplaceConfirm) {
            Button("Replace", role: .destructive) { performMove(replaceExisting: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A copy of Vigil.app already exists at /Applications. Replace it with this copy?")
        }
    }

    private var locationDetail: String {
        if AppRelocator.isAlreadyInApplications {
            return "Running from /Applications/Vigil.app — looks good."
        } else if VigilIdentifiers.isTranslocated {
            return "Currently running from a quarantined location (Gatekeeper Path Randomization). Click below to move to /Applications and restart."
        } else {
            return "Currently running from \(Bundle.main.bundlePath). Click below to move."
        }
    }

    private func performMove(replaceExisting: Bool) {
        inProgress = true
        error = nil
        Task {
            do {
                try await AppRelocator.moveAndRelaunch(replaceExisting: replaceExisting)
                // If we get here without relaunching, the move was a no-op
                // (already in place).
                await coordinator.permissions.refresh(loginItemController: coordinator.loginItem)
            } catch let err as AppRelocator.RelocationError where err == .alreadyExists {
                showReplaceConfirm = true
            } catch {
                self.error = "\(error)"
            }
            inProgress = false
        }
    }
}

// MARK: - Screen: Approve admin

struct ScreenApproveAdmin: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var coordinator: AppCoordinator

    private var sudoersPreview: String {
        VigilIdentifiers.sudoersLine(for: NSUserName())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Approve Vigil's privileged actions (one-time).")
                .font(.system(size: 14, weight: .semibold))
            Text("Lid-Awake applies a reversible system-sleep override via pmset. That needs admin. The “Approve All” flow installs a scoped privileged helper at /Library/PrivilegedHelperTools and writes a narrow sudoers rule so Vigil never has to prompt for your password again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Exact sudoers rule that will be installed:")
                    .font(.caption.weight(.semibold))
                Text(sudoersPreview)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionRow(
                title: "Sudoers approval",
                detail: helperDetail,
                state: coordinator.permissions.helperContract,
                actionLabel: helperActionLabel,
                action: helperAction
            )

            Text("Caffeinate uses none of this — it works without approval.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var helperDetail: String {
        switch coordinator.permissions.helperContract {
        case .ok: "Approved. Lid-Awake on/off and time-limited auto-disable run without password prompts."
        case .missingRequired:
            coordinator.helperContractMismatch
                ? "Sudoers rule on disk is out of date — re-approve to update it."
                : "Not yet approved. Without this, time-limited Lid-Awake cannot auto-restore your power settings."
        case .missingSkipped: "Skipped earlier. You can still approve at any time."
        case .unknown: "Checking…"
        }
    }

    private var helperActionLabel: String {
        coordinator.permissions.helperContract == .ok ? "Revoke" : "Approve"
    }

    private func helperAction() {
        if coordinator.permissions.helperContract == .ok {
            coordinator.revokeApproval()
        } else {
            coordinator.approveAllActions()
        }
    }
}

// MARK: - Screen: Allow auto-updates (App Management)

struct ScreenAllowAutoUpdates: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow Vigil to install its own updates.")
                .font(.system(size: 14, weight: .semibold))
            Text("Vigil checks for updates daily and verifies each one with an EdDSA signature before installing. macOS asks for App Management permission the first time an app updates itself in place.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                title: "App Management",
                detail: appManagementDetail,
                state: coordinator.permissions.appManagement,
                actionLabel: "Open Privacy Settings",
                action: openAppManagementSettings
            )

            Text("There's no public API to query this permission proactively. If updates have been failing with permission errors, opening Settings → Privacy & Security → App Management and enabling Vigil here should fix it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
    }

    private var appManagementDetail: String {
        switch coordinator.permissions.appManagement {
        case .ok: "No recent permission failures from auto-update."
        case .missingRequired: "Recent auto-update failed with a permission error. App Management may be denied."
        case .missingSkipped: "Skipped earlier. Re-check from Settings at any time."
        case .unknown: "No data yet — comes from the next auto-update result."
        }
    }

    private func openAppManagementSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Screen: Notifications

struct ScreenNotifications: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var coordinator: AppCoordinator
    @State private var requesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send a notification when a timer expires.")
                .font(.system(size: 14, weight: .semibold))
            Text("Allowing notifications lets Vigil tell you when a Caffeinate or Lid-Awake timer reaches its deadline. Per-feature opt-in lives on each card in the menu, so you can pick which (if any) of the two features actually notifies you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                title: "Notifications",
                detail: notificationsDetail,
                state: coordinator.permissions.notifications,
                actionLabel: notificationsActionLabel,
                action: requestNotifications
            )

            Spacer()
        }
    }

    private var notificationsDetail: String {
        switch coordinator.permissions.notifications {
        case .ok: "Allowed. Enable per-feature notifications from the menu cards."
        case .missingRequired: "Not yet allowed."
        case .missingSkipped: "Skipped. Toggle Notifications back on from Settings → Notifications → Vigil to re-enable."
        case .unknown: "Checking…"
        }
    }

    private var notificationsActionLabel: String {
        coordinator.permissions.notifications == .ok ? "Open Settings" : "Allow"
    }

    private func requestNotifications() {
        if coordinator.permissions.notifications == .ok {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        requesting = true
        Task {
            _ = await ExpiryNotifier.requestAuthorizationIfNeeded()
            await coordinator.permissions.refresh(loginItemController: coordinator.loginItem)
            requesting = false
        }
    }
}

// MARK: - Screen: Open at Login

struct ScreenOpenAtLogin: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var coordinator: AppCoordinator
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Vigil at login.")
                .font(.system(size: 14, weight: .semibold))
            Text("If you want Vigil's menu-bar icon to appear automatically each time you log in, enable this. You can change it later in System Settings → General → Login Items.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                title: "Open Vigil at login",
                detail: loginDetail,
                state: coordinator.permissions.loginItem,
                actionLabel: loginActionLabel,
                action: toggle
            )

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Note: disabling Vigil in System Settings → Login Items will also affect any running background agents (lid-awake or caffeinate sessions).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
    }

    private var loginDetail: String {
        if !coordinator.loginItem.canRegisterFromHere {
            return "Move Vigil.app to /Applications before enabling — \(coordinator.loginItem.statusDescription)."
        }
        return coordinator.loginItem.statusDescription
    }

    private var loginActionLabel: String {
        coordinator.loginItem.isEnabled ? "Disable" : "Enable"
    }

    private func toggle() {
        error = nil
        let result = coordinator.loginItem.setEnabled(!coordinator.loginItem.isEnabled)
        switch result {
        case .ok:
            Task { await coordinator.permissions.refresh(loginItemController: coordinator.loginItem) }
        case .requiresMove:
            error = "Move Vigil.app to /Applications first."
        case .requiresApproval:
            coordinator.loginItem.openLoginItemsSettings()
        case .failed(let e):
            error = "\(e.localizedDescription)"
        }
    }
}

// MARK: - Screen: Done

struct ScreenDone: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Here's what to do from here.")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    Text("Look up — Vigil lives in your menu bar. Click the icon to open the popover.")
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "eye.fill")
                        .frame(width: 22)
                    Text("Click Caffeinate to keep your Mac awake while you're at it.")
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "laptopcomputer")
                        .frame(width: 22)
                    Text("Click Lid-Awake to run a long job with the lid closed.")
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "gearshape")
                        .frame(width: 22)
                    Text("Open Setup again from the gear icon in the popover footer.")
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            Spacer()
        }
    }
}
