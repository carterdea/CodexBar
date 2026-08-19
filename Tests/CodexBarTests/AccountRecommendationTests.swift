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
    func `Codex accounts are ranked by headroom`() {
        let line = Self.codexRecommendation(rows: [
            Self.codexRow("busy@example.com", percent: 80, isActive: true),
            Self.codexRow("spare@example.com", percent: 5),
        ])

        #expect(line?.contains("spare@example.com") == true)
    }

    @Test
    func `says nothing when the active Codex account already has the most headroom`() {
        let line = Self.codexRecommendation(rows: [
            Self.codexRow("spare@example.com", percent: 5, isActive: true),
            Self.codexRow("busy@example.com", percent: 80),
        ])

        #expect(line == nil)
    }

    /// The segmented layout fetches only the active account, so the store holds at most one row and
    /// there is nothing to compare against.
    @Test
    func `says nothing when only one Codex account has usage`() {
        let line = Self.codexRecommendation(rows: [
            Self.codexRow("solo@example.com", percent: 5, isActive: true),
        ])

        #expect(line == nil)
    }

    /// Menu rendering must stay side-effect free: reading the visible-account projection here would
    /// load `auth.json`, parse JWTs, and hash fingerprints while the menu is being built. The rows
    /// already carry the projection's active flag, so the recommendation never needs to ask for it.
    @Test
    func `collecting Codex candidates never loads codex auth state`() {
        let loads = Counter()
        let line = Self.codexRecommendation(
            rows: [
                Self.codexRow("busy@example.com", percent: 80, isActive: true),
                Self.codexRow("spare@example.com", percent: 5),
            ],
            onReconciliationLoad: { loads.increment() })

        #expect(loads.value == 0)
        #expect(line != nil)
    }

    /// Codex labels are emails, and this line sits directly above cards that redact theirs.
    @Test
    func `redacts the recommended Codex account when personal info is hidden`() {
        let line = Self.codexRecommendation(
            rows: [
                Self.codexRow("busy@example.com", percent: 80, isActive: true),
                Self.codexRow("spare@example.com", percent: 5),
            ],
            hidePersonalInfo: true)

        #expect(line != nil)
        #expect(line?.contains("spare@example.com") != true)
    }

    /// The menu builds the line for whichever provider offers candidates, so the Codex hook only has
    /// to hand them over. This is the one test that walks the whole path.
    @Test
    func `the built menu shows the Codex recommendation`() {
        let rows = [
            Self.codexRow("busy@example.com", percent: 80, isActive: true),
            Self.codexRow("spare@example.com", percent: 5),
        ]
        let (store, settings) = Self.codexStore(rows: rows)

        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false,
            now: Self.now)
        let expected = AccountRecommendation.line(
            for: CodexProviderImplementation().rankableAccounts(context: Self.codexContext(
                store: store,
                settings: settings,
                rows: rows)),
            now: Self.now)

        let texts = descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(text, _) = entry else { return nil }
            return text
        }
        #expect(expected != nil)
        #expect(texts.contains { $0 == expected })
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

    private static func codexStore(
        rows: [CodexAccountUsageSnapshot],
        hidePersonalInfo: Bool = false,
        onReconciliationLoad: (@Sendable () -> Void)? = nil) -> (UsageStore, SettingsStore)
    {
        let settings = testSettingsStore(suiteName: "AccountRecommendationTests-codex")
        settings.hidePersonalInfo = hidePersonalInfo
        if let onReconciliationLoad {
            settings._test_codexAccountSnapshotLoader = { activeSource in
                onReconciliationLoad()
                return CodexAccountReconciliationSnapshot(
                    storedAccounts: [],
                    activeStoredAccount: nil,
                    liveSystemAccount: nil,
                    matchingStoredAccountForLiveSystemAccount: nil,
                    activeSource: activeSource,
                    hasUnreadableAddedAccountStore: false)
            }
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.codexAccountSnapshots = rows
        return (store, settings)
    }

    private static func codexContext(
        store: UsageStore,
        settings: SettingsStore,
        rows: [CodexAccountUsageSnapshot]) -> ProviderMenuUsageContext
    {
        ProviderMenuUsageContext(
            provider: .codex,
            store: store,
            settings: settings,
            metadata: ProviderDescriptorRegistry.descriptor(for: .codex).metadata,
            snapshot: rows.first?.snapshot)
    }

    /// Mirrors what the menu does with a provider's candidates, driving the real Codex hook so the
    /// projection it hands over is the thing under test. `onReconciliationLoad` fires if that hook
    /// asks the settings store to reconcile accounts, which menu rendering must never do.
    private static func codexRecommendation(
        rows: [CodexAccountUsageSnapshot],
        hidePersonalInfo: Bool = false,
        onReconciliationLoad: (@Sendable () -> Void)? = nil) -> String?
    {
        let (store, settings) = self.codexStore(
            rows: rows,
            hidePersonalInfo: hidePersonalInfo,
            onReconciliationLoad: onReconciliationLoad)
        let accounts = CodexProviderImplementation().rankableAccounts(
            context: self.codexContext(store: store, settings: settings, rows: rows))
        return AccountRecommendation.line(for: accounts, hidePersonalInfo: hidePersonalInfo, now: self.now)
    }
}

/// Minimal call counter for the `@Sendable` reconciliation-loader seam.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}
