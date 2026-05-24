import Foundation

/// Metrics describing a feature session at a moment in time.
///
/// Single source of truth for "given a session and (for lid-awake) its
/// lid telemetry, what are its current numbers at this moment?".
///
/// Used by:
///   - The agent's `emitSessionEnded` to materialize a `SessionEnded`
///     event (`at = endedAt`).
///   - The menu app's per-feature stats row to render "On for" / "Lid
///     closed" / "Last close" while a session is active (`at = now`).
///   - The menu app's lifetime projection (`FeatureSnapshot.liveLifetime`)
///     to overlay the in-flight session on top of the persisted
///     aggregate so totals tick live.
///   - The CLI's `vigil status` human output for both purposes.
///
/// Keeping the derivation here guarantees all surfaces report the same
/// numbers — and that the value the UI shows at moment T equals the
/// `SessionEnded` event the agent will emit if the session ends at T.
public struct SessionMetrics: Sendable, Equatable {
    /// Wall-clock seconds since `session.enabledAt`. Always >= 0.
    public let elapsedSeconds: TimeInterval

    /// For lid-awake: total seconds the lid has been closed during this
    /// session — the persisted accumulator plus any in-flight
    /// close-since delta if the lid is currently closed. nil for
    /// caffeinate (which doesn't track lid state).
    public let lidClosedSeconds: TimeInterval?

    /// For lid-awake: duration of the most recent close-then-open cycle
    /// in this session, if any. Read straight from telemetry (no
    /// derivation needed). nil for caffeinate or sessions with no
    /// closed-then-opened cycle yet.
    public let lastLidCloseSeconds: TimeInterval?

    public init(
        elapsedSeconds: TimeInterval,
        lidClosedSeconds: TimeInterval?,
        lastLidCloseSeconds: TimeInterval?
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.lidClosedSeconds = lidClosedSeconds
        self.lastLidCloseSeconds = lastLidCloseSeconds
    }

    /// Derive metrics from raw inputs. Both the agent (which has a
    /// `LidTelemetry` value) and the menu app (which has a
    /// `StatusReport.FeatureSnapshot.LidExtras`) flatten their per-feature
    /// telemetry into these primitive arguments and call this single
    /// function.
    ///
    /// - Parameters:
    ///   - session: the session whose metrics we're computing.
    ///   - accumulatedLidClosedSeconds: closed-and-reopened total across
    ///     the session so far. Pass 0 for caffeinate (or any feature
    ///     without lid telemetry).
    ///   - lidClosedSince: the moment the lid was last closed and not
    ///     yet reopened, if currently closed. Pass nil for caffeinate.
    ///   - lastLidCloseSeconds: duration of the most recent
    ///     close-then-open cycle, if any. Pass nil for caffeinate.
    ///   - moment: the wall-clock moment to evaluate at. Defaults to
    ///     `Date()`; the agent passes `endedAt`, the view passes
    ///     `TimelineView`'s context date.
    ///   - tracksLid: whether lidClosedSeconds should be reported. False
    ///     for caffeinate — keeps the result nil instead of 0 so callers
    ///     can distinguish "no lid tracking" from "lid never closed".
    public static func compute(
        session: FeatureSession,
        accumulatedLidClosedSeconds: TimeInterval,
        lidClosedSince: Date?,
        lastLidCloseSeconds: TimeInterval?,
        at moment: Date = Date(),
        tracksLid: Bool
    ) -> SessionMetrics {
        let elapsed = max(0, moment.timeIntervalSince(session.enabledAt))

        let lidClosed: TimeInterval?
        if tracksLid {
            let inflight = lidClosedSince.map { max(0, moment.timeIntervalSince($0)) } ?? 0
            lidClosed = max(0, accumulatedLidClosedSeconds) + inflight
        } else {
            lidClosed = nil
        }

        return SessionMetrics(
            elapsedSeconds: elapsed,
            lidClosedSeconds: lidClosed,
            lastLidCloseSeconds: tracksLid ? lastLidCloseSeconds : nil
        )
    }
}
