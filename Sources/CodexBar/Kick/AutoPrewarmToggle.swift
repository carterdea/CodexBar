import CodexBarCore
import SwiftUI

/// The switch that lets CodexBar send a message on an account the user is not even looking at.
///
/// One per provider, in that provider's own pane, because the two are separate decisions and the
/// accounts qualify on different terms. The copy has to keep saying that turning this on sends a
/// real message and spends real quota, and has to name which accounts it can actually reach.
@MainActor
enum AutoPrewarmToggle {
    static func descriptor(
        provider: UsageProvider,
        store: AutoKickStore = .shared) -> ProviderSettingsToggleDescriptor
    {
        ProviderSettingsToggleDescriptor(
            id: "fork-auto-prewarm-\(provider.rawValue)",
            title: L("Start the next account's session window automatically"),
            subtitle: L(self.subtitleKey(for: provider)),
            binding: Binding(
                get: { store.isPrewarmEnabled(for: provider) },
                set: { store.setPrewarmEnabled($0, for: provider) }),
            statusText: nil,
            actions: [],
            isVisible: nil,
            isEnabled: nil,
            onChange: nil,
            onAppDidBecomeActive: nil,
            onAppearWhenEnabled: nil)
    }

    /// Separate copy rather than one string naming both, because what the feature can reach differs:
    /// Claude needs an OAuth token the user pasted in, Codex needs an account CodexBar keeps its own
    /// login for. A user reading the wrong half would not know why nothing happens.
    private static func subtitleKey(for provider: UsageProvider) -> String {
        // Provider-specific by design: this is the sentence describing one provider's own
        // credential requirement, which no shared metadata carries.
        switch provider {
        case .codex:
            "auto_prewarm_subtitle_codex"
        default:
            "auto_prewarm_subtitle"
        }
    }
}
