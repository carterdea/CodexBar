import CodexBarCore
import Foundation
import SwiftUI

enum SpendActivityViewMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case cumulative

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .daily: L("Daily")
        case .weekly: L("Weekly")
        case .cumulative: L("Cumulative")
        }
    }
}

struct SpendActivitySeries {
    static let weekCount = 53
    static let dayCount = 7
    static let rangeDayCount = 365

    let daily: [Int]
    let isCovered: [Bool]
    /// Whether the scan window reached the day. A day can be scanned and still uncovered when the
    /// source data is missing, which is a real gap rather than a window edge.
    let isScanned: [Bool]
    /// The providers behind each cell, in the order the tooltip lists them.
    let providers: [[SpendDashboardModel.ProviderActivity]]
    let start: Date
    let rangeStart: Date
    let today: Date
    let calendar: Calendar

    init(
        daily: [Int],
        isCovered: [Bool],
        isScanned: [Bool]? = nil,
        providers: [[SpendDashboardModel.ProviderActivity]]? = nil,
        start: Date,
        rangeStart: Date,
        today: Date,
        calendar: Calendar)
    {
        self.daily = daily
        self.isCovered = isCovered
        self.isScanned = isScanned ?? [Bool](repeating: true, count: daily.count)
        self.providers = providers ?? Array(repeating: [], count: daily.count)
        self.start = start
        self.rangeStart = rangeStart
        self.today = today
        self.calendar = calendar
    }

    static func make(
        from points: [SpendDashboardModel.TokenActivityPoint],
        now: Date = Date(),
        calendar: Calendar = .current) -> Self
    {
        var totals: [Date: Int] = [:]
        var providersByDay: [Date: [SpendDashboardModel.ProviderActivity]] = [:]
        var unknownDays: Set<Date> = []
        var unscannedDays: Set<Date> = []
        for point in points {
            let day = calendar.startOfDay(for: point.day)
            if !point.isScanned {
                unscannedDays.insert(day)
            }
            guard let totalTokens = point.totalTokens else {
                totals.removeValue(forKey: day)
                providersByDay.removeValue(forKey: day)
                unknownDays.insert(day)
                continue
            }
            guard !unknownDays.contains(day) else { continue }
            totals[day] = Self.saturatingAdd(totals[day] ?? 0, max(totalTokens, 0))
            providersByDay[day, default: []].append(contentsOf: point.providers)
        }

        let today = calendar.startOfDay(for: now)
        let rangeStart = calendar.date(
            byAdding: .day,
            value: -(Self.rangeDayCount - 1),
            to: today) ?? today
        let rangeStartWeekday = calendar.component(.weekday, from: rangeStart)
        let start = calendar.date(
            byAdding: .day,
            value: -(rangeStartWeekday - 1),
            to: rangeStart) ?? rangeStart
        let cellCount = Self.weekCount * Self.dayCount
        var daily = [Int](repeating: 0, count: cellCount)
        var isCovered = [Bool](repeating: false, count: cellCount)
        var isScanned = [Bool](repeating: false, count: cellCount)
        var providers = [[SpendDashboardModel.ProviderActivity]](repeating: [], count: cellCount)
        for index in 0..<cellCount {
            guard let date = calendar.date(byAdding: .day, value: index, to: start),
                  rangeStart...today ~= date
            else {
                continue
            }
            isScanned[index] = !unscannedDays.contains(date)
            guard !unknownDays.contains(date), let total = totals[date] else { continue }
            daily[index] = total
            isCovered[index] = true
            providers[index] = SpendDashboardModel.ProviderActivity.merged(providersByDay[date] ?? [])
        }
        return Self(
            daily: daily,
            isCovered: isCovered,
            isScanned: isScanned,
            providers: providers,
            start: start,
            rangeStart: rangeStart,
            today: today,
            calendar: calendar)
    }

    func date(at index: Int) -> Date? {
        self.calendar.date(byAdding: .day, value: index, to: self.start)
    }

    func weekStartDate(at week: Int) -> Date? {
        self.calendar.date(byAdding: .day, value: week * Self.dayCount, to: self.start)
    }

    var visibleDayCount: Int {
        self.daily.indices.filter(self.isVisible).count
    }

    var coveredDayCount: Int {
        self.daily.indices.count(where: { self.isVisible($0) && self.isCovered[$0] })
    }

    var hasUnknownCoverage: Bool {
        self.coveredDayCount < self.visibleDayCount
    }

