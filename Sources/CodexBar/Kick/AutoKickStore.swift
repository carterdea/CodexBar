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

    /// A peak, and the weekly window it was measured in.
    ///
    /// The window identity is what stops a peak outliving its window. Nothing guarantees the app
    /// is running when a weekly window turns over, and a peak with no window attached is just a
    /// number: a 90% mark from a week the app then slept through would survive into the next
    /// window, where keeping the maximum means no later sample could ever bring it down. The next
    /// turnover would then read a busy week that never happened, and send a message for it.
    private struct WeeklyPeak {
        var peak: Double
        var windowID: String?

        var asDictionary: [String: Any] {
            var raw: [String: Any] = ["peak": NSNumber(value: self.peak)]
            if let windowID = self.windowID { raw["window"] = windowID }
            return raw
        }

        init(peak: Double, windowID: String?) {
            self.peak = peak
            self.windowID = windowID
        }

        /// A bare number is the shape written before windows were tracked. It reads as a peak
        /// whose window is unknown, which the first identified sample then rolls over.
        init?(raw: Any?) {
            if let number = raw as? NSNumber {
                self.init(peak: number.doubleValue, windowID: nil)
                return
            }
            guard let raw = raw as? [String: Any], let peak = (raw["peak"] as? NSNumber)?.doubleValue
            else { return nil }
            self.init(peak: peak, windowID: raw["window"] as? String)
        }
    }

    private func storedPeak(for key: String) -> WeeklyPeak? {
        WeeklyPeak(raw: self.defaults.dictionary(forKey: self.peaksKey)?[key])
    }

    private func store(_ value: WeeklyPeak, for key: String) {
        var peaks = self.defaults.dictionary(forKey: self.peaksKey) ?? [:]
        peaks[key] = value.asDictionary
        self.defaults.set(peaks, forKey: self.peaksKey)
    }

    /// The high-water mark of the window that has just ended, or `nil` when none was measured.
    ///
    /// One deliberate limitation. A turnover is observed twice — by a usage sample carrying the new
    /// window's reset instant, and by the reset event — and their order is not guaranteed. If
    /// sampling gets there first it has already rolled the record over, so this returns the new
    /// window's opening percentage (near zero) instead of the old window's peak, and no kick is
    /// sent. That is the safe direction and it matches how the rest of this store is biased: a
    /// missed kick costs a later window, a spurious one sends a message on the user's account that
    /// they never asked for. The following week's turnover is unaffected.
    func peakForEndedWindow(key: String) -> Double? {
        self.storedPeak(for: key)?.peak
    }

    /// Records a sample, keeping the highest **within one window**.
    ///
    /// A sample from a window the record does not know replaces it rather than competing with it.
    /// That is what makes a turnover the app slept through self-correcting: the first sample
    /// afterwards carries a window identity the record has never seen, so it starts a fresh peak
    /// instead of being suppressed by a stale higher one.
    func recordWeeklyUsage(_ percent: Double, for key: String, windowID: String?) {
        guard percent.isFinite else { return }
        guard let stored = self.storedPeak(for: key) else {
            self.store(WeeklyPeak(peak: percent, windowID: windowID), for: key)
            return
        }
        guard stored.windowID == windowID else {
            self.store(WeeklyPeak(peak: percent, windowID: windowID), for: key)
            return
        }
        guard percent > stored.peak else { return }
        self.store(WeeklyPeak(peak: percent, windowID: windowID), for: key)
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
