import Foundation

/// One observation of an account's quota lanes, taken from a live usage refresh.
///
/// Per lane rather than a single binding number, because the binding lane is usually the weekly one
/// and it barely moves. An hour of real work can raise the 5-hour lane by twenty points while the
/// weekly lane it sits behind climbs by a fraction of one — so a series of binding percentages
/// reads as flat for exactly the account the user is typing into. The rise is what identifies that
/// account, so it has to be looked for in every lane.
public struct PrewarmSample: Sendable, Equatable {
    public let at: Date
    /// Used-percent per quota lane, keyed by a name that is stable across refreshes.
    public let percentByLane: [String: Double]

    public init(at: Date, percentByLane: [String: Double]) {
        self.at = at
        self.percentByLane = percentByLane
    }
}

/// One account as the prewarm decision sees it. Deliberately not a provider type: the decision is
/// arithmetic over windows and timestamps, and keeping it that way is what makes it testable
/// without a live account.
public struct PrewarmAccount: Sendable, Equatable {
    /// Stable identity. Used to address the account afterwards and to break ties so the choice
    /// cannot shuffle between refreshes.
    public let key: String
    /// Every quota window the account reported, for the binding percentage and headroom.
    public let windows: [RateWindow]
    /// The 5-hour lane, or `nil` when the provider did not report one at all.
    ///
    /// "Did not report one" is not the same as "reported an empty one", and the difference decides
    /// this feature. A synthetic placeholder — Claude's stand-in for a null `five_hour` — must
    /// arrive here as `nil`, or every account that has never been used looks like a running window
    /// with no reset time and gets kicked forever.
    public let sessionWindow: RateWindow?
    /// Recent observations, oldest first. Sorted defensively by ``AutoPrewarmDecision``.
    public let samples: [PrewarmSample]
    /// When this account was last prewarmed, across launches.
    public let lastPrewarmedAt: Date?
    /// Whether a session window can actually be started on this account.
    ///
    /// Ranking an account the caller would refuse to send on is not a wasted cycle, it is a
    /// permanent stall: it wins on headroom, takes the shared cooldown with it, and nothing about
    /// it changes before the next cycle, so it wins again and the account that *can* be reached is
    /// never prewarmed at all.
    ///
    /// Read only when choosing a candidate, never when identifying the account in use. Whether a
    /// credential can send a message says nothing about whether someone is typing into it, and the
    /// spare belonging to an unkickable account is exactly the one worth starting.
    public let canStartSessionWindow: Bool

    public init(
        key: String,
        windows: [RateWindow],
        sessionWindow: RateWindow?,
        samples: [PrewarmSample],
        lastPrewarmedAt: Date?,
        canStartSessionWindow: Bool)
    {
        self.key = key
        self.windows = windows
        self.sessionWindow = sessionWindow
        self.samples = samples
        self.lastPrewarmedAt = lastPrewarmedAt
        self.canStartSessionWindow = canStartSessionWindow
    }
}

/// Picks the dormant account whose 5-hour clock should be started now, so that the switch the user
/// is about to make lands on a window that is already running rather than one that starts then.
///
/// Pure, and separate from the plumbing, for the same reason as ``AutoKickDecision``: this is the
/// decision that spends the user's quota without them asking. Every threshold below exists to stop
/// it firing when it should not, and each is tested at its boundary.
///
/// Callers pass **one provider's** accounts. A Codex account filling up says nothing about how much
/// Claude capacity is left, so mixing providers here would let one provider's activity spend the
/// other's quota.
public enum AutoPrewarmDecision {
    /// How full the account being worked in must be before its replacement is worth starting.
    ///
    /// Below this there is no switch coming, and a prewarm that is not followed by a switch is a
    /// 5-hour window opened for nothing.
    public static let triggerPercent: Double = 85

    /// How much room a candidate must have left to be worth switching to.
    ///
    /// Starting the clock on an account that is nearly full buys a window the user cannot spend,
    /// and burns the one thing a dormant account has: an unstarted window it can open whenever it
    /// is actually needed.
    public static let minimumHeadroomPercent: Double = 15

    /// The rise, in percentage points, that marks an account as the one being used.
    ///
    /// Small enough that a few minutes of real work clears it, large enough that provider-side
    /// rounding does not.
    public static let riseThresholdPoints: Double = 0.5

    /// How recent a rise has to be to still mean "this is the account in use", and also the widest
    /// gap between two samples that can be compared at all.
    ///
    /// Two samples further apart than this say nothing about *when* the usage moved between them,
    /// so a pair straddling a long gap is not evidence of current activity.
    public static let activityWindow: TimeInterval = 30 * 60

    /// The shortest gap allowed between two prewarms of the same account.
    ///
    /// One 5-hour window long, because that is exactly the thing being started: a second prewarm
    /// inside the first window's lifetime cannot start anything, it only sends another message.
    public static let cooldown: TimeInterval = 5 * 3600

