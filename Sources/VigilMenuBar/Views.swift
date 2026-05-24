import SwiftUI
import VigilCore

// MARK: - Menu-bar label

/// The status-bar icon itself. Single switching SF Symbol per the design
/// spec; all four symbols ship in macOS 13.0. Tooltip + accessibility label
/// match each state so screen readers and hover both describe what's
/// happening. A small orange dot overlays the symbol whenever any required
/// permission is missing — gives the user a heads-up before they even open
/// the popover.
///
/// SwiftUI's `MenuBarExtra` label is rendered as a template image by
/// default, which strips colour. To get a green active-state tint that
/// actually shows up, we build an explicit `NSImage` with
/// `isTemplate = false` and tint it via Core Graphics compositing; the
/// idle state still uses a template image so it follows the user's
/// menu-bar tinting.
struct MenuBarLabel: View {
    let caffeinateActive: Bool
    let lidAwakeActive: Bool
    let hasPendingPermissions: Bool

    var body: some View {
        Image(nsImage: renderedImage())
            .overlay(alignment: .topTrailing) {
                if hasPendingPermissions {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 1, y: -1)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityLabel(tooltip)
            .help(tooltip)
    }

    private var isActive: Bool {
        caffeinateActive || lidAwakeActive
    }

    private var symbolName: String {
        switch (caffeinateActive, lidAwakeActive) {
        case (false, false): "moon.zzz"
        case (true, false): "eye.fill"
        case (false, true): "laptopcomputer"
        case (true, true): "bolt.fill"
        }
    }

    private var tooltip: String {
        let base: String
        switch (caffeinateActive, lidAwakeActive) {
        case (false, false): base = "Vigil — idle"
        case (true, false): base = "Vigil — Caffeinate: keep this Mac awake"
        case (false, true): base = "Vigil — Lid-Awake: keep this Mac awake with the lid closed"
        case (true, true): base = "Vigil — Never let this Mac sleep, even with the lid closed"
        }
        return hasPendingPermissions ? "\(base) (setup needs attention)" : base
    }

    /// Build the menu-bar image: template (system-tinted) when idle, green
    /// tint when any feature is active.
    private func renderedImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return NSImage()
        }

        if !isActive {
            base.isTemplate = true   // let the system tint it (light/dark menu bar)
            return base
        }

        // Active: composite the green tint behind the symbol shape using
        // destinationIn — produces a solid-green silhouette of the SF
        // Symbol's shape, isTemplate = false so SwiftUI keeps the colour.
        let size = base.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            NSColor.systemGreen.set()
            rect.fill()
            base.draw(
                in: rect,
                from: NSRect(origin: .zero, size: size),
                operation: .destinationIn,
                fraction: 1.0
            )
            return true
        }
        tinted.isTemplate = false
        return tinted
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

            FeatureStatsRow(vm: vm)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Lid-awake visual sub-options

/// The two "dim on close" toggles only apply to lid-awake; they're nested
/// inside the lid-awake card so feature concerns stay co-located.
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

// MARK: - Feature stats row

/// Compact stats display inside each FeatureCard, below the Duration row.
///
/// Two lines (either may be absent depending on state):
///   1. Live session line — only when active. Updates once per second via
///      `TimelineView` so "On for" and (for lid-awake) the lid-closed
///      accumulator visibly tick up while the popover is open.
///   2. Lifetime line — only when at least one ended session exists.
///      Folded from the StatsLog event aggregate.
/// Compact auxiliary stats footer inside each FeatureCard, below the
/// accessory controls. Stable layout — no width jumps as numbers tick —
/// achieved by a two-column Grid with right-aligned monospaced-digit
/// values. Section headers are small-caps + tracked for the macOS
/// settings-panel aesthetic.
///
/// Only renders when there's something to show:
///   - Active session block: rendered only while `vm.session != nil`.
///   - Lifetime block: rendered only when `stats.sessionCount > 0`.
///   - Both absent → the whole view collapses (no divider, no padding).
struct FeatureStatsRow: View {
    @ObservedObject var vm: FeatureViewModel

    var body: some View {
        let hasActive = vm.session != nil
        let hasLifetime = (vm.snapshot?.stats.sessionCount ?? 0) > 0

        if hasActive || hasLifetime {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                if let session = vm.session {
                    sessionSection(session: session)
                }
                if let stats = vm.snapshot?.stats, stats.sessionCount > 0 {
                    lifetimeSection(stats: stats)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionSection(session: FeatureSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(text: "This session")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    statRow("On for", value: DurationFormat.compact(
                        seconds: max(0, Int(context.date.timeIntervalSince(session.enabledAt)))
                    ))
                    if vm.feature == .lidAwake, let lid = vm.snapshot?.lid {
                        let inflight = lid.currentClosedSince.map {
                            max(0, Int(context.date.timeIntervalSince($0)))
                        } ?? 0
                        let totalClosed = lid.accumulatedClosedSeconds + inflight
                        if totalClosed > 0 {
                            statRow("Lid closed", value: DurationFormat.compact(seconds: totalClosed))
                        }
                        if let last = lid.lastClosedSeconds, last > 0 {
                            statRow("Last close", value: DurationFormat.compact(seconds: last))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lifetimeSection(stats: StatusReport.FeatureSnapshot.Stats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(text: "Lifetime")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                statRow("Total enabled", value: DurationFormat.compact(seconds: stats.totalEnabledSeconds))
                if vm.feature == .lidAwake && stats.totalLidClosedSeconds > 0 {
                    statRow("Lid-closed", value: DurationFormat.compact(seconds: stats.totalLidClosedSeconds))
                }
                if stats.longestSessionSeconds > 0 {
                    statRow("Longest", value: DurationFormat.compact(seconds: stats.longestSessionSeconds))
                }
                statRow("Sessions", value: "\(stats.sessionCount)")
            }
        }
    }

    /// One label/value row inside a Grid. Right-aligned value column keeps
    /// layout stable as the value's char-count changes (e.g. "9s" → "10s").
    /// monospacedDigit keeps the digits themselves from jittering.
    @ViewBuilder
    private func statRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.6)
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
                coordinator.openSetup(focusOn: .welcome)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Setup…")
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

            Button {
                if updateController.isConfigured {
                    updateController.checkForUpdates()
                }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .help(updateController.isConfigured
                  ? "Check for updates"
                  : "Auto-updates are configured in signed release builds only")
            .disabled(coordinator.isBusy || !updateController.canCheckForUpdates)
            .buttonStyle(.plain)

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
            .help(coordinator.lidAwake.isActive || coordinator.caffeinate.isActive
                  ? "Quit Vigil (active features keep running in the background)"
                  : "Quit Vigil")
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

            if coordinator.permissions.hasRequiredMissing {
                Button {
                    coordinator.openSetup(focusOn: coordinator.firstMissingStep)
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Setup needs attention")
            }

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
        case (true, false): "Keeping your Mac awake"
        case (false, true): "Keeping your Mac awake, lid closed"
        case (true, true): "Never letting your Mac sleep"
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
                        HStack(spacing: 6) {
                            Image(systemName: "lock.open")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Approval needed —")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button("Open Setup") {
                                coordinator.openSetup(focusOn: .approveAdmin)
                            }
                            .buttonStyle(.plain)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            Spacer()
                        }
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
