import SwiftUI
import VigilCore

// MARK: - Menu-bar label

/// The status-bar icon itself. Single switching SF Symbol per the design
/// spec; all four symbols ship in macOS 13.0. Tooltip + accessibility label
/// match each state so screen readers and hover both describe what's
/// happening.
struct MenuBarLabel: View {
    let caffeinateActive: Bool
    let lidAwakeActive: Bool

    var body: some View {
        Image(systemName: symbolName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 22, height: 22)
            .accessibilityLabel(tooltip)
            .help(tooltip)
    }

    private var symbolName: String {
        switch (caffeinateActive, lidAwakeActive) {
        case (false, false): "moon.zzz"
        case (true, false): "eye.fill"
        case (false, true): "laptopcomputer"
        case (true, true): "sun.max.fill"
        }
    }

    private var tooltip: String {
        switch (caffeinateActive, lidAwakeActive) {
        case (false, false): "Vigil — idle"
        case (true, false): "Vigil — Caffeinate active"
        case (false, true): "Vigil — Lid-Awake active"
        case (true, true): "Vigil — Caffeinate and Lid-Awake active"
        }
    }
}

// MARK: - Duration picker

/// `Menu`-wrapped inline `Picker`. `.menu` style is the macOS-13 idiomatic
/// dropdown for an enum with a moderate number of cases; `.segmented` does
/// not fit eight options in a popover, and a popover-sheet would be three
/// nested overlays.
struct DurationMenu: View {
    @Binding var selection: Duration
    let disabled: Bool

    var body: some View {
        Menu {
            Picker("Duration", selection: $selection) {
                ForEach(Duration.allCases) { d in
                    Text(d.displayName).tag(d)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(selection.displayName).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(disabled ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(disabled)
    }
}

// MARK: - Countdown label

/// Updates once per second while its containing view is in the SwiftUI
/// render tree (i.e. while the popover is open). `TimelineView(.periodic)`
/// suspends offscreen on supported macOS versions; the `.onAppear` /
/// `.onDisappear` defence-in-depth on `MenuContentView` covers older
/// `MenuBarExtra` lifecycle bugs.
struct TimeRemainingLabel: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text(format(secondsRemaining(at: context.date)))
                    .monospacedDigit()
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func secondsRemaining(at now: Date) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now)))
    }

    private func format(_ s: Int) -> String {
        if s >= 3600 {
            return String(format: "%dh %02dm left", s / 3600, (s % 3600) / 60)
        }
        if s >= 60 {
            return String(format: "%dm %02ds left", s / 60, s % 60)
        }
        return "\(s)s left"
    }
}

// MARK: - Feature card

