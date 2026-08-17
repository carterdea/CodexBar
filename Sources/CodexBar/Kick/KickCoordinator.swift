import CodexBarCore
import Foundation

/// Owns "kick" requests: sending one minimal message so a provider's session window starts now.
///
/// A separate object rather than state on `StatusItemController` for two reasons. It keeps the
/// in-flight guard in one place for every caller (menu today, auto-kick later), and it means the
/// fork adds no stored properties to a heavily-edited upstream type.
///
/// Occupancy is **single, per provider, and rejecting**: a kick requested while one is already in
/// flight is dropped, never queued. A kick spends real quota, so a queue would turn one impatient
/// double-click into two messages.
@MainActor
final class KickCoordinator {
    static let shared = KickCoordinator()

    private var inFlight: Set<UsageProvider> = []
    private let logger = CodexBarLog.logger(LogCategories.notifications)

    /// Whether a kick is currently running for this provider. Callers use this to disable the
    /// control rather than to decide whether to send — ``kick(provider:store:)`` re-checks.
    func isKicking(_ provider: UsageProvider) -> Bool {
        self.inFlight.contains(provider)
    }

    /// Runs a kick if one is not already in flight for `provider`, then refreshes usage if a
    /// window actually started.
    func kick(provider: UsageProvider, store: UsageStore) {
        guard !self.inFlight.contains(provider) else {
            self.logger.info("kick ignored: already in flight", metadata: ["provider": provider.rawValue])
            return
        }
        self.inFlight.insert(provider)

        Task { @MainActor in
            defer { self.inFlight.remove(provider) }

            let outcome = await Self.run(provider: provider)
            self.logger.info(
                "kick finished",
                metadata: ["provider": provider.rawValue, "outcome": String(describing: outcome)])

            if outcome.warrantsRefresh {
                await store.refreshProvider(provider)
            }
            self.report(outcome, provider: provider)
        }
    }

    // MARK: - Internals

    private static func run(provider: UsageProvider) async -> KickOutcome {
        switch provider {
        case .claude:
            do {
                let credentials = try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh()
                return await ClaudeKickRunner.kick(accessToken: credentials.accessToken)
            } catch {
                return .noCredentials
            }
        default:
            return .unsupported(reason: L("Starting a session window is not supported for this provider."))
        }
    }

    /// Every outcome is said out loud. A kick spends quota on the user's own account, so silence
    /// after a tap is not an acceptable answer — including when nothing was sent.
    private func report(_ outcome: KickOutcome, provider: UsageProvider) {
        let title = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let body = switch outcome {
        case .started:
            L("Session window started.")
        case .alreadyRunning:
            L("A session window was already running, so nothing was sent.")
        case .noCredentials:
            L("Could not start a session window: sign in to this account again.")
        case let .unsupported(reason):
            reason
        case let .failed(message):
            message
        }

        AppNotifications.shared.post(
            idPrefix: "kick-\(provider.rawValue)",
            title: title,
            body: body,
            soundEnabled: false)
    }
}
