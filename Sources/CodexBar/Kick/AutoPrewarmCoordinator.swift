import CodexBarCore
import Foundation

/// Starts a dormant Claude account's 5-hour clock while the account being worked in fills up, so
/// the switch the user is about to make lands on a window that is already running.
///
/// ### What it can reach
///
/// Only Claude **token accounts** — the ones whose OAuth token the user pasted into CodexBar
/// themselves. That is not a shortcut, it is the whole of what is addressable: `claude-swap`
/// accounts keep their credentials inside the `cswap` subprocess and hand CodexBar percentages
/// only, and the ambient Claude Code login is by definition the one already active. Reaching a
/// dormant claude-swap account would mean either becoming a second credential vault or switching
/// the machine's live Claude login in the background, both of which
/// `docs/claude-multi-account-and-status-items.md` rules out. So an account CodexBar cannot send a
/// message on is simply never a candidate, and a user with no OAuth token accounts sees this
/// feature do nothing at all.
///
/// It also needs per-account numbers to decide with, and those only exist when upstream fetches
/// every token account rather than just the selected one — `UsageStore.shouldFetchAllTokenAccounts`
/// requires the stacked multi-account layout and more than one account. Below that bar
/// `accountSnapshots` holds at most the selected account, no account is ever both active and
/// distinct from a candidate, and the decision correctly declines to act.
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
        let now = Date()
        // Provider-specific by design: only Claude has a 5-hour window that begins with a request
        // and an addressable per-account credential. Codex starts its window by running a CLI in
        // one account's $CODEX_HOME, which cannot target an account that is not active — so there
        // is nothing here to generalise across providers.
        let accounts = self.usageStore?.accountSnapshots[UsageProvider.claude.instanceID] ?? []
        self.recordSamples(accounts, now: now)

        guard let candidate = AutoPrewarmDecision.candidate(
            isEnabled: self.store.isPrewarmEnabled,
            accounts: self.prewarmAccounts(accounts),
            lastPrewarmOfAnyAccountAt: self.store.lastPrewarmOfAnyAccountAt(),
            now: now),
            let entry = accounts.first(where: { Self.key(for: $0.account) == candidate.key })
        else { return }

        // Recorded before the message is sent, so a crash mid-send costs a missed prewarm rather
        // than a second message on an account the user is not even looking at.
        self.store.recordPrewarm(at: now, for: candidate.key)
        self.logger.info("prewarming a dormant Claude account")

        Task { @MainActor in
            guard let usageStore = self.usageStore else { return }
            guard let outcome = await KickCoordinator.shared
                .kickClaudeTokenAccount(entry.account, store: usageStore)
            else { return }
            self.report(outcome, label: entry.account.displayName, settings: usageStore.settings)
        }
    }

    private func recordSamples(_ accounts: [TokenAccountUsageSnapshot], now: Date) {
        let horizon = now.addingTimeInterval(-2 * AutoPrewarmDecision.activityWindow)
        var live: [String: [PrewarmSample]] = [:]

        for entry in accounts {
            let key = Self.key(for: entry.account)
            var series = (self.samples[key] ?? []).filter { $0.at >= horizon }
            if let snapshot = entry.snapshot {
                let lanes = Self.lanes(in: snapshot)
                // A refresh that produced no readable lane is not an observation of zero usage, and
                // recording it as one would read as a fall and then as a rise on the next tick.
                if !lanes.isEmpty {
                    series.append(PrewarmSample(at: now, percentByLane: lanes))
                }
            }
            live[key] = series
        }

        // Accounts the user removed drop out entirely rather than keeping a series nothing will
        // ever compare against.
        self.samples = live
    }

    private func prewarmAccounts(_ accounts: [TokenAccountUsageSnapshot]) -> [PrewarmAccount] {
        accounts.compactMap { entry in
            // A failed refresh leaves the last known numbers in place, and those must not be read
            // as a live report — the same hazard `AccountRanking` guards against for re-auth.
            guard entry.error == nil, let snapshot = entry.snapshot else { return nil }
            let key = Self.key(for: entry.account)
            return PrewarmAccount(
                key: key,
                windows: snapshot.rankableWindows,
                sessionWindow: Self.sessionWindow(in: snapshot),
                samples: self.samples[key] ?? [],
                lastPrewarmedAt: self.store.lastPrewarmedAt(for: key))
        }
    }

    /// The 5-hour lane, or `nil` when the provider reported none.
    ///
    /// A synthetic placeholder is Claude's stand-in for a null `five_hour`, i.e. an account with no
    /// session lane at all. It must not arrive at the decision as a real window with no reset
    /// instant, or every never-used account would look permanently ready to prewarm.
    private static func sessionWindow(in snapshot: UsageSnapshot) -> RateWindow? {
        guard let primary = snapshot.primary, !primary.isSyntheticPlaceholder else { return nil }
        return primary
    }

    /// Used-percent per quota lane, keyed so the same lane lines up between two refreshes.
    ///
    /// The positional lanes are keyed by position and named ones by their own id, which is what
    /// makes a model-scoped quota comparable to itself rather than to whatever sorted next to it.
    private static func lanes(in snapshot: UsageSnapshot) -> [String: Double] {
        var lanes: [String: Double] = [:]
        func add(_ name: String, _ window: RateWindow?) {
            guard let window, !window.isSyntheticPlaceholder, window.usedPercent.isFinite else { return }
            lanes[name] = window.usedPercent
        }
        add("primary", snapshot.primary)
        add("secondary", snapshot.secondary)
        add("tertiary", snapshot.tertiary)
        for named in snapshot.extraRateWindows ?? [] where named.usageKnown {
            add("named:\(named.id)", named.window)
        }
        return lanes
    }

    /// The account's own stable id, which is persisted with the token account and survives
    /// relabelling. Never the label or an email: this key is written to local defaults.
    private static func key(for account: ProviderTokenAccount) -> String {
        "claude-token|\(account.id.uuidString)"
    }

    /// Every outcome is said out loud, as with a manual kick. This one spends quota on an account
    /// the user is not looking at, so silence is even less acceptable here than there.
    private func report(_ outcome: KickOutcome, label: String, settings: SettingsStore) {
        let safeLabel = PersonalInfoRedactor.redactEmails(in: label, isEnabled: settings.hidePersonalInfo)
            ?? label
        let body = switch outcome {
        case .started:
            String(format: L("prewarm_started_format"), safeLabel)
        case .alreadyRunning:
            L("A session window was already running, so nothing was sent.")
        case .noCredentials:
            L("Could not start a session window: sign in to this account again.")
        case let .unsupported(reason):
            reason
        case let .failed(message):
            message
        }

        // Provider-specific by design: the notification names the provider whose account was
        // touched, and this coordinator only ever touches Claude.
        let title = ProviderDescriptorRegistry.descriptor(for: .claude).metadata.displayName
        AppNotifications.shared.post(
            idPrefix: "prewarm-claude",
            title: title,
            body: body,
            soundEnabled: false)
    }
}
