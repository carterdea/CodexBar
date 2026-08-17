import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Covers whether Claude's menu offers "Start session window", and in which state.
///
/// Tested through `MenuDescriptor` rather than a live `NSMenu` because the descriptor is the
/// stable seam — and because under Merge Icons the real menu only shows one provider's section at
/// a time, so a passing GUI check would depend on which tab happened to be selected.
@MainActor
struct MenuDescriptorClaudeKickTests {
    private func makeStore(suite: String) throws -> (UsageStore, SettingsStore) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        return (store, settings)
    }

    private func snapshot(session: RateWindow?) -> UsageSnapshot {
        UsageSnapshot(
            primary: session,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
    }

    private func entries(store: UsageStore, settings: SettingsStore) -> [MenuDescriptor.Entry] {
        MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false)
            .sections
            .flatMap(\.entries)
    }

    private func kickAction(in entries: [MenuDescriptor.Entry]) -> MenuDescriptor.MenuAction? {
        entries.compactMap { entry -> MenuDescriptor.MenuAction? in
            guard case let .action(_, action) = entry, case .kickSession = action else { return nil }
            return action
        }.first
    }

    private func kickUnavailableSubtitle(in entries: [MenuDescriptor.Entry]) -> String?? {
        entries.compactMap { entry -> String?? in
            guard case let .unavailable(label, subtitle) = entry, label == "Start session window" else {
                return nil
            }
            return subtitle
        }.first
    }

    @Test
    func `an idle claude account is offered a session window kick`() throws {
        let (store, settings) = try self.makeStore(suite: "MenuDescriptorClaudeKickTests-idle")
        store._setSnapshotForTesting(self.snapshot(session: nil), provider: .claude)

        let action = self.kickAction(in: self.entries(store: store, settings: settings))
        #expect(action == .kickSession(.claude))
    }

    @Test
    func `a running session window offers no kick`() throws {
        let (store, settings) = try self.makeStore(suite: "MenuDescriptorClaudeKickTests-running")
        let running = RateWindow(
            usedPercent: 12,
            windowMinutes: 300,
            resetsAt: Date().addingTimeInterval(3600),
            resetDescription: nil,
            nextRegenPercent: nil,
            isSyntheticPlaceholder: false)
        store._setSnapshotForTesting(self.snapshot(session: running), provider: .claude)

        let entries = self.entries(store: store, settings: settings)
        #expect(self.kickAction(in: entries) == nil)
        #expect(self.kickUnavailableSubtitle(in: entries) != nil)
    }

    /// Claude web reports a placeholder five-hour window when the account has no live session.
    /// Treating that as a running window would hide the kick exactly when it is most useful.
    @Test
    func `a placeholder window counts as no session and still offers the kick`() throws {
        let (store, settings) = try self.makeStore(suite: "MenuDescriptorClaudeKickTests-placeholder")
        let placeholder = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: Date().addingTimeInterval(3600),
            resetDescription: nil,
            nextRegenPercent: nil,
            isSyntheticPlaceholder: true)
        store._setSnapshotForTesting(self.snapshot(session: placeholder), provider: .claude)

        let action = self.kickAction(in: self.entries(store: store, settings: settings))
        #expect(action == .kickSession(.claude))
    }
}
