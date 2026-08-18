import CodexBarCore
import SwiftUI

/// The activity grid as the menu shows it: no view-mode picker, no legend, and a shorter window
/// than the settings pane draws. A menu row is about a third the width of the pane, so 53 columns
/// would land under three points a cell; the trailing window keeps cells the size of a target.
struct SpendActivityMenuCardView: View {
    static let weekCount = 26

    let points: [SpendDashboardModel.TokenActivityPoint]
    let width: CGFloat

    var body: some View {
        let series = SpendActivitySeries
            .make(from: self.points)
            .trailingWeeks(Self.weekCount)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L("Token activity"))
                    .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
                Spacer(minLength: 8)
                Text(UsageFormatter.tokenCountString(Self.total(series.daily)))
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
            }
            SpendActivityDailyGrid(series: series)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: self.width, alignment: .leading)
    }

    private static func total(_ values: [Int]) -> Int {
        values.reduce(0) { SpendActivitySeries.saturatingAdd($0, $1) }
    }
}
