import CodexBarCore
import Foundation

/// Starts a dormant account's 5-hour clock while the account being worked in fills up, so the
/// switch the user is about to make lands on a window that is already running.
///
/// ### What it can reach
///
/// Claude **token accounts** holding an OAuth token the user pasted in, and **managed Codex
/// accounts**, which are logins CodexBar keeps in a `CODEX_HOME` of its own. Both are accounts the
/// app can address on purpose rather than by whatever is signed in at the moment.
///
/// Everything else is out of reach by construction, not by omission. The same Claude token slot
/// also stores web cookies and admin API keys, and neither can send an inference request.
/// `claude-swap` accounts keep their credentials inside the `cswap` subprocess and hand CodexBar
/// percentages only. The ambient Claude Code login and the ambient `~/.codex` login are not
/// accounts so much as whichever login is signed in there, so a kick aimed at either lands wherever
/// that happens to point. Reaching further would mean becoming a second credential vault or
/// switching the machine's live login in the background, both of which
/// `docs/claude-multi-account-and-status-items.md` rules out.
///
/// It also needs per-account numbers to decide with, and those exist only when the app fetches
/// every account rather than just the selected one — `UsageStore.shouldFetchAllTokenAccounts` and
/// `shouldFetchAllCodexVisibleAccounts` both want the stacked multi-account layout and more than
/// one account. Below that bar no account is ever both active and distinct from a candidate, and
/// the decision correctly declines to act.
///
/// ### Why samples are held here and not read back from history
///
/// The trigger needs a rise between two observations no more than 30 minutes apart.
/// `PlanUtilizationHistoryStore` keeps two years of samples but canonicalises them into hourly
/// buckets — `UsageStore+PlanUtilization.swift` keeps one peak entry per hour per reset segment —
/// so consecutive stored entries are an hour or more apart and can never satisfy that gap. The
/// live refresh stream is the only source with the right cadence, so the ring is built from it.
///
/// It is deliberately **not** persisted. A rise means "someone is typing into this account right
/// now", and a rise recovered from before a relaunch does not. The one thing that must survive a
/// crash — the cooldown — is in ``AutoKickStore``.
@MainActor
final class AutoPrewarmCoordinator {
    static let shared = AutoPrewarmCoordinator()

    /// The providers a prewarm can act on.
    static var providers: [UsageProvider] {
        // Provider-specific by design: a prewarm needs a session window that begins with a request
        // and an account CodexBar can address without switching the machine's live login. Only
        // these two have both, and no provider metadata records either property, so the list is
        // the feature rather than an unfactored special case.
        [.claude, .codex]
    }

    private let store: AutoKickStore
    private let logger = CodexBarLog.logger(LogCategories.notifications)
    private var observers: [NSObjectProtocol] = []
    private weak var usageStore: UsageStore?

    /// Recent observations per account, oldest first. Pruned on every tick to the oldest sample
    /// that could still take part in a comparison.
    private var samples: [String: [PrewarmSample]] = [:]

    init(store: AutoKickStore = .shared) {
        self.store = store
    }

    /// Begins observing. Safe to call once at launch; calling again replaces the observers.
    func start(usageStore: UsageStore) {
        self.stop()
        self.usageStore = usageStore
        self.observers = [
            NotificationCenter.default.addObserver(
                forName: .codexbarUsageSnapshotsDidChange,
                object: nil,
                queue: .main)
            { _ in MainActor.assumeIsolated { self.handleSnapshotsChanged() } },
        ]
    }

    func stop() {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.observers = []
        self.samples = [:]
    }

    // MARK: - Internals

    /// Sampling runs whether or not the feature is enabled, for the same reason as auto-kick's:
    /// otherwise the first half hour after switching it on can decide nothing, and a silent wait is
    /// indistinguishable from the feature being broken. Only the *decision* reads the setting.
    private func handleSnapshotsChanged() {
        guard let usageStore = self.usageStore else { return }
        let now = Date()
        let targets = Self.providers.flatMap { self.targets(for: $0, usageStore: usageStore) }
        self.recordSamples(targets, now: now)

        // Each provider decides on its own accounts. A Codex account filling up says nothing about
        // how much Claude capacity is left, so one merged ranking would let either provider's
        // activity spend the other's quota.
        for provider in Self.providers {
            self.prewarmIfNeeded(provider: provider, targets: targets, usageStore: usageStore, now: now)
        }
    }