    /// When this account's usage last rose, or `nil` if it never did within a comparable gap.
    ///
    /// Walks newest-first and stops at the first rise, so the answer is the most recent one.
    ///
    /// Each sample is compared against **every** earlier one still inside the activity window, not
    /// just the one before it. Adjacent pairs alone would make detection worse the more often the
    /// app refreshes: the same hour of work split across more samples puts less of the climb
    /// between any two of them, so a steady 20.0 -> 20.3 -> 20.6 clears the threshold over half an
    /// hour while no single step comes close. The rule is a rise between two samples at most one
    /// window apart, and that is what this looks for.
    public static func lastRise(in samples: [PrewarmSample]) -> Date? {
        let ordered = samples.sorted { $0.at < $1.at }
        guard ordered.count >= 2 else { return nil }

        for laterIndex in stride(from: ordered.count - 1, through: 1, by: -1) {
            let later = ordered[laterIndex]
            for earlierIndex in stride(from: laterIndex - 1, through: 0, by: -1) {
                let earlier = ordered[earlierIndex]
                // Sorted, so the first predecessor out of range puts every older one out too.
                guard later.at.timeIntervalSince(earlier.at) <= self.activityWindow else { break }
                if self.rose(from: earlier, to: later) { return later.at }
            }
        }
        return nil
    }

    /// The account being worked in: one whose usage rose recently, and the fullest of those.
    ///
    /// Fullest rather than most-recently-risen because the question this answers is "is a switch
    /// coming", and the account closest to its wall is the one that will force it.
    public static func activeAccount(among accounts: [PrewarmAccount], now: Date) -> PrewarmAccount? {
        accounts
            .compactMap { account -> (account: PrewarmAccount, percent: Double)? in
                guard let rise = self.lastRise(in: account.samples) else { return nil }
                let age = now.timeIntervalSince(rise)
                guard age >= 0, age < self.activityWindow else { return nil }
                guard let percent = AccountRanking.bindingUsedPercent(account.windows, now: now) else { return nil }
                return (account, percent)
            }
            .max { lhs, rhs in
                if lhs.percent != rhs.percent { return lhs.percent < rhs.percent }
                // Reversed so the *lowest* key wins the `max`, matching every other tie-break here.
                return lhs.account.key > rhs.account.key
            }?
            .account
    }

    /// The account to prewarm, or `nil` when nothing should be sent.
    ///
    /// Returns the account rather than a bare yes/no because "which one" is part of the decision,
    /// and a caller that re-derived it could pick a different account than the one that was judged.
    /// - Parameter lastPrewarmOfAnyAccountAt: when *any* account was last prewarmed. One at a time
    ///   is part of the decision, not an extra threshold: the user can only occupy one 5-hour
    ///   window at a time, so warming a second account before the first has been switched to is
    ///   pure waste. The reference implementation gets this for free by deciding once per cron tick;
    ///   here the decision runs on every usage refresh, and a successful prewarm triggers a refresh
    ///   of its own — so without this, one busy account would walk down the list and message every
    ///   dormant one.
    public static func candidate(
        isEnabled: Bool,
        accounts: [PrewarmAccount],
        lastPrewarmOfAnyAccountAt: Date?,
        now: Date) -> PrewarmAccount?
    {
        guard isEnabled else { return nil }
        if let lastPrewarmOfAnyAccountAt,
           now.timeIntervalSince(lastPrewarmOfAnyAccountAt) < self.cooldown
        {
            return nil
        }
        guard let active = self.activeAccount(among: accounts, now: now) else { return nil }
        guard let activePercent = AccountRanking.bindingUsedPercent(active.windows, now: now),
              activePercent >= self.triggerPercent
        else { return nil }

        return accounts
            .compactMap { account -> (account: PrewarmAccount, headroom: Double)? in
                guard account.key != active.key else { return nil }
                guard account.canStartSessionWindow else { return nil }
                guard let session = account.sessionWindow else { return nil }
                // A reset instant means the 5-hour clock is already running. Kicking then spends a
                // message to start something that started without us, which is the one failure this
                // feature has no excuse for.
                guard session.resetsAt == nil else { return nil }
                guard let percent = AccountRanking.bindingUsedPercent(account.windows, now: now) else { return nil }
                let headroom = 100 - percent
                guard headroom > self.minimumHeadroomPercent else { return nil }
                if let last = account.lastPrewarmedAt, now.timeIntervalSince(last) < self.cooldown {
                    return nil
                }
                return (account, headroom)
            }
            .max { lhs, rhs in
                if lhs.headroom != rhs.headroom { return lhs.headroom < rhs.headroom }
                return lhs.account.key > rhs.account.key
            }?
            .account
    }

    // MARK: - Internals

    /// Whether any lane the two samples share climbed by more than the threshold.
    ///
    /// Lanes present in only one of the two are skipped: a lane appearing for the first time is not
    /// a rise from zero, it is a lane nobody measured before.
    private static func rose(from earlier: PrewarmSample, to later: PrewarmSample) -> Bool {
        for (lane, laterPercent) in later.percentByLane {
            guard let earlierPercent = earlier.percentByLane[lane] else { continue }
            guard laterPercent.isFinite, earlierPercent.isFinite else { continue }
            if laterPercent > earlierPercent + self.riseThresholdPoints { return true }
        }
        return false
    }
}
