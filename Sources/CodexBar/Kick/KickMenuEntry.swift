import CodexBarCore

/// Builds the "Start session window" menu entry.
///
/// Shared so Claude and Codex cannot drift on when the kick is offered: the gating rules are about
/// the *window*, which both providers have, even though how a window gets started differs.
@MainActor
enum KickMenuEntry {
    static func make(provider: UsageProvider, store: UsageStore) -> ProviderMenuEntry {
        let label = L("Start session window")

        if KickCoordinator.shared.isKicking(provider) {
            return .unavailable(label, L("Starting…"))
        }

        // A synthetic placeholder is a provider standing in for a session lane it did not report,
        // i.e. no live window — which is exactly when a kick is worth offering. Reading it as a
        // running window would hide the action precisely when it is most useful.
        let session = store.snapshot(for: provider.instanceID)?.primary
        let isRunning = session.map { !$0.isSyntheticPlaceholder && $0.resetsAt != nil } ?? false
        if isRunning {
            return .unavailable(label, L("A session window is already running."))
        }

        return .action(label, .kickSession(provider))
    }
}
