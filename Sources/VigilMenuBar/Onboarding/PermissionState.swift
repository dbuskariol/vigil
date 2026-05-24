import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications
import VigilCore
import VigilIdentifiers

/// Wraps `SMAppService.mainApp` for the Open-at-Login toggle.
///
/// Hard-guards `setEnabled(true)` on the bundle being at `/Applications/
/// Vigil.app` and not translocated — `register()` records the current
/// bundle URL with launchd, so calling it from anywhere else would bake a
/// path that disappears on next reboot.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered

    init() { refresh() }

    var isEnabled: Bool { status == .enabled }

    var statusDescription: String {
        switch status {
        case .notRegistered:    "Not enabled"
        case .enabled:          "Enabled"
        case .requiresApproval: "Requires approval in System Settings"
        case .notFound:         "App not registered with launchd"
        @unknown default:       "Unknown"
        }
    }

    var canRegisterFromHere: Bool {
        !VigilIdentifiers.isTranslocated
            && Bundle.main.bundlePath == "/Applications/Vigil.app"
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    enum SetEnabledResult { case ok, requiresMove, requiresApproval, failed(Error) }

    /// Toggle and return what happened so the UI can react.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> SetEnabledResult {
        if enabled && !canRegisterFromHere {
            return .requiresMove
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            return status == .requiresApproval ? .requiresApproval : .ok
        } catch {
            refresh()
            return .failed(error)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Post-hoc, heuristic detection of "App Management permission likely
/// missing." There is no public macOS query API for this permission; we
/// can only observe Sparkle's install-time failures and classify the ones
/// that look like local permission denials.
///
/// False positives are possible (e.g. disk full → EPERM on install gets
/// flagged as App Management). The onboarding screen copy reflects this
/// uncertainty.
@MainActor
final class SparkleUpdatePermissionTracker: ObservableObject {

    static let shared = SparkleUpdatePermissionTracker()

    @AppStorage("sparkle.lastFailureKind") private var lastFailureKind: String = ""
    @AppStorage("sparkle.lastFailureAt") private var lastFailureAtRaw: Double = 0

    /// Flag as missing only when:
    ///   - the most recent Sparkle failure was classified as a local
    ///     permission denial (EPERM/EACCES walking the NSError chain), AND
    ///   - it happened within the last 30 days (stale failures don't
    ///     count — if the user has run multiple updates since then
    ///     without re-failing, the permission must have been granted).
    var appManagementLikelyMissing: Bool {
        guard lastFailureKind == FailureKind.installPermissionDenied.rawValue else {
            return false
        }
        let age = Date().timeIntervalSince1970 - lastFailureAtRaw
        return age > 0 && age < 30 * 24 * 60 * 60
    }

    func recordFailure(_ error: Error) {
        let kind = Self.classify(error as NSError)
        lastFailureKind = kind.rawValue
        lastFailureAtRaw = Date().timeIntervalSince1970
    }

    func recordSuccess() {
        lastFailureKind = ""
        lastFailureAtRaw = 0
    }

    enum FailureKind: String {
        case installPermissionDenied
        case other
    }

    /// Walk the underlying NSError chain looking for POSIX EPERM/EACCES —
    /// the most reliable signal across Sparkle versions. Anything else
    /// (network, signature mismatch, user cancel) is `.other` and never
    /// promotes to the App Management heuristic.
    private static func classify(_ err: NSError) -> FailureKind {
        var current: NSError? = err
        while let e = current {
            if e.domain == NSPOSIXErrorDomain
                && (e.code == Int(EPERM) || e.code == Int(EACCES)) {
                return .installPermissionDenied
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .other
    }
}

/// The observable model of every permission Vigil cares about.
///
/// Drives the persistent menu-bar warning dot (only `.missingRequired`
/// permissions trigger it — `.missingSkipped` are user-deliberate and
/// must not nag) AND the Setup window's row-by-row state.
@MainActor
final class PermissionState: ObservableObject {

    enum Value: Equatable { case ok, missingRequired, missingSkipped, unknown }

    @Published var location: Value = .unknown            // /Applications + not translocated — hard required
    @Published var helperContract: Value = .unknown      // sudoers rule current — hard required
    @Published var notifications: Value = .unknown
    @Published var loginItem: Value = .unknown
    @Published var appManagement: Value = .unknown

    /// Per-permission "user clicked Skip" persisted flag. Reset when the
    /// user later toggles the permission on from the Setup window.
    @AppStorage("permission.notifications.skipped") var notificationsSkipped = false
    @AppStorage("permission.loginItem.skipped") var loginItemSkipped = false
    @AppStorage("permission.appManagement.skipped") var appManagementSkipped = false

    /// Whether the menu-bar dot should be shown. Only `.missingRequired`
    /// counts — `.missingSkipped` is a user-deliberate state.
    var hasRequiredMissing: Bool {
        [location, helperContract, notifications, loginItem, appManagement].contains(.missingRequired)
    }

    func refresh(loginItemController: LoginItemController) async {
        location = (!VigilIdentifiers.isTranslocated
                    && Bundle.main.bundlePath == "/Applications/Vigil.app")
            ? .ok : .missingRequired

        // helperContract is published from the AppCoordinator's status
        // refresh; this object reads the latest snapshot via the
        // coordinator (see `apply(report:)` below).

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notifications = .ok
        case .denied, .notDetermined:
            notifications = notificationsSkipped ? .missingSkipped : .missingRequired
        @unknown default:
            notifications = .unknown
        }

        loginItemController.refresh()
        loginItem = loginItemController.isEnabled
            ? .ok
            : (loginItemSkipped ? .missingSkipped : .missingRequired)

        appManagement = SparkleUpdatePermissionTracker.shared.appManagementLikelyMissing
            ? (appManagementSkipped ? .missingSkipped : .missingRequired)
            : .ok
    }

    /// Folds the IPC-contract status from a StatusReport into the
    /// helperContract slot. Called from `AppCoordinator.refresh`.
    func apply(report: StatusReport) {
        let contractOK = report.helper.approved && report.helper.contractMatches
        helperContract = contractOK ? .ok : .missingRequired
    }

    func markSkipped(_ step: OnboardingStep) {
        switch step {
        case .notifications: notificationsSkipped = true
        case .openAtLogin:   loginItemSkipped = true
        case .allowAutoUpdates: appManagementSkipped = true
        default: break  // location, approveAdmin: not skippable
        }
    }

    func unmarkSkipped(_ step: OnboardingStep) {
        switch step {
        case .notifications: notificationsSkipped = false
        case .openAtLogin:   loginItemSkipped = false
        case .allowAutoUpdates: appManagementSkipped = false
        default: break
        }
    }
}
