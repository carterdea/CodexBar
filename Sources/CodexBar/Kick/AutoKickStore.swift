import CodexBarCore
import Foundation

/// Persistent state for automatic kicks, kept in its own store rather than `SettingsStore`.
///
/// A fork-owned store means adding this feature does not edit three shared settings files, so
/// upstream merges stay cheap. It also keeps a switch that spends money out of the general
/// settings surface, where it would be easy to flip by accident.
@MainActor
@Observable
final class AutoKickStore {
    static let shared = AutoKickStore()

    private let defaults: UserDefaults
    private let enabledKey = "fork.autoKick.enabled"
    private let peaksKey = "fork.autoKick.weeklyPeaks"
    private let kickedKey = "fork.autoKick.lastKickedAt"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Off by default, and deliberately not synced: it sends messages on this machine's logins.
    var isEnabled: Bool {
        get { self.defaults.bool(forKey: self.enabledKey) }
        set { self.defaults.set(newValue, forKey: self.enabledKey) }
    }

    // MARK: - Weekly peaks

    /// The highest weekly usage seen for an account since its last reset.
    func weeklyPeak(for key: String) -> Double? {
        (self.defaults.dictionary(forKey: self.peaksKey)?[key] as? NSNumber)?.doubleValue
    }

    /// Records a sample, keeping the highest. Only the peak matters: the app samples on a refresh
    /// cadence, so it will usually miss the exact moment a window was fullest.
    func recordWeeklyUsage(_ percent: Double, for key: String) {
        guard percent.isFinite else { return }
        var peaks = self.defaults.dictionary(forKey: self.peaksKey) ?? [:]
        let existing = (peaks[key] as? NSNumber)?.doubleValue ?? -1
        guard percent > existing else { return }
        peaks[key] = NSNumber(value: percent)
        self.defaults.set(peaks, forKey: self.peaksKey)
    }

    /// Called once a turnover has been handled, so the next window starts measuring from scratch
    /// rather than inheriting the previous window's high-water mark forever.
    func clearWeeklyPeak(for key: String) {
        guard var peaks = self.defaults.dictionary(forKey: self.peaksKey) else { return }
        peaks.removeValue(forKey: key)
        self.defaults.set(peaks, forKey: self.peaksKey)
    }

    // MARK: - Kick history

    func lastAutoKickedAt(for key: String) -> Date? {
        guard let seconds = (self.defaults.dictionary(forKey: self.kickedKey)?[key] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Written *before* the kick is attempted, so a crash mid-kick cannot lead to a second one on
    /// the next launch. Over-recording costs a missed kick; under-recording costs a duplicate
    /// message on the user's account, which is the worse failure.
    func recordAutoKick(at date: Date, for key: String) {
        var kicked = self.defaults.dictionary(forKey: self.kickedKey) ?? [:]
        kicked[key] = NSNumber(value: date.timeIntervalSince1970)
        self.defaults.set(kicked, forKey: self.kickedKey)
    }
}