    private func prewarmIfNeeded(
        provider: UsageProvider,
        targets: [PrewarmTarget],
        usageStore: UsageStore,
        now: Date)
    {
        let owned = targets.filter { $0.provider == provider }
        guard let candidate = AutoPrewarmDecision.candidate(
            isEnabled: self.store.isPrewarmEnabled(for: provider),
            accounts: owned.compactMap { self.prewarmAccount(for: $0) },
            lastPrewarmOfAnyAccountAt: self.store.lastPrewarmOfAnyAccountAt(
                keyPrefix: Self.keyPrefix(for: provider)),
            now: now),
            let target = owned.first(where: { $0.key == candidate.key })
        else { return }

        // Recorded before the message is sent, so a crash mid-send costs a missed prewarm rather
        // than a second message on an account the user is not even looking at.
        self.store.recordPrewarm(at: now, for: candidate.key)
        self.logger.info("prewarming a dormant account", metadata: ["provider": provider.rawValue])

        Task { @MainActor in
            guard let outcome = await target.reach.kick(store: usageStore) else { return }
            self.report(outcome, target: target, settings: usageStore.settings)
        }
    }

    private func recordSamples(_ targets: [PrewarmTarget], now: Date) {
        var live: [String: [PrewarmSample]] = [:]
        for target in targets {
            let sample = target.snapshot.map { PrewarmSample(at: now, percentByLane: $0.prewarmLanes) }
            live[target.key] = PrewarmSampleRing.appending(sample, to: self.samples[target.key] ?? [], now: now)
        }

        // Accounts the user removed drop out entirely rather than keeping a series nothing will
        // ever compare against.
        self.samples = live
    }

    private func prewarmAccount(for target: PrewarmTarget) -> PrewarmAccount? {
        guard let snapshot = target.snapshot else { return nil }
        return PrewarmAccount(
            key: target.key,
            windows: snapshot.rankableWindows,
            sessionWindow: snapshot.prewarmSessionWindow,
            samples: self.samples[target.key] ?? [],
            lastPrewarmedAt: self.store.lastPrewarmedAt(for: target.key),
            canStartSessionWindow: target.reach.canStartSessionWindow)
    }

    func targets(for provider: UsageProvider, usageStore: UsageStore) -> [PrewarmTarget] {
        // Provider-specific by design: the two providers publish per-account usage in different
        // collections, and reach their accounts by different means — a pasted Claude token versus a
        // Codex login in a home directory of its own. Neither is derivable from provider metadata.
        switch provider {
        case .claude:
            (usageStore.accountSnapshots[provider.instanceID] ?? []).map { entry in
                PrewarmTarget(
                    provider: provider,
                    key: Self.key(provider: provider, id: entry.account.id.uuidString),
                    label: entry.account.displayName,
                    snapshot: PrewarmTarget.liveSnapshot(entry.snapshot, error: entry.error),
                    reach: .claudeToken(entry.account))
            }
        case .codex:
            usageStore.codexAccountSnapshots.map { entry in
                PrewarmTarget(
                    provider: provider,
                    key: Self.key(provider: provider, id: Self.codexAccountID(entry.account)),
                    label: entry.account.displayName,
                    snapshot: PrewarmTarget.liveSnapshot(entry.snapshot, error: entry.error),
                    reach: Self.codexReach(entry.account, settings: usageStore.settings))
            }
        default:
            []
        }
    }

    /// A managed account's own home, or ``PrewarmReach/unreachable``.
    ///
    /// Two accounts are deliberately left unreachable. One with no stored account is the ambient
    /// `~/.codex` login or a profile home CodexBar only reads, neither of which it owns. One that
    /// is currently *live* has been swapped into `~/.codex` by `ManagedCodexAccountService`, so its
    /// managed home is not where its credentials are right now — kicking it there would run against
    /// whatever that directory still holds.
    private static func codexReach(_ account: CodexVisibleAccount, settings: SettingsStore) -> PrewarmReach {
        guard let storedAccountID = account.storedAccountID, !account.isLive else { return .unreachable }
        guard let home = settings.codexAccountReconciliationSnapshot.storedAccounts
            .first(where: { $0.id == storedAccountID })?
            .managedHomePath
        else { return .unreachable }
        return .codexManagedHome(home)
    }

    /// The account's own persisted id where it has one, so the key survives relabelling. An account
    /// without one can still be recognised as the account in use, which is all the sample ring
    /// needs; it can never be a candidate, so a key that shifts costs nothing but its own history.
    private static func codexAccountID(_ account: CodexVisibleAccount) -> String {
        account.storedAccountID?.uuidString ?? "visible:\(account.id)"
    }