    func weeklyActivity() -> SpendActivityAggregateSeries {
        let firstScannedIndex = self.daily.indices.first { self.isVisible($0) && self.isScanned[$0] }
        var values: [Int] = []
        var coverage: [Bool] = []
        var scanned: [Bool] = []
        for start in stride(from: 0, to: self.daily.count, by: Self.dayCount) {
            let indices = start..<min(start + Self.dayCount, self.daily.count)
            let visible = indices.filter(self.isVisible)
            // The scanned region is contiguous, so unscanned days split into a leading window edge
            // and a trailing stale suffix. Only days before the first scanned day are the window
            // edge; they cannot make a week unavailable. Every visible day from that point on
            // counts, so a trailing unscanned day (a stale snapshot) keeps its week — and every
            // later running total — unavailable.
            let counted: [Int] = if let firstScannedIndex {
                visible.filter { $0 >= firstScannedIndex }
            } else {
                []
            }
            values.append(visible.reduce(0) { Self.saturatingAdd($0, self.daily[$1]) })
            coverage.append(!counted.isEmpty && counted.allSatisfy { self.isCovered[$0] })
            scanned.append(!counted.isEmpty)
        }
        return SpendActivityAggregateSeries(values: values, isCovered: coverage, isScanned: scanned)
    }

    func isVisible(_ index: Int) -> Bool {
        guard let date = self.date(at: index) else { return false }
        return self.rangeStart...self.today ~= date
    }

    /// Levels for the daily grid. The ramp ranks on token counts, which reads a day that only
    /// cost money as an empty day — that day has no token bucket to rank. Floor those at the
    /// lowest visible level instead, so a provider that worked always draws as having worked.
    /// `providers` is the same non-empty gate the tooltip decides to print a line on.
    var dailyLevels: [Int] {
        zip(SpendActivityLevels.dailyLevels(self.daily), self.providers).map { level, providers in
            providers.isEmpty ? level : max(level, 1)
        }
    }

    /// Every cell's tokens, overflow-safe.
    var totalTokens: Int {
        self.daily.reduce(0, Self.saturatingAdd)
    }

    /// The same year narrowed to its last `weeks` columns, for surfaces too narrow to draw 53 of
    /// them at a readable cell size. Today keeps the last column, which is how the grid marks it.
    func trailingWeeks(_ weeks: Int) -> Self {
        let columns = max(1, weeks)
        guard columns < Self.weekCount else { return self }
        let dropped = (Self.weekCount - columns) * Self.dayCount
        let start = self.calendar.date(byAdding: .day, value: dropped, to: self.start) ?? self.start
        return Self(
            daily: Array(self.daily[dropped...]),
            isCovered: Array(self.isCovered[dropped...]),
            isScanned: Array(self.isScanned[dropped...]),
            providers: Array(self.providers[dropped...]),
            start: start,
            rangeStart: max(self.rangeStart, start),
            today: self.today,
            calendar: self.calendar)
    }

    /// How many columns this series draws. Equal to `Self.weekCount` unless it was narrowed.
    var columnCount: Int {
        self.daily.count / Self.dayCount
    }

    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }
}

struct SpendActivityAggregateSeries: Equatable {
    let values: [Int]
    let isCovered: [Bool]
    /// Whether the week holds any day at or after the first scanned day. Weeks entirely before the
    /// scan window are skipped by the running coverage; weeks at or after it participate.
    let isScanned: [Bool]

    init(values: [Int], isCovered: [Bool], isScanned: [Bool]? = nil) {
        self.values = values
        self.isCovered = isCovered
        self.isScanned = isScanned ?? [Bool](repeating: true, count: values.count)
    }

    /// Running total per week. The grid always spans a full year, so a scan window shorter than
    /// 365 days leaves an unscanned prefix. That prefix must not mark the whole series
    /// unavailable, so the running coverage starts at the first scanned week.
    ///
    /// An unscanned week and an unknown week are not the same thing. A week the scan never reached
    /// carries no information either way. A week the scan reached but could not resolve is a real
    /// gap, and every later total is then only a lower bound, so it stays unavailable.
    func cumulative() -> Self {
        var total = 0
        var hasStarted = false
        var coverageIsComplete = true
        var cumulativeValues: [Int] = []
        var cumulativeCoverage: [Bool] = []
        for index in self.values.indices {
            total = SpendActivitySeries.saturatingAdd(total, self.values[index])
            if self.isScanned[index] {
                hasStarted = true
            }
            if hasStarted {
                coverageIsComplete = coverageIsComplete && self.isCovered[index]
            }
            cumulativeValues.append(total)
            cumulativeCoverage.append(hasStarted && coverageIsComplete)
        }
        return Self(values: cumulativeValues, isCovered: cumulativeCoverage, isScanned: self.isScanned)
    }
}

enum SpendActivityLevels {
    static func dailyLevels(_ values: [Int]) -> [Int] {
        let maxValue = values.max() ?? 0
        return values.map { value in
            guard value > 0, maxValue > 0 else { return 0 }
            let ratio = Double(value) / Double(maxValue)
            if ratio > 0.75 {
                return 4
            }
            if ratio > 0.5 {
                return 3
            }
            if ratio > 0.25 {
                return 2
            }
            return 1
        }
    }

