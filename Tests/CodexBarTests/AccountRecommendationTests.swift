import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Mostly about when the line stays *silent*. A recommendation that appears when there is no real
/// choice, or that points at the account already in use, is noise in a menu people open constantly.
@MainActor
struct AccountRecommendationTests {
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func account(
        _ label: String,
        percent: Double?,
        isActive: Bool = false,
        error: String? = nil) -> ProviderAccountUsageSnapshot
    {
        let window = percent.map {
            RateWindow(
                usedPercent: $0,
                windowMinutes: nil,
                resetsAt: Self.now.addingTimeInterval(3600),
                resetDescription: nil,
                nextRegenPercent: nil,
                isSyntheticPlaceholder: false)
        }
        return ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: label),
            provider: .claude,
            displayLabel: label,
            isActive: isActive,
            canActivate: !isActive,
            snapshot: window.map {
                UsageSnapshot(
                    primary: $0,
                    secondary: nil,
                    tertiary: nil,
                    providerCost: nil,
                    updatedAt: Self.now,
                    identity: nil)
            },
            error: error,
            sourceLabel: nil)
    }

    @Test
    func `recommends the account with the most headroom`() {
        let line = AccountRecommendation.line(
            for: [
                self.account("busy", percent: 80, isActive: true),
                self.account("spare", percent: 5),
            ],
            now: Self.now)

        let unwrapped = try? #require(line)
        #expect(unwrapped?.contains("spare") == true)
    }

    @Test
    func `says nothing when there is only one account`() {
        #expect(AccountRecommendation.line(for: [self.account("solo", percent: 5)], now: Self.now) == nil)
    }

    @Test
    func `says nothing when the best account is already the active one`() {
        let line = AccountRecommendation.line(
            for: [
                self.account("spare", percent: 5, isActive: true),
                self.account("busy", percent: 80),
            ],
            now: Self.now)

        #expect(line == nil)
    }

    /// When everything is full the top row is merely the least bad, so "use this" would be wrong.
    @Test
    func `says nothing when every account is blocked`() {
        let line = AccountRecommendation.line(
            for: [
                self.account("full-a", percent: 100, isActive: true),
                self.account("full-b", percent: 100),
            ],
            now: Self.now)

        #expect(line == nil)
    }

    @Test
    func `says nothing when no account reports a usable number`() {
        let line = AccountRecommendation.line(
            for: [
                self.account("mystery-a", percent: nil, isActive: true),
                self.account("mystery-b", percent: nil),
            ],
            now: Self.now)

        #expect(line == nil)
    }

    /// A failed refresh still shows its last numbers, which must not win the recommendation.
    @Test
    func `does not recommend an account whose refresh failed`() {
        let line = AccountRecommendation.line(
            for: [
                self.account("working", percent: 40, isActive: true),
                self.account("broken", percent: 2, error: "unauthorized"),
            ],
            now: Self.now)

        #expect(line?.contains("broken") != true)
    }
}
