import Foundation
import Testing
@testable import CodexBarCore

/// Ported case-for-case from the TypeScript implementation this policy came from, so the reasons
/// behind each rule survive the move. Most of them are bugs that actually shipped.
@Suite(.serialized)
struct AccountRankingTests {
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86400

    private struct Account: RankableAccount {
        let rankingName: String
        let rankingWindows: [RateWindow]
        let rankingNeedsReauth: Bool

        init(_ name: String, _ windows: [RateWindow], needsReauth: Bool = false) {
            self.rankingName = name
            self.rankingWindows = windows
            self.rankingNeedsReauth = needsReauth
        }
    }

    private static func window(
        _ percent: Double,
        resetsIn: TimeInterval? = nil,
        placeholder: Bool = false) -> RateWindow
    {
        RateWindow(
            usedPercent: percent,
            windowMinutes: nil,
            resetsAt: resetsIn.map { Self.now.addingTimeInterval($0) },
            resetDescription: nil,
            nextRegenPercent: nil,
            isSyntheticPlaceholder: placeholder)
    }

    private func order(_ accounts: [Account]) -> [String] {
        AccountRanking.rank(accounts, now: Self.now).map(\.rankingName)
    }

    // MARK: - Binding percent

    @Test
    func `binding percent is the highest across every window not just the weekly ones`() {
        // The account the old order put first: a 74% week hiding a 100% Fable week.
        let windows = [Self.window(22), Self.window(74), Self.window(100)]
        #expect(AccountRanking.bindingUsedPercent(windows, now: Self.now) == 100)
    }

    @Test
    func `a full session window binds just as hard as a full week`() {
        #expect(AccountRanking.bindingUsedPercent([Self.window(100), Self.window(3)], now: Self.now) == 100)
    }

    @Test
    func `no windows at all is nil which is not the same as zero percent`() {
        #expect(AccountRanking.bindingUsedPercent([], now: Self.now) == nil)
    }

