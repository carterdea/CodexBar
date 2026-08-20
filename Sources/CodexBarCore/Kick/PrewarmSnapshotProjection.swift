import Foundation

/// Turns a live usage snapshot into the two things ``AutoPrewarmDecision`` reads: the session lane
/// and one observation of every quota lane.
///
/// Separate from the coordinator that calls it because this is where the decision's guarantees are
/// actually won or lost. Every threshold in ``AutoPrewarmDecision`` is tested at its boundary, but
/// those tests feed hand-built values — so if this translation is wrong, none of them say anything
/// about what the app does.
extension UsageSnapshot {
    /// The 5-hour lane, or `nil` when the provider reported none.
    ///
    /// A synthetic placeholder is Claude's stand-in for a null `five_hour`, i.e. an account with no
    /// session lane at all. It must not reach the decision as a real window with no reset instant,
    /// because that is exactly the shape of a dormant account ready to prewarm — so every account
    /// that had never been used would look permanently ready, forever.
    ///
    /// A genuine session that is merely idle is *not* a placeholder and is returned as-is, which is
    /// the case the whole feature exists to find.
    public var prewarmSessionWindow: RateWindow? {
        guard let primary, !primary.isSyntheticPlaceholder else { return nil }
        return primary
    }

    /// Used-percent per quota lane, keyed so the same lane lines up between two refreshes.
    ///
    /// The positional lanes are keyed by position and named ones by their own id. That is what
    /// makes a model-scoped quota comparable to itself rather than to whichever lane happened to
    /// sort next to it — comparing two different lanes would manufacture rises and falls out of
    /// nothing.
    ///
    /// Lanes with nothing real to report are left out rather than recorded as zero: a placeholder
    /// stands in for a lane the provider never sent, `usageKnown == false` marks a named window
    /// whose reset time arrived before its usage, and a non-finite percent is not a measurement.
    /// Recording any of them as 0 would read as a fall now and a rise on the next refresh.
    public var prewarmLanes: [String: Double] {
        var lanes: [String: Double] = [:]
        func add(_ name: String, _ window: RateWindow?) {
            guard let window, !window.isSyntheticPlaceholder, window.usedPercent.isFinite else { return }
            lanes[name] = window.usedPercent
        }
        add("primary", self.primary)
        add("secondary", self.secondary)
        add("tertiary", self.tertiary)
        for named in self.extraRateWindows ?? [] where named.usageKnown {
            add("named:\(named.id)", named.window)
        }
        return lanes
    }
}

/// The rolling window of observations one account's rise is detected in.
///
/// Bounded twice on purpose. By age, because a sample too old to pair with anything can never
/// contribute to a decision; and by count, because the refresh that feeds it is not on a guaranteed
/// cadence and an unbounded ring would grow with whatever rate the app happens to refresh at.
public enum PrewarmSampleRing {
    /// The oldest sample still worth keeping, measured back from now.
    ///
    /// Twice the activity window, not once. A rise is a *pair*: the later sample has to be within
    /// one activity window of now and the earlier one within another of the later. Keeping only one
    /// window would throw away the earlier half of every pair that still counts.
    public static let horizon: TimeInterval = 2 * AutoPrewarmDecision.activityWindow

    /// A ceiling on retained samples, as a guard rather than a policy — at any sane refresh rate the
    /// age bound is what actually prunes. It exists so an unexpectedly chatty refresh cannot grow
    /// this without limit, and is far above the number of samples an hour can hold in practice.
    public static let capacity = 240

    /// Adds an observation, if there is one, and drops what can no longer matter.
    ///
    /// `sample` is optional so a refresh that produced nothing readable is a no-op rather than an
    /// observation of zero — the distinction the whole ring depends on.
    public static func appending(
        _ sample: PrewarmSample?,
        to series: [PrewarmSample],
        now: Date) -> [PrewarmSample]
    {
        var kept = series.filter { now.timeIntervalSince($0.at) <= self.horizon }
        if let sample, !sample.percentByLane.isEmpty {
            kept.append(sample)
        }
        if kept.count > self.capacity {
            kept.removeFirst(kept.count - self.capacity)
        }
        return kept
    }
}
