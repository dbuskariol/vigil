import SwiftUI

@main
struct VigilMenuBarApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var updateController = UpdateController()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator, updateController: updateController)
        } label: {
            MenuBarLabel(
                caffeinateActive: coordinator.caffeinate.isActive,
                lidAwakeActive: coordinator.lidAwake.isActive,
                hasPendingPermissions: coordinator.permissions.hasRequiredMissing
            )
            .background(
                // Invisible host for the "open Setup when the model
                // requests it" trigger. `.background` is the canonical
                // place to attach behaviour to a `MenuBarExtra` label
                // because the label is always in the scene graph from
                // launch, so its `.onAppear` and `.onChange` fire even
                // before the popover has ever been opened. Avoids the
                // NotificationCenter-before-subscribers race that an
                // `init`-time post would hit.
                SetupWindowOpener(model: coordinator.onboarding)
            )
        }
        .menuBarExtraStyle(.window)

        Window("Vigil Setup", id: OnboardingWindowID) {
            OnboardingWindow(model: coordinator.onboarding, coordinator: coordinator)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Invisible view that observes `OnboardingModel.shouldShowWindow` and
/// opens the Setup window via the SwiftUI environment when the model says
/// so. Hosting it inside `MenuBarExtra.label.background` guarantees it
/// exists in the scene graph from app launch (the menu-bar icon is always
/// present), so first-launch auto-show works without timing tricks.
private struct SetupWindowOpener: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                if model.shouldShowWindow {
                    openWindow(id: OnboardingWindowID)
                }
            }
            .onChange(of: model.shouldShowWindow) { show in
                if show {
                    openWindow(id: OnboardingWindowID)
                }
            }
    }
}
