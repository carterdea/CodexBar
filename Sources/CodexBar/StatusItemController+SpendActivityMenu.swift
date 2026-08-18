import AppKit
import CodexBarCore
import SwiftUI

/// The activity grid in the menu, under the account cards. It reads the same spend model the
/// settings pane does, from its own controller: the pane's controller only lives while the pane
/// is on screen, and the menu needs the data whether or not settings was ever opened.
extension StatusItemController {
    static let spendActivityMenuCardID = "menuCardSpendActivity"

    func makeSpendActivityController() -> SpendDashboardController {
        let settings = self.settings
        let store = self.store
        return SpendDashboardController(
            requestBuilder: { mode in
                await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
            },
            cachedLoader: { request in
                await SpendDashboardSource.loadCached(request)
            })
    }

    /// Called when the menu opens. `update` compares configurations and returns without work when
    /// nothing moved, so an open that changes nothing costs a comparison rather than a scan.
    func refreshSpendActivityForMenuOpen() {
        guard self.settings.costUsageEnabled else {
            self.spendActivity.stop()
            return
        }
        self.spendActivity.update(configuration: SpendDashboardSource.configuration(
            settings: self.settings,
            store: self.store))
    }

    func addSpendActivityMenuCardIfNeeded(to menu: NSMenu, width: CGFloat) {
        guard self.settings.costUsageEnabled, self.menuCardRenderingEnabledForController else { return }
        let points = self.spendActivity.model.tokenActivity
        guard !points.isEmpty else { return }
        if menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
        menu.addItem(self.makeMenuCardItem(
            SpendActivityMenuCardView(points: points, width: width),
            id: Self.spendActivityMenuCardID,
            width: width,
            heightCacheScope: Self.spendActivityMenuCardID,
            heightCacheFingerprint: SpendActivityMenuCardView.fingerprint(points: points),
            containsInteractiveControls: true))
    }
}
