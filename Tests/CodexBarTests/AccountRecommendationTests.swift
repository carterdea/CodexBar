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

    // MARK: - Codex

    @Test
    func `Codex accounts are ranked by headroom`() throws {
        let entries = Self.codexUsageMenuEntries(rows: [
            Self.codexRow("busy@example.com", percent: 80, isActive: true),
            Self.codexRow("spare@example.com", percent: 5),
        ])

        guard case let .text(title, style) = try #require(entries.first) else {
            Issue.record("Expected a Codex recommendation menu entry")
            return
        }
        #expect(title.contains("spare@example.com"))
        #expect(style == .primary)
    }

    @Test
    func `says nothing when the active Codex account already has the most headroom`() {
        let entries = Self.codexUsageMenuEntries(rows: [
            Self.codexRow("spare@example.com", percent: 5, isActive: true),
            Self.codexRow("busy@example.com", percent: 80),
        ])

        #expect(entries.isEmpty)
    }

    /// The segmented layout fetches only the active account, so the store holds at most one row and
    /// there is nothing to compare against.
    @Test
    func `says nothing when only one Codex account has usage`() {
        let entries = Self.codexUsageMenuEntries(rows: [
            Self.codexRow("solo@example.com", percent: 5, isActive: true),
        ])

        #expect(entries.isEmpty)
    }

    /// Codex labels are emails, and this line sits directly above cards that redact theirs.
    @Test
    func `redacts the recommended Codex account when personal info is hidden`() throws {
        let entries = Self.codexUsageMenuEntries(
            rows: [
                Self.codexRow("busy@example.com", percent: 80, isActive: true),
                Self.codexRow("spare@example.com", percent: 5),
            ],
            hidePersonalInfo: true)

        guard case let .text(title, _) = try #require(entries.first) else {
            Issue.record("Expected a Codex recommendation menu entry")
            return
        }
        #expect(!title.contains("spare@example.com"))
    }

    // MARK: - Codex fixtures

    private static func codexRow(
        _ email: String,
        percent: Double,
        isActive: Bool = false) -> CodexAccountUsageSnapshot
    {
        CodexAccountUsageSnapshot(
            account: CodexVisibleAccount(
                id: email,
                email: email,
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: isActive,
                isLive: isActive,
                canReauthenticate: false,
                canRemove: false),
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: percent,
                    windowMinutes: 300,
                    resetsAt: self.now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                providerCost: nil,
                updatedAt: self.now,
                identity: nil),
            error: nil,
            sourceLabel: "test")
    }

    /// Drives the real provider hook rather than the projection alone, so the wiring itself is covered.
    private static func codexUsageMenuEntries(
        rows: [CodexAccountUsageSnapshot],
        hidePersonalInfo: Bool = false) -> [ProviderMenuEntry]
    {
        let settings = testSettingsStore(suiteName: "AccountRecommendationTests-codex")
        settings.hidePersonalInfo = hidePersonalInfo
        // Credits are the rest of this hook; leaving them off proves the recommendation stands alone.
        settings.showOptionalCreditsAndExtraUsage = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.codexAccountSnapshots = rows

        var entries: [ProviderMenuEntry] = []
        CodexProviderImplementation().appendUsageMenuEntries(
            context: ProviderMenuUsageContext(
                provider: .codex,
                store: store,
                settings: settings,
                metadata: ProviderDescriptorRegistry.descriptor(for: .codex).metadata,
                snapshot: rows.first?.snapshot),
            entries: &entries)
        return entries
    }
}
