import Combine
import Foundation
import Sparkle
import VigilCore
import VigilIdentifiers

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
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
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
        return URL(string: feedURL)?.scheme == "https"
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Boots out every Vigil-owned LaunchAgent (both v0.2.0 labels and the v0.1
/// legacy label, defensively) before Sparkle replaces the bundled CLI
/// binary. Otherwise launchd may hold a file-handle on the old Mach-O and
/// fail the in-place swap.
///
/// On relaunch, `AppCoordinator.reArmAgentsIfNeeded()` re-bootstraps the
/// per-feature agents against the new CLI for any feature whose session is
/// still within its window.
final class SparkleDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let labels = [
            VigilIdentifiers.lidAwakeAgentLabel,
            VigilIdentifiers.caffeinateAgentLabel,
            VigilIdentifiers.legacyAssertionAgentLabel,
        ]
        let domain = "gui/\(getuid())"
        for label in labels {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["bootout", "\(domain)/\(label)"]
            try? task.run()
            task.waitUntilExit()
        }
    }
}
