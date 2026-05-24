import Foundation
import SwiftUI
import VigilCore

/// The seven onboarding steps, in display order.
public enum OnboardingStep: String, CaseIterable, Hashable {
    case welcome
    case moveToApplications
    case approveAdmin
    case allowAutoUpdates
    case notifications
    case openAtLogin
    case done

    /// Whether this step can be skipped during firstRun mode.
    /// Welcome / Done are navigation-only; moveToApplications is the hard
    /// prerequisite (the relaunch advances the flow).
    public var canSkip: Bool {
        switch self {
        case .welcome, .moveToApplications, .done: false
        case .approveAdmin, .allowAutoUpdates, .notifications, .openAtLogin: true
        }
    }

    public var next: OnboardingStep? {
        let all = OnboardingStep.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    public var previous: OnboardingStep? {
        let all = OnboardingStep.allCases
        guard let i = all.firstIndex(of: self), i > 0 else { return nil }
        return all[i - 1]
    }
}

public let OnboardingWindowID = "vigil.onboarding"

/// Model driving the onboarding flow + the Setup window.
///
/// Two modes:
///   - `.firstRun` — sequential 7-screen walkthrough. Skip / Next / Done
///     footer. Auto-opened on first launch by a view in the scene graph
///     observing `hasCompletedOnboarding`.
///   - `.setup`    — re-openable via the "Setup…" button. Footer becomes
///     Close. Each screen body shows a "Fix" / "Re-enable" action inline.
@MainActor
public final class OnboardingModel: ObservableObject {

    public enum Mode { case firstRun, setup }

    @AppStorage("hasCompletedOnboarding") public var hasCompletedOnboarding = false
    @Published public var currentStep: OnboardingStep = .welcome
    @Published public var mode: Mode = .firstRun

    /// True iff the model thinks the Setup window should be visible right
    /// now. Observed by `MenuBarLabel` and `MenuContentView` to trigger
    /// `openWindow(id:)`. Driven by `requestOpen(...)` and reset by the
    /// window's `.onDisappear`.
    @Published public var shouldShowWindow = false

    public init() {
        // If a move-and-relaunch wrote a resume marker, jump straight to
        // the recorded step.
        if let raw = try? String(contentsOf: Paths.onboardingResumeMarker, encoding: .utf8),
           let step = OnboardingStep(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            currentStep = step
            try? FileManager.default.removeItem(at: Paths.onboardingResumeMarker)
            mode = .firstRun
            shouldShowWindow = true
        } else if !hasCompletedOnboarding {
            currentStep = .welcome
            mode = .firstRun
            shouldShowWindow = true
        }
    }

    public func requestOpen(mode: Mode, focusOn step: OnboardingStep = .welcome) {
        self.mode = mode
        self.currentStep = step
        self.shouldShowWindow = true
    }

    public func didDismissWindow() {
        shouldShowWindow = false
    }

    public func advance() {
        if let next = currentStep.next {
            currentStep = next
        }
    }

    public func goBack() {
        if let previous = currentStep.previous {
            currentStep = previous
        }
    }

    public func complete() {
        hasCompletedOnboarding = true
        shouldShowWindow = false
    }
}
