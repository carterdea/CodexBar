import Foundation

/// Anything that can be placed in the "use this one next" order. A protocol rather than a concrete
/// type so callers rank their own account models and get their own type back.
public protocol RankableAccount {
    /// Stable identity, used only to break ties so the order cannot shuffle between refreshes.
    var rankingName: String { get }

    /// Every quota window this account reported: session, weekly, and any model-scoped ones.
    var rankingWindows: [RateWindow] { get }

    /// Whether the account needs signing in again. Kept separate from the numbers on purpose —
    /// see ``AccountRanking/rank(_:now:)``.
    var rankingNeedsReauth: Bool { get }
}

/// Orders accounts by "which should I use next" — most headroom first.
///
/// One place decides this so the order is a property of the data rather than something each view
/// re-derives differently.
public enum AccountRanking {
    /// At 100% of its binding window an account has nothing left to spend.
    public static let blockedPercent: Double = 100

    /// The used-% that *binds* an account: the highest across every window it reported.
    ///
    /// The highest, not the weekly one, because the binding window is whichever stops you first —
    /// a 100% Fable week blocks Fable work from behind a 74% overall week, and a full 5-hour
    /// window blocks everything for the next few hours.
    ///
    /// `nil` means no usable number at all, which is not the same as 0%.
    public static func bindingUsedPercent(_ windows: [RateWindow]) -> Double? {
        var binding: Double?
        for window in self.countableWindows(windows) {
            if binding == nil || window.usedPercent > (binding ?? 0) {
                binding = window.usedPercent
            }
        }
        return binding
    }

    /// When a blocked account's block lifts: the **last** of its actually-blocked windows to turn
    /// over. `nil` when none of them names a future reset, which sorts last.
    ///
    /// Windows with room left say nothing about it — a weekly window at 100% resetting Friday keeps
    /// the account unusable all week however soon its 12%-used session window turns over. And the
    /// last rather than the first, because every blocking window has to turn over before there is
    /// anything to spend.
    ///
    /// A model-scoped block stops only its own model, so an account held here by one of those may
    /// be partly usable sooner than this says. Among accounts that are all blocked anyway, that is
    /// the safe direction to be wrong in.
    public static func unblocksAt(_ windows: [RateWindow], now: Date) -> Date? {
        var latest: Date?
        for window in self.countableWindows(windows) where window.usedPercent >= self.blockedPercent {
            guard let reset = window.resetsAt, reset > now else { continue }
            if latest == nil || reset > (latest ?? reset) { latest = reset }
        }
        return latest
    }

    /// Ranks accounts, most headroom first. Pure: returns a new array.
    ///
    /// Three bands, in order:
    /// 1. **Usable** (binding < 100%), ascending by binding used-% — the emptiest account leads,
    ///    because it is the one you can work in longest before hitting a wall.
    /// 2. **Blocked** (binding >= 100%), ascending by when the block lifts — nothing to spend, so
    ///    the only question left is which frees up first.
    /// 3. **Unknown** — needs re-auth, or reported no number at all. Nothing to rank on.
    ///
    /// Name breaks every remaining tie so the list never shuffles between refreshes.
    ///
    /// Re-auth is checked *before* the numbers, because a dead login can still be holding one: the
    /// last usage payload stays visible so the card can show what it knew, and it is otherwise
    /// indistinguishable from a live one. Without this, a login that expired at 12% used looks like
    /// the emptiest account there is and leads the board — pointing the user at the one account
    /// they cannot spend anything in.
    public static func rank<T: RankableAccount>(_ accounts: [T], now: Date) -> [T] {
        accounts.enumerated().sorted { lhs, rhs in
            let leftBand = self.band(lhs.element)
            let rightBand = self.band(rhs.element)
            if leftBand != rightBand { return leftBand < rightBand }

            switch leftBand {
            case 0:
                let left = self.bindingUsedPercent(lhs.element.rankingWindows) ?? 0
                let right = self.bindingUsedPercent(rhs.element.rankingWindows) ?? 0
                if left != right { return left < right }
            case 1:
                let left = self.unblocksAt(lhs.element.rankingWindows, now: now)
                let right = self.unblocksAt(rhs.element.rankingWindows, now: now)
                if left != right {
                    // A missing reset means "no idea when", which belongs after every known one.
                    guard let left else { return false }
                    guard let right else { return true }
                    return left < right
                }
            default:
                break
            }

            let names = lhs.element.rankingName.localizedCompare(rhs.element.rankingName)
            if names != .orderedSame { return names == .orderedAscending }
            // Index last so the sort is total and equal rows keep their input order.
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - Internals

    /// A synthetic placeholder is a provider standing in for a lane it did not actually report.
    /// Counting one would read as a real 0%-used window, which is the emptiest thing on the board —
    /// so an account that reported nothing would lead it.
    private static func countableWindows(_ windows: [RateWindow]) -> [RateWindow] {
        windows.filter { !$0.isSyntheticPlaceholder && $0.usedPercent.isFinite }
    }

    private static func band(_ account: some RankableAccount) -> Int {
        if account.rankingNeedsReauth { return 2 }
        guard let binding = self.bindingUsedPercent(account.rankingWindows) else { return 2 }
        return binding >= self.blockedPercent ? 1 : 0
    }
}
