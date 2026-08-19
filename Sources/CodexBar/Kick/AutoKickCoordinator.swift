import CodexBarCore
import Foundation

/// Starts a new weekly window automatically when a heavily used one turns over.
///
/// Detection is entirely upstream's: `UsageStore+LimitResetCelebration` already recognises a weekly
/// reset — it is what fires the confetti — and already demands two confirming observations for
/// Claude before believing one. This only adds the question upstream has no reason to ask: *was
/// that window worth replacing early*.
///
/// It has to ask, because the reset event reports the percentage *after* the reset, which is near
/// zero for every account whether or not anyone was using it. So the weekly figure is sampled as it
/// goes and the high-water mark is what the decision reads.
@MainActor
final class AutoKickCoordinator {
    static let shared = AutoKickCoordinator()

    private let store: AutoKickStore
    private let logger = CodexBarLog.logger(LogCategories.notifications)
    private var observers: [NSObjectProtocol] = []
    private weak var usageStore: UsageStore?

    init(store: AutoKickStore = .shared) {
        self.store = store
    }

    /// Begins observing. Safe to call once at launch; calling again replaces the observers.
    func start(usageStore: UsageStore) {
        self.stop()
        self.usageStore = usageStore

        let center = NotificationCenter.default
        self.observers = [
            center.addObserver(
                forName: .codexbarUsageSnapshotsDidChange,
                object: nil,
                queue: .main)
            { _ in MainActor.assumeIsolated { self.recordWeeklyUsage() } },
            center.addObserver(
                forName: .codexbarWeeklyLimitReset,
                object: nil,
                queue: .main)
            { note in
                // Pull the provider out before crossing isolation: it is Sendable, the
                // notification is not.
                guard let provider = (note.object as? WeeklyLimitResetEvent)?.provider else { return }
                MainActor.assumeIsolated { self.handleWeeklyReset(provider: provider) }
            },
        ]
    }

    func stop() {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.observers = []
    }

    // MARK: - Internals

    /// Keyed on the account's own identity, not just the provider, so a peak cannot be carried
    /// across a switch to a different login. Both the sample and the decision read this from the
    /// same place, so they cannot disagree about which account they mean.
    ///
    /// An account with no identity yet gets `nil` rather than a shared placeholder. A placeholder
    /// would be one bucket that every unidentified login of that provider reads and writes, so
    /// signing out of a heavy account and into a fresh one would hand the new one the old one's
    /// peak — and auto-kick would send a message on it for a week it never had. Skipping means
    /// nothing is sampled until identity is known, which costs at most one window.
    private func peakKey(for provider: UsageProvider) -> String? {
        guard let snapshot = self.usageStore?.snapshot(for: provider.instanceID) else { return nil }
        guard let identity = snapshot.identity?.accountEmail ?? snapshot.identity?.accountOrganization,
              !identity.isEmpty
        else { return nil }
        return "\(provider.rawValue)|\(identity)"
    }

    /// Identifies the weekly window a sample belongs to, so a peak cannot outlive its window.
    ///
    /// The reset instant is the only thing that distinguishes one weekly window from the next, and
    /// it is already on the snapshot. Without it a peak is just a number: if the app is closed
    /// across a turnover, no reset event fires, `clearWeeklyPeak` never runs, and the old peak
    /// survives into a window it did not measure — where `recordWeeklyUsage` keeps the maximum and
    /// so can never lower it. The next turnover then reads a busy week that never happened.
    private func windowID(for provider: UsageProvider) -> String? {
        guard let resetsAt = self.usageStore?.snapshot(for: provider.instanceID)?.secondary?.resetsAt
        else { return nil }
        return String(Int(resetsAt.timeIntervalSince1970))
    }

    /// The weekly lane is `secondary`. A synthetic placeholder stands in for a lane the provider
    /// never reported, so recording it would invent a 0% observation for a window nobody saw.
    private func weeklyPercent(for provider: UsageProvider) -> Double? {
        guard let window = self.usageStore?.snapshot(for: provider.instanceID)?.secondary else { return nil }
        guard !window.isSyntheticPlaceholder, window.usedPercent.isFinite else { return nil }
        return window.usedPercent
    }

    /// Sampling runs whether or not auto-kick is enabled; only the *decision* consults the setting.
    ///
    /// Otherwise the first turnover after switching it on is always skipped, because the window
    /// that just ended was never measured — and a silent skip is indistinguishable from the
    /// feature being broken. The cost is one number per account in local defaults, which never
    /// leaves the machine.
    private func recordWeeklyUsage() {
        // Provider-specific by design: Claude and Codex are the only providers with a kickable session
        // window, so they are the only ones whose weekly peak is worth sampling.
        for provider in [UsageProvider.claude, .codex] {
            guard let key = self.peakKey(for: provider),
                  let percent = self.weeklyPercent(for: provider),
                  let windowID = self.windowID(for: provider)
            else { continue }
            self.store.recordWeeklyUsage(percent, for: key, windowID: windowID)
        }
    }

    private func handleWeeklyReset(provider: UsageProvider) {
        guard let usageStore, let key = self.peakKey(for: provider) else { return }

        let now = Date()
        // Read against the window that just ended. The snapshot at reset time may already carry
        // the *next* window's reset instant, in which case the stored peak belongs to neither and
        // is not evidence about the window being decided.
        let peak = self.store.peakForEndedWindow(key: key)
        let shouldKick = AutoKickDecision.shouldKick(
            isEnabled: self.store.isEnabled,
            peakPercent: peak,
            lastAutoKickedAt: self.store.lastAutoKickedAt(for: key),
            now: now)

        // The window is over either way, so the next one starts measuring from scratch.
        self.store.clearWeeklyPeak(for: key)

        guard shouldKick else {
            self.logger.debug(
                "auto-kick skipped",
                metadata: ["provider": provider.rawValue, "peak": peak.map { String(format: "%.0f", $0) } ?? "none"])
            return
        }

        // Recorded before the attempt: a crash mid-kick then costs a missed window rather than a
        // second message on the user's account.
        self.store.recordAutoKick(at: now, for: key)
        self.logger.info("auto-kick starting a new weekly window", metadata: ["provider": provider.rawValue])
        KickCoordinator.shared.kick(provider: provider, store: usageStore, trigger: .automatic)
    }
}
