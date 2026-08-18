import Foundation
import Testing
@testable import CodexBarCore

/// This decision spends the user's quota without them asking, so nearly every case here is about
/// it staying silent. A missed kick costs a slightly later window; a wrong one sends a message on
/// someone's account that they did not ask for.
@Suite(.serialized)
struct AutoKickDecisionTests {
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    @Test
    func `a heavily used window that turned over is kicked`() {
        #expect(AutoKickDecision.shouldKick(
            isEnabled: true,
            peakPercent: 90,
            lastAutoKickedAt: nil,
            now: Self.now))
    }

    @Test
    func `the setting being off beats every other condition`() {
        #expect(!AutoKickDecision.shouldKick(
            isEnabled: false,
            peakPercent: 100,
            lastAutoKickedAt: nil,
            now: Self.now))
    }

    /// A window with room left never stopped anyone, so replacing it early buys nothing and still
    /// sends a message.
    @Test
    func `a lightly used window is not worth a message`() {
        #expect(!AutoKickDecision.shouldKick(
            isEnabled: true,
            peakPercent: 20,
            lastAutoKickedAt: nil,
            now: Self.now))
    }

    @Test
    func `the threshold itself counts as heavily used`() {
        #expect(AutoKickDecision.shouldKick(
            isEnabled: true,
            peakPercent: AutoKickDecision.heavilyUsedPercent,
            lastAutoKickedAt: nil,
            now: Self.now))
    }

    /// An app started after the reset knows nothing about the window that just ended. Treating
    /// "never observed" as "empty" would be a guess; treating it as "full" would send a message on
    /// every launch that happens to follow a turnover.
    @Test
    func `a window that was never observed is not guessed at`() {
        #expect(!AutoKickDecision.shouldKick(
            isEnabled: true,
            peakPercent: nil,
            lastAutoKickedAt: nil,
            now: Self.now))
    }

    // MARK: - Not twice for the same turnover

    @Test
    func `a second kick too soon after the first is refused`() {
        let recent = Self.now.addingTimeInterval(-AutoKickDecision.minimumInterval + 60)
        #expect(!AutoKickDecision.shouldKick(
            isEnabled: true,
            peakPercent: 95,
            lastAutoKickedAt: recent,
            now: Self.now))
    }

    @Test
    func `the next weekly turnover is far enough away to be allowed`() {
        let lastWeek = Self.now.addingTimeInterval(-7 * 86400)
        #expect(AutoKickDecision.shouldKick(
            isEnabled: true,
            peakPercent: 95,
            lastAutoKickedAt: lastWeek,
            now: Self.now))
    }

    /// Weekly windows are seven days apart, so the guard has to be comfortably shorter than that
    /// and comfortably longer than any duplicate detection within one turnover.
    @Test
    func `the minimum interval sits well inside a weekly window`() {
        #expect(AutoKickDecision.minimumInterval < 7 * 86400)
        #expect(AutoKickDecision.minimumInterval >= 3600)
    }
}