    /// Never a label or an email: these keys are written to local defaults.
    private static func key(provider: UsageProvider, id: String) -> String {
        "\(self.keyPrefix(for: provider))\(id)"
    }

    /// What scopes the one-at-a-time cooldown to a single provider.
    private static func keyPrefix(for provider: UsageProvider) -> String {
        "\(provider.rawValue)|"
    }

    /// Every outcome is said out loud, as with a manual kick. This one spends quota on an account
    /// the user is not looking at, so silence is even less acceptable here than there.
    private func report(_ outcome: KickOutcome, target: PrewarmTarget, settings: SettingsStore) {
        let safeLabel = PersonalInfoRedactor.redactEmails(in: target.label, isEnabled: settings.hidePersonalInfo)
            ?? target.label
        let body = outcome.notificationBody(started: String(format: L("prewarm_started_format"), safeLabel))

        let title = ProviderDescriptorRegistry.descriptor(for: target.provider).metadata.displayName
        AppNotifications.shared.post(
            idPrefix: "prewarm-\(target.provider.rawValue)",
            title: title,
            body: body,
            soundEnabled: false)
    }
}

/// How a prewarm reaches one account, or that it cannot.
///
/// An enum rather than a flag plus a payload so "unreachable" and "here is where to send" cannot
/// disagree. Ranking an account nothing can be sent on is not a wasted cycle but a permanent stall:
/// it wins on headroom, takes the shared cooldown with it, and nothing about it changes before the
/// next cycle, so it wins again and the account that *can* be reached is never prewarmed at all.
enum PrewarmReach {
    case claudeToken(ProviderTokenAccount)
    case codexManagedHome(String)
    case unreachable

    /// Read only when choosing a candidate, never when identifying the account in use. Whether a
    /// credential can send a message says nothing about whether someone is typing into it, and the
    /// spare belonging to an unreachable account is exactly the one worth starting.
    var canStartSessionWindow: Bool {
        switch self {
        case let .claudeToken(account):
            // Web cookies and admin API keys are stored in the same slot and cannot send. Answered
            // here so an account `KickCoordinator` would refuse never reaches the ranking. Nothing
            // is read from the Keychain, Claude Code storage, or claude-swap to answer it.
            ClaudeCredentialRouting
                .resolve(tokenAccountToken: account.token, manualCookieHeader: nil)
                .oauthAccessToken != nil
        case .codexManagedHome:
            true
        case .unreachable:
            false
        }
    }

    @MainActor
    func kick(store: UsageStore) async -> KickOutcome? {
        switch self {
        case let .claudeToken(account):
            await KickCoordinator.shared.kickClaudeTokenAccount(account, store: store)
        case let .codexManagedHome(home):
            await KickCoordinator.shared.kickCodexManagedAccount(homePath: home, store: store)
        case .unreachable:
            nil
        }
    }
}

/// One account as this coordinator sees it, with the numbers to rank it and the means to reach it.
struct PrewarmTarget {
    let provider: UsageProvider
    let key: String
    let label: String
    /// Only ever a snapshot the last refresh actually produced. See ``liveSnapshot(_:error:)``.
    let snapshot: UsageSnapshot?
    let reach: PrewarmReach

    /// The snapshot a refresh produced, or `nil` when that refresh failed.
    ///
    /// A failed refresh does not always arrive empty. `UsageStore` keeps the previous numbers when
    /// a Codex account fails for a reason that says nothing about the account — no network, DNS, a
    /// timeout — so the menu shows the last known figures instead of blanking out.
    ///
    /// Sampled, that value is a lie about *when*. Every failed refresh re-stamps the same old
    /// percentage with the current time, so when the network comes back and a higher number
    /// arrives, a climb that happened across the whole outage reads as one that happened in the
    /// last few minutes. That is precisely the signal this feature treats as someone typing into
    /// the account right now, and acting on it spends a message and a five-hour cooldown on an
    /// account nobody is using.
    ///
    /// Applied once, here, rather than at each place that reads a snapshot: ranking a stale number
    /// is the same hazard `AccountRanking` guards against for re-auth, and two guards for one rule
    /// is one guard someone can forget to add.
    static func liveSnapshot(_ snapshot: UsageSnapshot?, error: String?) -> UsageSnapshot? {
        error == nil ? snapshot : nil
    }
}