/// One of the two stacked cards in the popover.
///
/// `accessory` is an arbitrary trailing block where lid-awake adds its
/// visual-options toggles and approval banner; caffeinate passes EmptyView.
struct FeatureCard<Accessory: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isBusy: Bool
    let isDisabled: Bool
    @ObservedObject var vm: FeatureViewModel
    let onToggle: () -> Void
    let onDurationChange: () -> Void
    let onNotifyChange: () -> Void
    @Binding var notifyOnExpiry: Bool
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(vm.isActive ? .green : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vm.isActive },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isBusy || isDisabled)
            }

            HStack {
                Text("Duration").font(.caption).foregroundStyle(.secondary)
                Spacer()
                DurationMenu(
                    selection: Binding(
                        get: { vm.duration },
                        set: { newValue in
                            vm.duration = newValue
                            onDurationChange()
                        }
                    ),
                    disabled: vm.isActive || isBusy
                )
            }

            if vm.isActive, let expiresAt = vm.session?.expiresAt {
                TimeRemainingLabel(expiresAt: expiresAt)
            }

            HStack {
                Toggle("Notify when timer ends", isOn: Binding(
                    get: { notifyOnExpiry },
                    set: { newValue in
                        notifyOnExpiry = newValue
                        onNotifyChange()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
            }

            accessory()
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Banners

struct TranslocationBanner: View {
    var body: some View {
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
}

struct ApprovalBanner: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: coordinator.helperVersionMismatch
                  ? "exclamationmark.triangle.fill"
                  : "lock.open")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.helperVersionMismatch ? "Helper outdated" : "One-time approval available")
                    .font(.caption.weight(.semibold))
                Text(coordinator.helperVersionMismatch
                    ? "Re-approve to update the privileged helper to the current Vigil version."
                    : "Lid-awake on/off and time-limited auto-disable can run without password prompts. Caffeinate works without approval.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(coordinator.helperVersionMismatch ? "Re-approve" : "Approve All") {
                coordinator.approveAllActions()
            }
            .disabled(coordinator.isBusy)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Lid-awake visual sub-options

/// The two "dim on close" toggles only apply to lid-awake. v0.1.0-beta.1
/// placed them as their own row; v0.2.0 nests them inside the lid-awake
/// card so feature concerns stay co-located.
struct LidAwakeVisualToggles: View {
    @AppStorage("dimDisplayOnClose") var dimDisplayOnClose = true
    @AppStorage("dimKeyboardOnClose") var dimKeyboardOnClose = true
    let lidAwakeActive: Bool
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Dim display on close", isOn: $dimDisplayOnClose)
                .toggleStyle(.checkbox)
                .font(.caption)
            Toggle("Dim keyboard backlight on close", isOn: $dimKeyboardOnClose)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .disabled(lidAwakeActive || isBusy)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Diagnostics disclosure

struct DiagnosticsDisclosure: View {
    let report: StatusReport?

    var body: some View {
        DisclosureGroup("Diagnostics") {
            VStack(alignment: .leading, spacing: 4) {
                if let report {
                    diagnosticsRow("Power source", report.battery.source)
                    if let percent = report.battery.percent {
                        diagnosticsRow("Battery", "\(percent) \(report.battery.state ?? "")")
                    }
                    diagnosticsRow("Detected displays", "\(report.displays.count)")
                    diagnosticsRow("Lid", lidLabel(report.power.clamshellClosed))
                    diagnosticsRow("Keyboard backlight API", report.keyboardBacklight.apiAvailable ? "Available" : "Unavailable")
                    diagnosticsRow("Helper approved", report.helper.approved ? "Yes" : "No")
                    if let v = report.helper.installedVersion {
                        diagnosticsRow("Helper version", v)
                    }
                    diagnosticsRow("Vigil version", report.version)
                } else {
                    Text("No diagnostics available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private func lidLabel(_ closed: Bool?) -> String {
        switch closed {
        case .some(true): "Closed"
        case .some(false): "Open"
        case .none: "Unknown"
        }
    }

    private func diagnosticsRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Footer

struct FooterBar: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var updateController: UpdateController

    var body: some View {
        HStack(spacing: 8) {
            Text(coordinator.lastMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Spacer()

            Button {
                coordinator.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(coordinator.isBusy)
            .buttonStyle(.plain)

            Button {
                coordinator.doctor()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("Copy diagnostics to clipboard")
            .disabled(coordinator.isBusy)
            .buttonStyle(.plain)

            if updateController.isConfigured {
                Button {
                    updateController.checkForUpdates()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Check for updates")
                .disabled(coordinator.isBusy || !updateController.canCheckForUpdates)
                .buttonStyle(.plain)
            }

            if anyFeatureActive {
                Button {
                    coordinator.turnOffAll()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .help("Turn off all features")
                .disabled(coordinator.isBusy)
                .buttonStyle(.plain)
            }

            if coordinator.helperApproved {
                Button {
                    coordinator.revokeApproval()
                } label: {
                    Image(systemName: "lock.slash")
                }
                .help("Revoke approval")
                .disabled(coordinator.isBusy)
                .buttonStyle(.plain)
            }

            Button {
                coordinator.quit()
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Vigil (active features keep running in the background)")
            .buttonStyle(.plain)
        }
    }

    private var anyFeatureActive: Bool {
        coordinator.caffeinate.isActive || coordinator.lidAwake.isActive
    }
}

// MARK: - Header

struct HeaderRow: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: anyActive ? "sun.max.fill" : "moon.zzz")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(anyActive ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Vigil")
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if coordinator.isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var anyActive: Bool {
        coordinator.caffeinate.isActive || coordinator.lidAwake.isActive
    }

    private var subtitleText: String {
        switch (coordinator.caffeinate.isActive, coordinator.lidAwake.isActive) {
        case (false, false): "Idle"
        case (true, false): "Caffeinate active"
        case (false, true): "Lid-Awake active"
        case (true, true): "Caffeinate + Lid-Awake active"
        }
    }
}

// MARK: - Top-level popover

struct MenuContentView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var updateController: UpdateController

    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderRow(coordinator: coordinator)

            if coordinator.isTranslocated {
                TranslocationBanner()
            }

            FeatureCard(
                title: "Caffeinate",
                subtitle: coordinator.caffeinate.subtitle,
                systemImage: "eye.fill",
                isBusy: coordinator.isBusy,
                isDisabled: coordinator.isTranslocated,
                vm: coordinator.caffeinate,
                onToggle: { coordinator.toggle(.caffeinate) },
                onDurationChange: { /* persisted via @AppStorage */ },
                onNotifyChange: {
                    if coordinator.notifyOnExpiryCaffeinate {
                        Task {
                            let granted = await ExpiryNotifier.requestAuthorizationIfNeeded()
                            if !granted {
                                coordinator.notifyOnExpiryCaffeinate = false
                                coordinator.lastMessage = "Notifications denied in System Settings"
                            }
                        }
                    }
                },
                notifyOnExpiry: Binding(
                    get: { coordinator.notifyOnExpiryCaffeinate },
                    set: { coordinator.notifyOnExpiryCaffeinate = $0 }
                )
            ) {
                EmptyView()
            }

            FeatureCard(
                title: "Lid-Awake",
                subtitle: coordinator.lidAwake.subtitle,
                systemImage: "laptopcomputer",
                isBusy: coordinator.isBusy,
                isDisabled: coordinator.isTranslocated,
                vm: coordinator.lidAwake,
                onToggle: { coordinator.toggle(.lidAwake) },
                onDurationChange: { /* persisted via @AppStorage */ },
                onNotifyChange: {
                    if coordinator.notifyOnExpiryLidAwake {
                        Task {
                            let granted = await ExpiryNotifier.requestAuthorizationIfNeeded()
                            if !granted {
                                coordinator.notifyOnExpiryLidAwake = false
                                coordinator.lastMessage = "Notifications denied in System Settings"
                            }
                        }
                    }
                },
                notifyOnExpiry: Binding(
                    get: { coordinator.notifyOnExpiryLidAwake },
                    set: { coordinator.notifyOnExpiryLidAwake = $0 }
                )
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if !coordinator.helperApproved {
                        ApprovalBanner(coordinator: coordinator)
                    }
                    LidAwakeVisualToggles(
                        lidAwakeActive: coordinator.lidAwake.isActive,
                        isBusy: coordinator.isBusy
                    )
                    if coordinator.lidAwake.duration != .indefinite && !coordinator.helperApproved {
                        Text("Time-limited lid-awake requires Approve All so the timer can restore power settings.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if coordinator.pendingBatteryConfirmation == .lidAwake {
                        Text("On battery power — click Turn On again to confirm.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            DiagnosticsDisclosure(report: coordinator.statusReport)

            Divider()

            FooterBar(coordinator: coordinator, updateController: updateController)
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { isOpen = true; coordinator.refresh() }
        .onDisappear { isOpen = false }
    }
}
