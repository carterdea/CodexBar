import CodexBarCore
import SwiftUI

/// The activity grid as the menu shows it: no view-mode picker, no legend, and a shorter window
/// than the settings pane draws. A menu row is about a third the width of the pane, so 53 columns
/// would land under three points a cell; the trailing window keeps cells the size of a target.
struct SpendActivityMenuCardView: View {
    static let weekCount = 26

    let points: [SpendDashboardModel.TokenActivityPoint]
    let width: CGFloat
    let now: Date

    init(
        points: [SpendDashboardModel.TokenActivityPoint],
        width: CGFloat,
        now: Date = Date())
    {
        self.points = points
        self.width = width
        self.now = now
    }

    var body: some View {
        let series = SpendActivitySeries
            .make(from: self.points, now: self.now)
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

    /// Identity for the menu's height cache: the row only changes size when the window's shape
    /// does, so the day count and the trailing day are enough to spot a stale measurement.
    static func fingerprint(points: [SpendDashboardModel.TokenActivityPoint]) -> String {
        let last = points.last.map { Int($0.day.timeIntervalSince1970) } ?? 0
        return "spendActivity:\(points.count):\(last)"
    }

    private static func total(_ values: [Int]) -> Int {
        values.reduce(0) { SpendActivitySeries.saturatingAdd($0, $1) }
    }
}
