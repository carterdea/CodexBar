import Foundation

/// Whether a weekly turnover should be answered with an automatic kick.
///
/// Pure and separate from the plumbing because this is the decision that spends the user's quota
/// without them asking. Every rule here exists to stop it firing when it should not.
public enum AutoKickDecision {
    /// How full a weekly window must have been before its turnover is worth kicking.
    ///
    /// A window with room left never stopped anyone, so starting its replacement early buys
    /// nothing and still sends a message on the user's account.
    public static let heavilyUsedPercent: Double = 60

    /// The shortest gap allowed between two automatic kicks of the same account.
    ///
    /// Weekly turnovers are seven days apart, so anything closer is a repeat rather than a new
    /// window — a relaunch mid-turnover, a detector firing twice, a restored backup. Twelve hours
    /// is far below the real interval and far above any plausible duplicate.
    public static let minimumInterval: TimeInterval = 12 * 3600

    /// - Parameters:
    ///   - peakPercent: the highest weekly usage seen on this account *before* the reset. `nil`
    ///     when the window was never observed, which is not the same as it being empty — an app
    ///     started after the reset knows nothing about what came before and must not guess.
    ///   - lastAutoKickedAt: when this account was last auto-kicked, across launches.
    public static func shouldKick(
        isEnabled: Bool,
        peakPercent: Double?,
        lastAutoKickedAt: Date?,
        now: Date) -> Bool
    {
        guard isEnabled else { return false }
        guard let peakPercent, peakPercent >= self.heavilyUsedPercent else { return false }

        if let lastAutoKickedAt {
            guard now.timeIntervalSince(lastAutoKickedAt) >= self.minimumInterval else { return false }
        }
        return true
    }
}