    static func weeklyTotals(_ daily: [Int]) -> [Int] {
        stride(from: 0, to: daily.count, by: SpendActivitySeries.dayCount).map { start in
            daily[start..<min(start + SpendActivitySeries.dayCount, daily.count)].reduce(0) { total, value in
                let result = total.addingReportingOverflow(value)
                return result.overflow ? Int.max : result.partialValue
            }
        }
    }

    static func cumulativeTotals(_ weekly: [Int]) -> [Int] {
        var sum = 0
        return weekly.map { value in
            let result = sum.addingReportingOverflow(value)
            sum = result.overflow ? Int.max : result.partialValue
            return sum
        }
    }

    static func color(forLevel level: Int) -> Color {
        switch level {
        case 4: self.rgb(0x216E39)
        case 3: self.rgb(0x30A14E)
        case 2: self.rgb(0x40C463)
        case 1: self.rgb(0x9BE9A8)
        default: self.rgb(0xEBEDF0)
        }
    }

    static var uniformFill: Color {
        self.rgb(0x40C463)
    }

    static var unavailableFill: Color {
        self.rgb(0xD6DCE5)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

struct SpendActivityGridGeometry {
    static let weekdayGutterWidth: CGFloat = 40
    static let gridSpacing: CGFloat = 8
    static let tooltipInset: CGFloat = 4
    static let tooltipGap: CGFloat = 7
    static let tooltipWidth: CGFloat = 180
    static let tooltipDayLineHeight: CGFloat = 13
    static let tooltipDetailLineHeight: CGFloat = 14
    static let tooltipVerticalPadding: CGFloat = 6

    /// Where the tooltip is placed, not how tall it is drawn — the tooltip lays itself out from
    /// its own text so a font change can never clip a provider line. A drifting estimate shifts
    /// the tooltip against the pointer instead of truncating it.
    static func tooltipHeight(detailLineCount: Int) -> CGFloat {
        self.tooltipVerticalPadding * 2
            + self.tooltipDayLineHeight
            + CGFloat(detailLineCount) * self.tooltipDetailLineHeight
    }

    static func gridFrame(containerWidth: CGFloat, columns: Int = SpendActivitySeries.weekCount) -> CGRect {
        let leading = self.weekdayGutterWidth + self.gridSpacing
        let width = max(containerWidth - leading, 0)
        let pitch = columns > 0 ? width / CGFloat(columns) : 0
        return CGRect(x: leading, y: 0, width: width, height: pitch * CGFloat(SpendActivitySeries.dayCount))
    }

    static func weekdayCenter(row: Int, rowPitch: CGFloat) -> CGFloat {
        (CGFloat(row) + 0.5) * rowPitch
    }

    static func tooltipCenterX(anchorX: CGFloat, tooltipWidth: CGFloat, gridWidth: CGFloat) -> CGFloat {
        let halfWidth = tooltipWidth / 2
        let lower = min(halfWidth + self.tooltipInset, gridWidth / 2)
        let upper = max(gridWidth - halfWidth - self.tooltipInset, gridWidth / 2)
        return min(max(anchorX, lower), upper)
    }

    static func tooltipOriginY(anchorY: CGFloat, tooltipHeight: CGFloat, gridHeight: CGFloat) -> CGFloat {
        let below = anchorY + self.tooltipGap
        if below + tooltipHeight <= gridHeight {
            return below
        }
        return max(anchorY - tooltipHeight - self.tooltipGap, 0)
    }
}

enum SpendActivityGridMove {
    case left
    case right
    case up
    case down
}

enum SpendActivityGridNavigation {
    static func candidate(from current: Int, move: SpendActivityGridMove, rows: Int) -> Int? {
        guard rows > 0 else { return nil }
        let row = current % rows
        return switch move {
        case .left:
            current - rows
        case .right:
            current + rows
        case .up where row > 0:
            current - 1
        case .down where row < rows - 1:
            current + 1
        default:
            nil
        }
    }
}

enum SpendActivityWeekday {
    static let labeledRows = [1, 3, 5]

    static func label(for row: Int, locale: Locale? = nil) -> String {
        guard self.labeledRows.contains(row) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale ?? codexBarLocalizedResourceLocale()
        guard let symbols = formatter.shortStandaloneWeekdaySymbols, symbols.indices.contains(row) else {
            return ""
        }
        return symbols[row]
    }
}

enum SpendActivityDateFormatting {
    static func mediumDateString(_ date: Date, locale: Locale? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale ?? codexBarLocalizedResourceLocale()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// "Wed, Jun 3" — weekday, month, day, ordered by the resolved locale. A heatmap cell is read
    /// against its column, so the weekday earns its place while the year does not.
    static func weekdayDateString(_ date: Date, locale: Locale? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale ?? codexBarLocalizedResourceLocale()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }
}

enum SpendActivityAccessibility {
    static func description(date: Date, value: String, locale: Locale? = nil) -> String {
        "\(SpendActivityDateFormatting.mediumDateString(date, locale: locale)): \(value)"
    }
}
