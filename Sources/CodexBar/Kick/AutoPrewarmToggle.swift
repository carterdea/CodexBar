import SwiftUI

/// The switch that lets CodexBar send a message on an account the user is not even looking at.
///
/// Claude only, and only in Claude's pane, because Claude is the only provider with both a 5-hour
/// window that begins with a request and a per-account credential CodexBar can address. The copy
/// has to keep saying that turning this on sends a real message and spends real quota.
@MainActor
enum AutoPrewarmToggle {
    static func descriptor(store: AutoKickStore = .shared) -> ProviderSettingsToggleDescriptor {
        ProviderSettingsToggleDescriptor(
            id: "fork-auto-prewarm",
            title: L("Start the next account's session window automatically"),
            subtitle: L("auto_prewarm_subtitle"),
            binding: Binding(
                get: { store.isPrewarmEnabled },
                set: { store.isPrewarmEnabled = $0 }),
            statusText: nil,
            actions: [],
            isVisible: nil,
            isEnabled: nil,
            onChange: nil,
            onAppDidBecomeActive: nil,
            onAppearWhenEnabled: nil)
    }
}
