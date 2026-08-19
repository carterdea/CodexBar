import CodexBarCore
import Foundation
import SwiftUI

struct SpendActivityHeatmapView: View {
    let points: [SpendDashboardModel.TokenActivityPoint]
    let now: Date

    @AppStorage("spendActivityViewMode") private var mode: SpendActivityViewMode = .daily
    @State private var series: SpendActivitySeries

    init(points: [SpendDashboardModel.TokenActivityPoint], now: Date = Date()) {
        self.points = points
        self.now = now
        self._series = State(initialValue: SpendActivitySeries.make(from: points, now: now))
    }

    var body: some View {
        let hasActivity = (self.series.daily.max() ?? 0) > 0
        let hasUnknownCoverage = self.series.hasUnknownCoverage
        let totalTokens = self.series.totalTokens
        let coverageText = spendDashboardCoverageText(
            covered: self.series.coveredDayCount,
            requested: self.series.visibleDayCount)
        let weekly = self.series.weeklyActivity()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Token activity"))
                        .font(.headline)
                    if hasActivity {
                        Text(self.activitySummary(totalTokens: totalTokens, coverageText: coverageText))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if hasUnknownCoverage {
                        Text("\(L("Unavailable")) · \(coverageText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker(L("View"), selection: self.$mode) {
                    ForEach(SpendActivityViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if hasActivity || hasUnknownCoverage {
                switch self.mode {
                case .daily:
                    SpendActivityDailyGrid(series: self.series)
                    self.dailyLegend
                case .weekly:
                    SpendActivityWeekGrid(
                        series: self.series,
                        activity: weekly,
                        cumulative: false)
                    self.caption(
                        L("Each column = 1 week"),
                        showsUnavailable: weekly.isCovered.contains(false))
                case .cumulative:
                    SpendActivityWeekGrid(
                        series: self.series,
                        activity: weekly.cumulative(),
                        cumulative: true)
                    self.caption(L("Running total"), showsUnavailable: hasUnknownCoverage)
                }
            } else {
                Text(L("No activity in the last 12 months"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: self.points) { _, points in
            self.series = SpendActivitySeries.make(from: points, now: self.now)
        }
    }

    private var dailyLegend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text(L("Less"))
            ForEach(0...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(SpendActivityLevels.color(forLevel: level))
                    .frame(width: 9, height: 9)
            }
            Text(L("More"))
            if self.series.hasUnknownCoverage {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(SpendActivityLevels.unavailableFill)
                    .frame(width: 9, height: 9)
                    .padding(.leading, 6)
                Text(L("Unavailable"))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func caption(_ text: String, showsUnavailable: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Spacer()
            if showsUnavailable {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(SpendActivityLevels.unavailableFill)
                    .frame(width: 9, height: 9)
                Text(L("Unavailable"))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func activitySummary(totalTokens: Int, coverageText: String) -> String {
        let total = UsageFormatter.tokenCountString(totalTokens)
        return self.series.hasUnknownCoverage
            ? "\(total) · \(coverageText)"
            : "\(total) \(L("in the last year"))"
    }
}

struct SpendActivityDailyGrid: View {
    let series: SpendActivitySeries

    @State private var hoveredIndex: Int?
    @State private var keyboardIndex: Int?
    @FocusState private var isKeyboardFocused: Bool

    private let rows = SpendActivitySeries.dayCount

    /// The grid draws whatever the series carries, so a narrowed series draws fewer columns.
    private var columns: Int {
        self.series.columnCount
    }

    var body: some View {
        let levels = self.series.dailyLevels
        VStack(alignment: .leading, spacing: 3) {
            self.monthRow
            GeometryReader { proxy in
                let gridFrame = SpendActivityGridGeometry.gridFrame(
                    containerWidth: proxy.size.width,
                    columns: self.columns)
                let pitch = gridFrame.width / CGFloat(self.columns)
                let cell = max(pitch - 2, 2)
                ZStack(alignment: .topLeading) {
                    self.weekdayLabels(rowPitch: pitch)
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            let corner = min(cell * 0.22, 2.5)
                            for index in 0..<(self.columns * self.rows) where self.isVisibleCell(index) {
                                let col = index / self.rows
                                let row = index % self.rows
                                let rect = CGRect(
                                    x: CGFloat(col) * pitch + (pitch - cell) / 2,
                                    y: CGFloat(row) * pitch + (pitch - cell) / 2,
                                    width: cell,
                                    height: cell)
                                let fill = self.series.isCovered[index]
                                    ? SpendActivityLevels.color(forLevel: levels[index])
                                    : SpendActivityLevels.unavailableFill
                                context.fill(
                                    RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: rect),
                                    with: .color(fill))
                            }
                        }
                        self.hoverHighlight(cell: cell, pitch: pitch)
                        self.tooltip(size: gridFrame.size, pitch: pitch)
                    }
                    .frame(width: gridFrame.width, height: gridFrame.height)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            self.hoveredIndex = self.cellIndex(at: location, pitch: pitch)
                        case .ended:
                            self.hoveredIndex = nil
                        }
                    }
                    .offset(x: gridFrame.minX)
                }
            }
            .aspectRatio(CGFloat(self.columns + 2) / CGFloat(self.rows), contentMode: .fit)
        }
        .focusable()
        .focused(self.$isKeyboardFocused)
        .onMoveCommand(perform: self.moveKeyboardSelection)
        .onChange(of: self.isKeyboardFocused) { _, isFocused in
            if isFocused, self.keyboardIndex == nil {
                self.keyboardIndex = self.lastVisibleIndex
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Token activity"))
        .accessibilityValue(self.accessibilityValue)
        .accessibilityChildren {
            ForEach(self.series.daily.indices.filter(self.series.isVisible), id: \.self) { index in
                if let date = self.series.date(at: index) {
                    Text(self.accessibilityDescription(at: index, date: date))
                }
            }
        }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                self.moveKeyboardSelectionChronologically(by: 1)
            case .decrement:
                self.moveKeyboardSelectionChronologically(by: -1)
            @unknown default:
                break
            }
        }
    }

    private var monthRow: some View {
        GeometryReader { proxy in
            let gridFrame = SpendActivityGridGeometry.gridFrame(
                containerWidth: proxy.size.width,
                columns: self.columns)
            let pitch = gridFrame.width / CGFloat(self.columns)
            ZStack(alignment: .topLeading) {
                ForEach(self.monthMarkers(pitch: pitch)) { marker in
                    Text(marker.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .offset(x: gridFrame.minX + marker.offset)
                }
            }
        }
        .frame(height: 14)
    }

    private func weekdayLabels(rowPitch: CGFloat) -> some View {
        ForEach(SpendActivityWeekday.labeledRows, id: \.self) { row in
            Text(SpendActivityWeekday.label(for: row))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: SpendActivityGridGeometry.weekdayGutterWidth, alignment: .trailing)
                .position(
                    x: SpendActivityGridGeometry.weekdayGutterWidth / 2,
                    y: SpendActivityGridGeometry.weekdayCenter(row: row, rowPitch: rowPitch))
        }
    }

    @ViewBuilder
    private func hoverHighlight(cell: CGFloat, pitch: CGFloat) -> some View {
        if let index = self.activeIndex {
            let col = index / self.rows
            let row = index % self.rows
            RoundedRectangle(cornerRadius: min(cell * 0.22, 2.5), style: .continuous)
                .stroke(Color.primary.opacity(0.7), lineWidth: 1.5)
                .frame(width: cell, height: cell)
                .position(
                    x: CGFloat(col) * pitch + pitch / 2,
                    y: CGFloat(row) * pitch + pitch / 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func tooltip(size: CGSize, pitch: CGFloat) -> some View {
        if let index = self.activeIndex, let date = self.series.date(at: index) {
            let col = index / self.rows
            let row = index % self.rows
            let anchorX = CGFloat(col) * pitch + pitch / 2
            let anchorY = CGFloat(row) * pitch + pitch / 2
            let width = min(SpendActivityGridGeometry.tooltipWidth, max(size.width - 8, 1))
            let content = self.tooltipContent(at: index, date: date)
            let height = SpendActivityGridGeometry.tooltipHeight(
                detailLineCount: content.providerLines.count)
            let originY = SpendActivityGridGeometry.tooltipOriginY(
                anchorY: anchorY,
                tooltipHeight: height,
                gridHeight: size.height)
            SpendActivityTooltip(content: content, width: width)
                .position(
                    x: SpendActivityGridGeometry.tooltipCenterX(
                        anchorX: anchorX,
                        tooltipWidth: width,
                        gridWidth: size.width),
                    y: originY + height / 2)
                .allowsHitTesting(false)
        }
    }

    private func tooltipContent(at index: Int, date: Date) -> SpendActivityTooltipContent {
        SpendActivityTooltipFormatting.content(
            date: date,
            providers: self.series.providers[index],
            isCovered: self.series.isCovered[index])
    }

    private func cellIndex(at location: CGPoint, pitch: CGFloat) -> Int? {
        guard pitch > 0 else { return nil }
        let col = Int(location.x / pitch)
        let row = Int(location.y / pitch)
        guard col >= 0, col < self.columns, row >= 0, row < self.rows else { return nil }
        let index = col * self.rows + row
        return self.isVisibleCell(index) ? index : nil
    }

    private func isVisibleCell(_ index: Int) -> Bool {
        self.series.isVisible(index)
    }

    private var activeIndex: Int? {
        if let hoveredIndex {
            return hoveredIndex
        }
        return self.keyboardIndex
    }

    private var lastVisibleIndex: Int? {
        self.series.daily.indices.last(where: self.series.isVisible)
    }

    private func moveKeyboardSelection(_ direction: MoveCommandDirection) {
        self.hoveredIndex = nil
        guard let current = self.keyboardIndex ?? self.lastVisibleIndex else { return }
        self.keyboardIndex = current
        let move: SpendActivityGridMove? = switch direction {
        case .left:
            .left
        case .right:
            .right
        case .up:
            .up
        case .down:
            .down
        default:
            nil
        }
        guard let move else { return }
        let candidate = SpendActivityGridNavigation.candidate(from: current, move: move, rows: self.rows)
        guard let candidate, self.isVisibleCell(candidate) else { return }
        self.keyboardIndex = candidate
    }

    private func moveKeyboardSelectionChronologically(by offset: Int) {
        self.hoveredIndex = nil
        guard let current = self.keyboardIndex else {
            self.keyboardIndex = self.lastVisibleIndex
            return
        }
        let candidate = current + offset
        guard self.isVisibleCell(candidate) else { return }
        self.keyboardIndex = candidate
    }

    private struct MonthMarker: Identifiable {
        let id: Int
        let offset: CGFloat
        let label: String
    }

    private func monthMarkers(pitch: CGFloat) -> [MonthMarker] {
        let formatter = DateFormatter()
        formatter.locale = codexBarLocalizedResourceLocale()
        formatter.dateFormat = "MMM"
        var markers: [MonthMarker] = []
        var lastLabel = ""
        for col in 0..<self.columns {
            guard let date = self.series.date(at: col * self.rows),
                  self.series.calendar.component(.day, from: date) <= 7
            else { continue }
            let label = formatter.string(from: date)
            guard label != lastLabel else { continue }
            markers.append(MonthMarker(id: col, offset: CGFloat(col) * pitch, label: label))
            lastLabel = label
        }
        return markers
    }

    private var accessibilityValue: String {
        if let index = self.activeIndex, let date = self.series.date(at: index) {
            return self.accessibilityDescription(at: index, date: date)
        }
        let total = UsageFormatter.tokenCountString(self.series.totalTokens)
        guard self.series.hasUnknownCoverage else { return total }
        let coverage = spendDashboardCoverageText(
            covered: self.series.coveredDayCount,
            requested: self.series.visibleDayCount)
        return "\(total) · \(coverage)"
    }

    private func accessibilityDescription(at index: Int, date: Date) -> String {
        self.tooltipContent(at: index, date: date).accessibilityLine
    }
}

private struct SpendActivityWeekGrid: View {
    let series: SpendActivitySeries
    let activity: SpendActivityAggregateSeries
    let cumulative: Bool

    @State private var hoverLocation: CGPoint?

    private let columns = SpendActivitySeries.weekCount
    private let rows = SpendActivitySeries.dayCount

    var body: some View {
        let maxValue = self.activity.values.enumerated()
            .filter { self.activity.isCovered[$0.offset] }
            .map(\.element)
            .max() ?? 0
        GeometryReader { proxy in
            let gridFrame = SpendActivityGridGeometry.gridFrame(containerWidth: proxy.size.width)
            let pitch = gridFrame.width / CGFloat(self.columns)
            let cell = max(pitch - 2, 2)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let corner = min(cell * 0.22, 2.5)
                    for col in 0..<self.columns where col < self.activity.values.count && self.isVisible(col) {
                        let value = self.activity.values[col]
                        let isCovered = self.activity.isCovered[col]
                        let rawFill = maxValue > 0
                            ? Int((Double(value) / Double(maxValue) * Double(self.rows)).rounded())
                            : 0
                        let filled = value > 0 ? max(rawFill, 1) : 0
                        for row in 0..<self.rows {
                            let fill: Color = if !isCovered {
                                SpendActivityLevels.unavailableFill
                            } else if row >= self.rows - filled {
                                SpendActivityLevels.uniformFill
                            } else {
                                SpendActivityLevels.color(forLevel: 0)
                            }
                            let rect = CGRect(
                                x: CGFloat(col) * pitch + (pitch - cell) / 2,
                                y: CGFloat(row) * pitch + (pitch - cell) / 2,
                                width: cell,
                                height: cell)
                            context.fill(
                                RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: rect),
                                with: .color(fill))
                        }
                    }
                }
                self.tooltip(size: gridFrame.size, pitch: pitch)
            }
            .frame(width: gridFrame.width, height: gridFrame.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    self.hoverLocation = self.column(at: location, pitch: pitch) == nil ? nil : location
                case .ended:
                    self.hoverLocation = nil
                }
            }
            .offset(x: gridFrame.minX)
        }
        .aspectRatio(CGFloat(self.columns + 2) / CGFloat(self.rows), contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Token activity"))
        .accessibilityValue(self.accessibilityValue)
        .accessibilityChildren {
            ForEach(self.activity.values.indices.filter(self.isVisible), id: \.self) { index in
                if let weekStart = self.series.weekStartDate(at: index) {
                    Text(self.accessibilityDescription(at: index, weekStart: weekStart))
                }
            }
        }
    }

    @ViewBuilder
    private func tooltip(size: CGSize, pitch: CGFloat) -> some View {
        if let location = self.hoverLocation,
           let col = self.column(at: location, pitch: pitch),
           col < self.activity.values.count,
           let weekStart = self.series.weekStartDate(at: col)
        {
            let width = min(SpendActivityGridGeometry.tooltipWidth, max(size.width - 8, 1))
            let content = SpendActivityTooltipFormatting.aggregateContent(
                weekStart: weekStart,
                value: self.value(at: col))
            let height = SpendActivityGridGeometry.tooltipHeight(
                detailLineCount: content.providerLines.count)
            let originY = SpendActivityGridGeometry.tooltipOriginY(
                anchorY: location.y,
                tooltipHeight: height,
                gridHeight: size.height)
            SpendActivityTooltip(content: content, width: width)
                .position(
                    x: SpendActivityGridGeometry.tooltipCenterX(
                        anchorX: CGFloat(col) * pitch + pitch / 2,
                        tooltipWidth: width,
                        gridWidth: size.width),
                    y: originY + height / 2)
                .allowsHitTesting(false)
        }
    }

    private func column(at location: CGPoint, pitch: CGFloat) -> Int? {
        guard pitch > 0 else { return nil }
        let col = Int(location.x / pitch)
        guard col >= 0, col < self.columns, self.isVisible(col) else { return nil }
        return col
    }

    private func isVisible(_ column: Int) -> Bool {
        guard let start = self.series.weekStartDate(at: column) else { return false }
        let end = self.series.calendar.date(
            byAdding: .day,
            value: SpendActivitySeries.dayCount - 1,
            to: start) ?? start
        return start <= self.series.today && end >= self.series.rangeStart
    }

    private var accessibilityTokenTotal: Int {
        if self.cumulative {
            return self.activity.values.last ?? 0
        }
        return self.activity.values.reduce(0) { total, value in
            let result = total.addingReportingOverflow(value)
            return result.overflow ? Int.max : result.partialValue
        }
    }

    private var accessibilityValue: String {
        let total = UsageFormatter.tokenCountString(self.accessibilityTokenTotal)
        let hasUnavailable = self.activity.isCovered.enumerated().contains { index, covered in
            self.isVisible(index) && !covered
        }
        guard hasUnavailable else { return total }
        let coverage = spendDashboardCoverageText(
            covered: self.series.coveredDayCount,
            requested: self.series.visibleDayCount)
        return "\(total) · \(coverage)"
    }

    private func value(at index: Int) -> String {
        self.activity.isCovered[index]
            ? UsageFormatter.tokenCountString(self.activity.values[index])
            : L("Unavailable")
    }

    private func accessibilityDescription(at index: Int, weekStart: Date) -> String {
        SpendActivityAccessibility.description(date: weekStart, value: self.value(at: index))
    }
}

private struct SpendActivityTooltip: View {
    let content: SpendActivityTooltipContent
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(self.content.dayLine)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            ForEach(self.content.providerLines, id: \.self) { line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, SpendActivityGridGeometry.tooltipVerticalPadding)
        .frame(width: self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3))
        }
    }
}
