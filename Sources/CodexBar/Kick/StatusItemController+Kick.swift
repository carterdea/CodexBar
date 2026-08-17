import AppKit
import CodexBarCore

extension StatusItemController {
    /// Menu handler for "Start session window". The provider rides along as the menu item's
    /// represented object, matching how `runSwitchAccount(_:)` is wired.
    @objc
    func runKickSession(_ sender: NSMenuItem) {
        let provider = (sender.representedObject as? String)
            .flatMap(UsageProvider.init(rawValue:))
            ?? self.lastMenuProvider?.firstPartyProvider
        guard let provider else { return }
        KickCoordinator.shared.kick(provider: provider, store: self.store)
    }
}
