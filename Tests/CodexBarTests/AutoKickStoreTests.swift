import Foundation
import Testing
@testable import CodexBar

/// The store's whole job is to answer "how full was the window that just ended". Getting that
/// wrong in the high direction sends a message on the user's account for a week they never had,
/// so these tests are mostly about a peak not outliving the window it measured.
@Suite(.serialized)
@MainActor
struct AutoKickStoreTests {
    private func makeStore(suite: String) throws -> AutoKickStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AutoKickStore(defaults: defaults)
    }

    private static let key = "claude|someone@example.com"
    private static let weekOne = "1000"
    private static let weekTwo = "2000"

    @Test
    func `the peak is the highest sample within one window`() throws {
        let store = try self.makeStore(suite: "AutoKickStoreTests-highest")
        store.recordWeeklyUsage(20, for: Self.key, windowID: Self.weekOne)
        store.recordWeeklyUsage(85, for: Self.key, windowID: Self.weekOne)
        store.recordWeeklyUsage(40, for: Self.key, windowID: Self.weekOne)

        #expect(store.peakForEndedWindow(key: Self.key) == 85)
    }

    /// The regression this file exists for. With the app closed across a turnover, no reset event
    /// fires and nothing clears the peak — so a quiet week must not inherit a busy week's number
    /// just because the busy one was higher.
    @Test
    func `a peak does not survive into a window it did not measure`() throws {
        let store = try self.makeStore(suite: "AutoKickStoreTests-survive")
        store.recordWeeklyUsage(90, for: Self.key, windowID: Self.weekOne)

        // Relaunch, a week later, into a window the store has never seen.
        store.recordWeeklyUsage(5, for: Self.key, windowID: Self.weekTwo)

        #expect(store.peakForEndedWindow(key: Self.key) == 5)
    }

    /// The reset event usually lands while the snapshot still names the window that ended, which
    /// is the case auto-kick depends on.
    @Test
    func `a turnover reports the ended window's peak`() throws {
        let store = try self.makeStore(suite: "AutoKickStoreTests-order-reset")
        store.recordWeeklyUsage(90, for: Self.key, windowID: Self.weekOne)

        #expect(store.peakForEndedWindow(key: Self.key) == 90)
    }

    /// The accepted limitation, pinned so it cannot change by accident. When a sample carrying the
    /// new window arrives *before* the reset event, the record has already rolled and the ended
    /// window's peak is gone — so the decision sees the new window's opening percentage and stays
    /// quiet. Losing a kick is the correct direction to fail: the alternative is a message sent on
    /// the user's account for a week that was never busy.
    @Test
    func `a sample from the new window arriving first costs the kick, not a false one`() throws {
        let store = try self.makeStore(suite: "AutoKickStoreTests-order-sample")
        store.recordWeeklyUsage(90, for: Self.key, windowID: Self.weekOne)
        store.recordWeeklyUsage(2, for: Self.key, windowID: Self.weekTwo)

        #expect(store.peakForEndedWindow(key: Self.key) == 2)
    }

    @Test
    func `accounts do not share a peak`() throws {
        let store = try self.makeStore(suite: "AutoKickStoreTests-accounts")
        store.recordWeeklyUsage(90, for: "claude|a@example.com", windowID: Self.weekOne)
        store.recordWeeklyUsage(5, for: "claude|b@example.com", windowID: Self.weekOne)

        #expect(store.peakForEndedWindow(key: "claude|b@example.com") == 5)
    }

    @Test
    func `clearing a peak forgets it entirely`() throws {
        let store = try self.makeStore(suite: "AutoKickStoreTests-clear")
        store.recordWeeklyUsage(90, for: Self.key, windowID: Self.weekOne)
        store.clearWeeklyPeak(for: Self.key)

        #expect(store.peakForEndedWindow(key: Self.key) == nil)
    }

    /// Defaults written before windows were tracked hold a bare number. It reads as a peak of
    /// unknown window, which the next identified sample rolls over rather than competing with.
    @Test
    func `a peak stored in the old shape is read and then rolled over`() throws {
        let suite = "AutoKickStoreTests-legacy"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set([Self.key: NSNumber(value: 77)], forKey: "fork.autoKick.weeklyPeaks")
        let store = AutoKickStore(defaults: defaults)

        #expect(store.peakForEndedWindow(key: Self.key) == 77)

        store.recordWeeklyUsage(3, for: Self.key, windowID: Self.weekOne)
        #expect(store.peakForEndedWindow(key: Self.key) == 3)
    }

    @Test
    func `a non-finite sample is ignored`() throws {
        let store = try self.makeStore(suite: "AutoKickStoreTests-nonfinite")
        store.recordWeeklyUsage(40, for: Self.key, windowID: Self.weekOne)
        store.recordWeeklyUsage(.nan, for: Self.key, windowID: Self.weekOne)
        store.recordWeeklyUsage(.infinity, for: Self.key, windowID: Self.weekOne)

        #expect(store.peakForEndedWindow(key: Self.key) == 40)
    }
}
