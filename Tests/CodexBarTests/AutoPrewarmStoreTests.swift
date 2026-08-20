import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// The prewarm cooldown is the only part of this feature that must survive a crash: it is what
/// stops a relaunch from sending a second message on an account nobody is watching.
@Suite(.serialized)
@MainActor
struct AutoPrewarmStoreTests {
    private func makeStore(suite: String) throws -> AutoKickStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AutoKickStore(defaults: defaults)
    }

    private static let key = "claude|11111111-2222-3333-4444-555555555555"
    private static let otherKey = "claude|99999999-8888-7777-6666-555555555555"
    private static let codexKey = "codex|44444444-3333-2222-1111-000000000000"

    @Test
    func `prewarm is off until it is turned on`() throws {
        let store = try self.makeStore(suite: "AutoPrewarmStoreTests-default-off")
        #expect(!store.isPrewarmEnabled(for: .claude))
    }

    @Test
    func `a recorded prewarm survives a new store over the same defaults`() throws {
        let suite = "AutoPrewarmStoreTests-persist"
        let store = try self.makeStore(suite: suite)
        let at = Date(timeIntervalSince1970: 1_760_000_000)
        store.recordPrewarm(at: at, for: Self.key)

        let defaults = try #require(UserDefaults(suiteName: suite))
        let reloaded = AutoKickStore(defaults: defaults)
        #expect(reloaded.lastPrewarmedAt(for: Self.key) == at)
    }

    @Test
    func `an account that was never prewarmed has no timestamp`() throws {
        let store = try self.makeStore(suite: "AutoPrewarmStoreTests-absent")
        store.recordPrewarm(at: Date(), for: Self.key)
        #expect(store.lastPrewarmedAt(for: Self.otherKey) == nil)
    }

    @Test
    func `the most recent prewarm across accounts is the latest one recorded`() throws {
        let store = try self.makeStore(suite: "AutoPrewarmStoreTests-any")
        let older = Date(timeIntervalSince1970: 1_760_000_000)
        store.recordPrewarm(at: older, for: Self.key)
        store.recordPrewarm(at: older.addingTimeInterval(600), for: Self.otherKey)

        #expect(store.lastPrewarmOfAnyAccountAt(keyPrefix: "claude|") == older.addingTimeInterval(600))
    }

    @Test
    func `no prewarm at all reports no most-recent time`() throws {
        let store = try self.makeStore(suite: "AutoPrewarmStoreTests-any-empty")
        #expect(store.lastPrewarmOfAnyAccountAt(keyPrefix: "claude|") == nil)
    }

    /// A Claude session window and a Codex one are separate quotas that run at the same time, so
    /// one shared timestamp would let whichever provider warmed first block the other for five
    /// hours — the opposite of what the one-at-a-time rule is for.
    @Test
    func `the one-at-a-time cooldown is scoped to one provider`() throws {
        let store = try self.makeStore(suite: "AutoPrewarmStoreTests-per-provider")
        let at = Date(timeIntervalSince1970: 1_760_000_000)
        store.recordPrewarm(at: at, for: Self.key)

        #expect(store.lastPrewarmOfAnyAccountAt(keyPrefix: "claude|") == at)
        #expect(store.lastPrewarmOfAnyAccountAt(keyPrefix: "codex|") == nil)

        store.recordPrewarm(at: at.addingTimeInterval(60), for: Self.codexKey)
        #expect(store.lastPrewarmOfAnyAccountAt(keyPrefix: "claude|") == at)
        #expect(store.lastPrewarmOfAnyAccountAt(keyPrefix: "codex|") == at.addingTimeInterval(60))
    }

    /// The two features have different intervals — twelve hours for a weekly turnover, five for a
    /// session window — so sharing one timestamp would let either silence the other.
    @Test
    func `prewarm and auto-kick keep separate histories`() throws {
        let store = try self.makeStore(suite: "AutoPrewarmStoreTests-separate")
        let at = Date(timeIntervalSince1970: 1_760_000_000)
        store.recordPrewarm(at: at, for: Self.key)

        #expect(store.lastAutoKickedAt(for: Self.key) == nil)

        store.recordAutoKick(at: at.addingTimeInterval(3600), for: Self.key)
        #expect(store.lastPrewarmedAt(for: Self.key) == at)
    }

    /// The enabled flags are separate too: turning on the weekly kick must not silently enable a
    /// feature that messages an account the user is not even looking at.
    @Test
    func `the two switches are independent`() throws {
        let store = try self.makeStore(suite: "AutoPrewarmStoreTests-switches")
        store.isEnabled = true
        #expect(!store.isPrewarmEnabled(for: .claude))

        store.setPrewarmEnabled(true, for: .claude)
        store.isEnabled = false
        #expect(store.isPrewarmEnabled(for: .claude))
    }

    /// Each provider's pane shows its own switch. Sharing one flag would mean arming Claude's
    /// prewarm also armed Codex's, which nobody asked for and which sends real messages.
    @Test
    func `each provider has its own prewarm switch`() throws {
        let store = try self.makeStore(suite: "AutoPrewarmStoreTests-per-provider-switch")
        store.setPrewarmEnabled(true, for: .claude)

        #expect(store.isPrewarmEnabled(for: .claude))
        #expect(!store.isPrewarmEnabled(for: .codex))
    }
}
