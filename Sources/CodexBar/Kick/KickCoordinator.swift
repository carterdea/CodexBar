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
/// Who asked for a kick, which decides whether it may put a Keychain dialog on screen.
///
/// Claude's credentials usually live in Claude Code's Keychain item, and reading it can prompt.
/// A prompt is reasonable when the user just clicked the menu item and is watching. It is not
/// reasonable at a weekly turnover, which happens on the provider's schedule and may well be at
/// 3am — an unexplained authorization dialog with nobody around to connect it to anything.
enum KickTrigger {
    case user
    case automatic

    var allowsKeychainPrompt: Bool {
        self == .user
    }
}

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
    func kick(provider: UsageProvider, store: UsageStore, trigger: KickTrigger = .user) {
        guard !self.inFlight.contains(provider) else {
            self.logger.info("kick ignored: already in flight", metadata: ["provider": provider.rawValue])
            return
        }
        self.inFlight.insert(provider)

        Task { @MainActor in
            defer { self.inFlight.remove(provider) }

            let outcome = await Self.run(provider: provider, settings: store.settings, trigger: trigger)
            self.logger.info(
                "kick finished",
                metadata: ["provider": provider.rawValue, "outcome": outcome.logName])

            if outcome.warrantsRefresh {
                await store.refreshProvider(provider)
            }
            self.report(outcome, provider: provider)
        }
    }

    // MARK: - Internals

    private static func run(
        provider: UsageProvider,
        settings: SettingsStore,
        trigger: KickTrigger) async -> KickOutcome
    {
        // Provider-specific by design: how a session window is started is not derivable from
        // provider metadata. Claude begins one with an inference request; Codex begins one by
        // running its CLI. Each provider that gains a kick has to say how, so this dispatch is
        // the feature rather than an unfactored special case.
        switch provider {
        case .claude:
            do {
                // An automatic kick reads credentials without prompting, and honours the cooldown
                // that stops a failed read from re-asking on every cycle. It would rather skip a
                // window than raise a dialog the user cannot place.
                let credentials = try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
                    allowKeychainPrompt: trigger.allowsKeychainPrompt,
                    respectKeychainPromptCooldown: !trigger.allowsKeychainPrompt)
                return await ClaudeKickRunner.kick(accessToken: credentials.accessToken)
            } catch {
                // Deliberately not `.noCredentials`. Credentials usually live in Claude Code's
                // Keychain item, and the common failure is revoked or unconsented *access* to a
                // login that is perfectly valid. Flattening the two would tell the user to sign in
                // again when the fix is granting access in Settings, so the loader's own wording
                // is passed through instead.
                return .failed(message: error.localizedDescription)
            }
        case .codex:
            // `codex exec` takes its login from $CODEX_HOME and has no flag to pick an account, so
            // the kick has to land in the home of whichever account is currently active or it
            // silently starts a window on the wrong one.
            return await CodexKickRunner.kick(codexHome: self.activeCodexHome(settings: settings))
        default:
            return .unsupported(reason: L("Starting a session window is not supported for this provider."))
        }
    }

    /// `nil` means the ambient login in `~/.codex`, which is what the CLI uses with no override.
    private static func activeCodexHome(settings: SettingsStore) -> String? {
        guard case let .managedAccount(id) = settings.codexResolvedActiveSource else { return nil }
        return settings.codexAccountReconciliationSnapshot.storedAccounts
            .first { $0.id == id }?
            .managedHomePath
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
