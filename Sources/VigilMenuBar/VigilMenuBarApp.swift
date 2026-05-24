import SwiftUI

@main
struct VigilMenuBarApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var updateController = UpdateController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator, updateController: updateController)
        } label: {
            MenuBarLabel(
                caffeinateActive: coordinator.caffeinate.isActive,
                lidAwakeActive: coordinator.lidAwake.isActive
            )
        }
        .menuBarExtraStyle(.window)
    }
}