    /// A placeholder stands in for a lane the provider never reported. Counting it as a real 0%
    /// would make an account that reported nothing look like the emptiest one on the board.
    @Test
    func `a placeholder window is not a real zero percent window`() {
        #expect(AccountRanking.bindingUsedPercent([Self.window(0, placeholder: true)], now: Self.now) == nil)
        #expect(AccountRanking.bindingUsedPercent(
            [Self.window(0, placeholder: true), Self.window(12)],
            now: Self.now) == 12)
    }

    /// Snapshots cached to disk are reloaded at launch with no age check, so after the app sits
    /// closed across a reset these stale numbers are all there is to rank on.
    @Test
    func `a window whose reset has already passed no longer counts`() {
        #expect(AccountRanking.bindingUsedPercent([Self.window(95, resetsIn: -60)], now: Self.now) == nil)
    }

    @Test
    func `an expired window does not bind over a live one`() {
        let windows = [Self.window(95, resetsIn: -60), Self.window(12, resetsIn: 3600)]
        #expect(AccountRanking.bindingUsedPercent(windows, now: Self.now) == 12)
    }

    // MARK: - Unblocks at

    @Test
    func `unblocks at ignores resets already in the past`() {
        let windows = [Self.window(100, resetsIn: -Self.hour), Self.window(100, resetsIn: 2 * Self.day)]
        #expect(AccountRanking.unblocksAt(windows, now: Self.now) == Self.now.addingTimeInterval(2 * Self.day))
    }

    @Test
    func `no future reset is nil so it sorts last`() {
        #expect(AccountRanking.unblocksAt([Self.window(100)], now: Self.now) == nil)
    }

    @Test
    func `a window with room left says nothing about when the block lifts`() {
        // The week is what stopped you; the session turning over in an hour gives you nothing to
        // spend when the week has been full since Tuesday.
        let windows = [Self.window(12, resetsIn: Self.hour), Self.window(100, resetsIn: 5 * Self.day)]
        #expect(AccountRanking.unblocksAt(windows, now: Self.now) == Self.now.addingTimeInterval(5 * Self.day))
    }

    @Test
    func `every blocking window has to turn over not just the first`() {
        let windows = [Self.window(100, resetsIn: Self.hour), Self.window(100, resetsIn: 5 * Self.day)]
        #expect(AccountRanking.unblocksAt(windows, now: Self.now) == Self.now.addingTimeInterval(5 * Self.day))
    }

    // MARK: - Ranking

    @Test
    func `most headroom first because the emptiest account is the one to use`() {
        #expect(self.order([
            Account("work", [Self.window(0), Self.window(71, resetsIn: 2 * Self.day)]),
            Account("personal", [Self.window(9, resetsIn: Self.hour), Self.window(2, resetsIn: 7 * Self.day)]),
            Account("starter", [Self.window(11, resetsIn: 5 * Self.hour), Self.window(11, resetsIn: 7 * Self.day)]),
        ]) == ["personal", "starter", "work"])
    }

    /// Under the old soonest-reset-first order this account led the board at 100% used.
    @Test
    func `a soon reset does not float an account up`() {
        #expect(self.order([
            Account("hello", [
                Self.window(22, resetsIn: 20 * 60),
                Self.window(74, resetsIn: 2 * Self.day),
                Self.window(100, resetsIn: 2 * Self.day),
            ]),
            Account("personal", [Self.window(9, resetsIn: Self.hour), Self.window(2, resetsIn: 7 * Self.day)]),
        ]) == ["personal", "hello"])
    }

    @Test
    func `blocked accounts sort last soonest to free up first`() {
        #expect(self.order([
            Account("blocked-late", [Self.window(100, resetsIn: 5 * Self.day)]),
            Account("blocked-soon", [Self.window(100, resetsIn: Self.day)]),
            Account("usable", [Self.window(99, resetsIn: 6 * Self.day)]),
        ]) == ["usable", "blocked-soon", "blocked-late"])
    }

    /// Every account here is blocked, so row 0 is the suggestion whether it deserves to be or not.
    @Test
    func `soonest means the block lifting not any window turning over`() {
        #expect(self.order([
            Account("week-long", [Self.window(30, resetsIn: Self.hour), Self.window(100, resetsIn: 5 * Self.day)]),
            Account(
                "back-tomorrow",
                [Self.window(100, resetsIn: 2 * Self.hour), Self.window(100, resetsIn: Self.day)]),
        ]) == ["back-tomorrow", "week-long"])
    }

    @Test
    func `ninety nine percent is still usable and outranks anything blocked`() {
        #expect(self.order([
            Account("full", [Self.window(100, resetsIn: Self.hour)]),
            Account("nearly", [Self.window(99, resetsIn: 6 * Self.day)]),
        ]) == ["nearly", "full"])
    }

    @Test
    func `accounts with no usable data sort after everything by name`() {
        #expect(self.order([
            Account("zed", []),
            Account("spare", []),
            Account("blocked", [Self.window(100, resetsIn: Self.day)]),
            Account("live", [Self.window(50, resetsIn: 3 * Self.day)]),
        ]) == ["live", "blocked", "spare", "zed"])
    }

    @Test
    func `equal headroom stays alphabetical so refreshes do not shuffle the board`() {
        #expect(self.order([
            Account("beta", [Self.window(40, resetsIn: Self.day)]),
            Account("alpha", [Self.window(40, resetsIn: 5 * Self.day)]),
        ]) == ["alpha", "beta"])
    }

    // MARK: - A dead login does not lead the board

    /// A re-auth account keeps serving its last payload so the card can still show what it knew.
    /// To a ranker reading only numbers that is indistinguishable from a live account, so a login
    /// that died at 12% used sorted ahead of every account that actually works.
    @Test
    func `cached numbers do not rank a dead login above accounts that work`() {
        #expect(self.order([
            Account("expired", [Self.window(12)], needsReauth: true),
            Account("live", [Self.window(40)]),
        ]) == ["live", "expired"])
    }

    @Test
    func `a dead login ranks below a blocked account too since that one frees up on its own`() {
        #expect(self.order([
            Account("expired", [Self.window(3)], needsReauth: true),
            Account("maxed", [Self.window(100, resetsIn: Self.day)]),
        ]) == ["maxed", "expired"])
    }

    @Test
    func `two dead logins are alphabetical like every other unknown`() {
        #expect(self.order([
            Account("zed", [Self.window(1)], needsReauth: true),
            Account("abe", [Self.window(99)], needsReauth: true),
        ]) == ["abe", "zed"])
    }

    @Test
    func `ranking is pure and leaves the callers array alone`() {
        let input = [
            Account("hot", [Self.window(90, resetsIn: Self.day)]),
            Account("cold", [Self.window(10, resetsIn: Self.day)]),
        ]
        _ = AccountRanking.rank(input, now: Self.now)
        #expect(input.map(\.rankingName) == ["hot", "cold"])
    }
}
