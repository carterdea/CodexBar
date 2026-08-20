import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// About one thing: a refresh that failed must not look like an observation.
///
/// `UsageStore` deliberately keeps the previous numbers when a Codex account fails for a reason
/// that says nothing about the account, so the menu does not blank out every time the network
/// drops. That is right for the menu and wrong for the prewarm, which reads a *change between two
/// observations* and would otherwise date an old percentage to right now.
@MainActor
struct AutoPrewarmTargetTests {
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeStore(suiteName: String) -> UsageStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
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

    private func codexAccount() -> CodexVisibleAccount {
        let storedAccountID = UUID()
        return CodexVisibleAccount(
            id: "spare@example.com",
            email: "spare@example.com",
            storedAccountID: storedAccountID,
            selectionSource: .managedAccount(id: storedAccountID),
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
    }

    private func codexTargets(error: String?) -> [PrewarmTarget] {
        let store = self.makeStore(suiteName: "AutoPrewarmTargetTests-\(error == nil ? "ok" : "failed")")
        store.codexAccountSnapshots = [
            CodexAccountUsageSnapshot(
                account: self.codexAccount(),
                snapshot: self.snapshot(percent: 40),
                error: error,
                sourceLabel: nil),
        ]
        let coordinator = AutoPrewarmCoordinator(
            store: AutoKickStore(defaults: UserDefaults(suiteName: "AutoPrewarmTargetTests-kick")!))
        return coordinator.targets(for: .codex, usageStore: store)
    }

    /// The shape `UsageStore.shouldPreserveCodexAccountSnapshotOnFailure` produces: an error *and*
    /// the last good numbers on the same row.
    @Test
    func `a codex refresh that failed carries no numbers, even when it kept the last known ones`() {
        let targets = self.codexTargets(error: "The Internet connection appears to be offline.")
        #expect(targets.count == 1)
        #expect(targets.first?.snapshot == nil)
    }

    @Test
    func `a codex refresh that succeeded carries its numbers`() {
        #expect(self.codexTargets(error: nil).first?.snapshot != nil)
    }

    @Test
    func `an error discards the snapshot on the row it arrived with`() {
        #expect(PrewarmTarget.liveSnapshot(self.snapshot(percent: 40), error: "offline") == nil)
        #expect(PrewarmTarget.liveSnapshot(self.snapshot(percent: 40), error: nil) != nil)
        #expect(PrewarmTarget.liveSnapshot(nil, error: nil) == nil)
    }
}
