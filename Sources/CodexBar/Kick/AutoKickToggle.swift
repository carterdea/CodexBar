import SwiftUI

/// The one switch that lets CodexBar send a message without being asked.
///
/// Shared by every provider that supports a kick so the copy cannot drift between panes: it has to
/// keep saying, in each of them, that turning this on spends quota on the user's own account.
@MainActor
enum AutoKickToggle {
    static func descriptor(store: AutoKickStore = .shared) -> ProviderSettingsToggleDescriptor {
        ProviderSettingsToggleDescriptor(
            id: "fork-auto-kick-weekly",
            title: L("Start a new weekly window automatically"),
            subtitle: L("auto_kick_subtitle"),
            binding: Binding(
                get: { store.isEnabled },
                set: { store.isEnabled = $0 }),
            statusText: nil,
            actions: [],
            isVisible: nil,
            isEnabled: nil,
            onChange: nil,
            onAppDidBecomeActive: nil,
            onAppearWhenEnabled: nil)
    }
}
