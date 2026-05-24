import AppKit
import SwiftUI
import VigilCore
import VigilIdentifiers

/// The Window scene shown for both first-run onboarding and the
/// reopenable "Setup…" flow.
struct OnboardingWindow: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(step: model.currentStep, mode: model.mode)
            Divider()
            OnboardingContent(model: model, coordinator: coordinator)
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            OnboardingFooter(model: model, coordinator: coordinator)
        }
        .frame(width: 560, height: 460)
        .fixedSize()
        .onAppear {
            // Status-bar accessory apps don't get a proper activation when
            // they open a Window — flip the policy briefly so the window
            // surfaces above other apps and gets a menu bar.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            Task { await coordinator.permissions.refresh(loginItemController: coordinator.loginItem) }
        }
        .onDisappear {
            // Drop back to accessory so we don't show in the Dock or
            // App Switcher when only the menu-bar extra is left.
            NSApp.setActivationPolicy(.accessory)
            model.didDismissWindow()
        }
    }
}

private struct OnboardingHeader: View {
    let step: OnboardingStep
    let mode: OnboardingModel.Mode

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .setup ? "Vigil Setup" : "Welcome to Vigil")
                    .font(.system(size: 16, weight: .semibold))
                Text(step.headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct OnboardingContent: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        switch model.currentStep {
        case .welcome:            ScreenWelcome()
        case .moveToApplications: ScreenMoveToApplications(model: model, coordinator: coordinator)
        case .approveAdmin:       ScreenApproveAdmin(model: model, coordinator: coordinator)
        case .allowAutoUpdates:   ScreenAllowAutoUpdates(model: model, coordinator: coordinator)
        case .notifications:      ScreenNotifications(model: model, coordinator: coordinator)
        case .openAtLogin:        ScreenOpenAtLogin(model: model, coordinator: coordinator)
        case .done:               ScreenDone(model: model)
        }
    }
}

private struct OnboardingFooter: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 8) {
            if model.currentStep.previous != nil && model.mode == .firstRun {
                Button("Back") { model.goBack() }
                    .keyboardShortcut(.cancelAction)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases.dropLast(), id: \.self) { step in
                    Circle()
                        .fill(step == model.currentStep ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            if model.mode == .firstRun {
                if model.currentStep.canSkip {
                    Button("Skip") {
                        coordinator.permissions.markSkipped(model.currentStep)
                        model.advance()
                    }
                }
                Button(model.currentStep == .done ? "Done" : "Next") {
                    if model.currentStep == .done {
                        model.complete()
                    } else {
                        model.advance()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
            } else {
                Button("Close") { model.didDismissWindow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// The only step where Next is gated on user action is
    /// `.moveToApplications` — that screen's primary action is the move,
    /// and the relaunch is what advances the flow. If the user is already
    /// in /Applications, Next enables.
    private var canAdvance: Bool {
        switch model.currentStep {
        case .moveToApplications:
            return AppRelocator.isAlreadyInApplications
        default:
            return true
        }
    }
}

private extension OnboardingStep {
    var headerSubtitle: String {
        switch self {
        case .welcome:            "Two awake modes, on demand."
        case .moveToApplications: "Move Vigil into /Applications so background agents can find it."
        case .approveAdmin:       "Lid-Awake needs a one-time admin approval."
        case .allowAutoUpdates:   "Let Vigil install its own updates without nagging."
        case .notifications:      "Get a heads-up when a timer finishes."
        case .openAtLogin:        "Have Vigil's menu-bar icon show up automatically at login."
        case .done:               "You're set."
        }
    }
}
