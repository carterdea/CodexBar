import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// What one account looks like to the prewarm: the numbers it may be ranked on, and whether there
/// is anywhere to send a message.
///
/// Both answers are refusals more often than not, and each refusal exists because saying yes costs
/// a message and a five-hour cooldown on an account nobody is using.
@MainActor
struct AutoPrewarmTargetTests {
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Fixtures

    private func makeStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private func snapshot(percent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: percent,
                windowMinutes: 300,
                resetsAt: Self.now.addingTimeInterval(3600),
                resetDescription: nil,
                nextRegenPercent: nil,
                isSyntheticPlaceholder: false),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Self.now,
            identity: nil)
    }

    private func codexAccount(storedAccountID: UUID?, isLive: Bool = false) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: "spare@example.com",
            email: "spare@example.com",
            storedAccountID: storedAccountID,
            selectionSource: storedAccountID.map { .managedAccount(id: $0) } ?? .liveSystem,
            isActive: false,
            isLive: isLive,
            canReauthenticate: true,
            canRemove: true)
    }

    private func managedAccount(id: UUID, homePath: String) -> ManagedCodexAccount {
        ManagedCodexAccount(
            id: id,
            email: "spare@example.com",
            managedHomePath: homePath,
            createdAt: Self.now.timeIntervalSince1970,
            updatedAt: Self.now.timeIntervalSince1970,
            lastAuthenticatedAt: nil)
    }

    private func codexTarget(
        _ name: String,
        account: CodexVisibleAccount,
        stored: [ManagedCodexAccount] = [],
        error: String? = nil) -> PrewarmTarget?
    {
        let settings = testSettingsStore(suiteName: "AutoPrewarmTargetTests-\(name)")
        settings._test_codexAccountSnapshotLoader = { activeSource in
            CodexAccountReconciliationSnapshot(
                storedAccounts: stored,
                activeStoredAccount: nil,
                liveSystemAccount: nil,
                matchingStoredAccountForLiveSystemAccount: nil,
                activeSource: activeSource,
                hasUnreadableAddedAccountStore: false)
        }
        let store = self.makeStore(settings: settings)
        store.codexAccountSnapshots = [
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(percent: 40),
                error: error,
                sourceLabel: nil),
        ]
        return self.coordinator().targets(for: .codex, usageStore: store).first
    }

    private func claudeTarget(_ name: String, token: String) -> PrewarmTarget? {
        let settings = testSettingsStore(suiteName: "AutoPrewarmTargetTests-\(name)")
        let store = self.makeStore(settings: settings)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "spare",
            token: token,
            addedAt: Self.now.timeIntervalSince1970,
            lastUsed: nil)
        store.accountSnapshots[UsageProvider.claude.instanceID] = [
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(percent: 40),
                error: nil,
                sourceLabel: "oauth",
                cacheKey: "test"),
        ]
        return self.coordinator().targets(for: .claude, usageStore: store).first
    }

    private func coordinator() -> AutoPrewarmCoordinator {
        AutoPrewarmCoordinator(
            store: AutoKickStore(defaults: UserDefaults(suiteName: "AutoPrewarmTargetTests-\(UUID())")!))
    }

    private func managedHome(_ reach: PrewarmReach?) -> String? {
        guard case let .codexManagedHome(home) = reach else { return nil }
        return home
    }

    private func isUnreachable(_ reach: PrewarmReach?) -> Bool {
        guard case .unreachable = reach else { return false }
        return true
    }

    // MARK: - Numbers

    /// `UsageStore` keeps the last known numbers when a Codex account fails for a reason that says
    /// nothing about the account, so the menu does not blank out every time the network drops. That
    /// row carries an error *and* a snapshot, and sampling it dates an old percentage to right now.
    @Test
    func `a codex refresh that failed carries no numbers, even when it kept the last known ones`() {
        let target = self.codexTarget(
            "stale",
            account: self.codexAccount(storedAccountID: UUID()),
            error: "The Internet connection appears to be offline.")
        #expect(target != nil)
        #expect(target?.snapshot == nil)
    }

    @Test
    func `a codex refresh that succeeded carries its numbers`() {
        #expect(self.codexTarget("live", account: self.codexAccount(storedAccountID: UUID()))?.snapshot != nil)
    }

    @Test
    func `an error discards the snapshot on the row it arrived with`() {
        #expect(PrewarmTarget.liveSnapshot(self.snapshot(percent: 40), error: "offline") == nil)
        #expect(PrewarmTarget.liveSnapshot(self.snapshot(percent: 40), error: nil) != nil)
        #expect(PrewarmTarget.liveSnapshot(nil, error: nil) == nil)
    }

    // MARK: - Reach

    @Test
    func `a managed codex account is reached in its own home`() {
        let id = UUID()
        let target = self.codexTarget(
            "managed",
            account: self.codexAccount(storedAccountID: id),
            stored: [self.managedAccount(id: id, homePath: "/tmp/codex-spare")])
        #expect(self.managedHome(target?.reach) == "/tmp/codex-spare")
        #expect(target?.reach.canStartSessionWindow == true)
    }

    /// A live account has been swapped into `~/.codex`, so its managed home is not where its
    /// credentials are. Kicking it there would run against whatever that directory still holds.
    @Test
    func `the account swapped into the codex home is not reached at its managed home`() {
        let id = UUID()
        let target = self.codexTarget(
            "live-account",
            account: self.codexAccount(storedAccountID: id, isLive: true),
            stored: [self.managedAccount(id: id, homePath: "/tmp/codex-spare")])
        #expect(self.isUnreachable(target?.reach))
        #expect(target?.reach.canStartSessionWindow == false)
    }

    /// The ambient `~/.codex` login is whoever is signed in there rather than an account CodexBar
    /// owns, so there is nothing to address.
    @Test
    func `a codex account CodexBar did not add is out of reach`() {
        let target = self.codexTarget("ambient", account: self.codexAccount(storedAccountID: nil))
        #expect(self.isUnreachable(target?.reach))
    }

    /// A stored id with no managed home left behind it: the account is gone but its usage row has
    /// not caught up yet.
    @Test
    func `a codex account whose managed home is missing is out of reach`() {
        let target = self.codexTarget("orphan", account: self.codexAccount(storedAccountID: UUID()))
        #expect(self.isUnreachable(target?.reach))
    }

    /// Claude's token slot also holds web cookies and admin API keys. Neither can send an inference
    /// request, and an account that wins on headroom but cannot be sent to is a permanent stall: it
    /// takes the cooldown with it and nothing about it changes before the next cycle.
    @Test
    func `a claude account holding a web cookie cannot start a session window`() {
        let target = self.claudeTarget("cookie", token: "sessionKey=abc123")
        #expect(target?.reach.canStartSessionWindow == false)
    }

    @Test
    func `a claude account holding an admin api key cannot start a session window`() {
        let target = self.claudeTarget("admin", token: "sk-ant-admin01-abc123")
        #expect(target?.reach.canStartSessionWindow == false)
    }

    @Test
    func `a claude account holding an oauth token can start a session window`() {
        let target = self.claudeTarget("oauth", token: "sk-ant-oat01-abc123")
        #expect(target?.reach.canStartSessionWindow == true)
    }
}
