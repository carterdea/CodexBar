import CodexBarCore
import Foundation

extension ProviderAccountUsageSnapshot: RankableAccount {
    public var rankingName: String {
        self.displayLabel
    }

    /// Every window the account reported, flattened. `NamedRateWindow.usageKnown` is dropped here
    /// because an unknown value carries no percent worth ranking on.
    public var rankingWindows: [RateWindow] {
        guard let snapshot else { return [] }
        var windows = [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self)
        windows.append(contentsOf: (snapshot.extraRateWindows ?? []).filter(\.usageKnown).map(\.window))
        return windows
    }

    /// An approximation of "cannot be relied on". Upstream does not model re-auth as its own state
    /// per account, but the hazard the ranking guards against is the same either way: an account
    /// whose last refresh failed still shows the numbers it knew, and those numbers must not let it
    /// lead the board.
    public var rankingNeedsReauth: Bool {
        self.error != nil
    }
}

/// Answers "which of these accounts should I use next", as one line of menu text.
///
/// Deliberately not a badge on the account card: that would mean editing the shared card view and
/// its model, and this fork keeps its footprint on upstream files small so merges stay cheap.
@MainActor
enum AccountRecommendation {
    /// The line to show, or `nil` when there is nothing useful to say.
    ///
    /// Silent unless there is a real choice to make: one account is not a recommendation, and
    /// pointing at the account already in use is noise.
    ///
    /// `hidePersonalInfo` is honoured because `displayLabel` is usually an email address, and this
    /// line sits in the menu directly above account cards that already redact theirs. Leaving it
    /// alone would quietly defeat the setting for anyone who turned it on to share their screen.
    static func line(
        for accounts: [ProviderAccountUsageSnapshot],
        hidePersonalInfo: Bool = false,
        now: Date = Date()) -> String?
    {
        guard accounts.count > 1 else { return nil }

        let ranked = AccountRanking.rank(accounts, now: now)
        guard let best = ranked.first, !best.isActive else { return nil }

        // Only recommend an account that is actually usable. When everything is blocked or
        // unreadable the top row is merely the least bad, and saying "use this" would be wrong.
        guard let percent = AccountRanking.bindingUsedPercent(best.rankingWindows),
              percent < AccountRanking.blockedPercent
        else { return nil }

        let label = PersonalInfoRedactor.redactEmails(in: best.displayLabel, isEnabled: hidePersonalInfo)
            ?? best.displayLabel
        return String(
            format: L("use_next_format"),
            label,
            UsageFormatter.percentString(percent))
    }
}
