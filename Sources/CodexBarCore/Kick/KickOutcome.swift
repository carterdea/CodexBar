import Foundation

/// The result of trying to "kick" an account: sending one minimal request so the provider's
/// session window starts now rather than whenever the next real piece of work lands.
///
/// A kick spends real quota on the user's own account, so every arm here is something the UI is
/// expected to say out loud. There is no silent failure case on purpose.
public enum KickOutcome: Sendable, Equatable {
    /// The provider accepted the request and the session window is now running.
    case started

    /// A session window was already open, so nothing was sent.
    case alreadyRunning

    /// No usable credentials for this account. The user needs to sign in again.
    case noCredentials

    /// This account cannot be kicked at all, for a reason worth showing (for example a
    /// ClaudeSwap account, whose credentials belong to the `cswap` subprocess and are never
    /// read by CodexBar).
    case unsupported(reason: String)

    /// The request was made and the provider refused it, or the transport failed.
    case failed(message: String)
}

extension KickOutcome {
    /// Whether the caller should refresh usage afterwards. Only a kick that actually started a
    /// window changes anything worth re-reading.
    public var warrantsRefresh: Bool {
        self == .started
    }
}
