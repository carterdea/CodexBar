import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// The provider split behind the heatmap: what the model carries per day, and what the colour
/// ramp ranks on once it does.
struct SpendActivityProviderSplitTests {
    @Test
    func `a day carries one entry per provider, merged across that provider's accounts`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                Self.input(id: "claude", provider: .claude, name: "Claude", tokens: 400, cost: 2),
                Self.input(id: "codex-a", provider: .codex, name: "Codex", tokens: 30, cost: 1),
                Self.input(id: "codex-b", provider: .codex, name: "Codex", tokens: 70, cost: 0.5),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        let today = try #require(Self.point(on: Self.now, in: model))

        #expect(today.providers.map(\.displayName) == ["Claude", "Codex"])
        #expect(today.providers.map(\.tokens) == [400, 100])
        #expect(today.providers.map(\.costUSD) == [2, 1.5])
        #expect(today.totalTokens == 500)
    }

    @Test
    func `a provider that did nothing that day gets no entry`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                Self.input(id: "claude", provider: .claude, name: "Claude", tokens: 0, cost: 0),
                Self.input(id: "codex", provider: .codex, name: "Codex", tokens: 100, cost: 1),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        let today = try #require(Self.point(on: Self.now, in: model))

        #expect(today.providers.map(\.displayName) == ["Codex"])
    }

    @Test
    func `a day priced without token buckets still carries its provider`() throws {
        let model = SpendDashboardModel.build(
            inputs: [Self.input(id: "codex", provider: .codex, name: "Codex", tokens: 0, cost: 3)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        let today = try #require(Self.point(on: Self.now, in: model))

        #expect(today.providers.map(\.tokens) == [0])
        #expect(today.providers.map(\.costUSD) == [3])
    }

    @Test
    func `the colour ramp ranks on the providers the tooltip lists`() throws {
        let day = Self.calendar.startOfDay(for: Self.now)
        let earlier = try #require(Self.calendar.date(byAdding: .day, value: -1, to: day))
        let series = SpendActivitySeries.make(
            from: [
                .init(day: earlier, totalTokens: 0, providers: []),
                .init(
                    day: day,
                    totalTokens: 100,
                    providers: [Self.activity(provider: .codex, name: "Codex", tokens: 100)]),
            ],
            now: Self.now,
            calendar: Self.calendar)
        let levels = SpendActivityLevels.dailyLevels(series.rankedDaily)
        let dayIndex = try #require(series.daily.indices.last { series.isVisible($0) })

        // A day only Codex worked must not draw like a day nobody worked.
        #expect(levels[dayIndex] == 4)
        #expect(levels[dayIndex - 1] == 0)
    }

    @Test
    func `points without a breakdown still rank on their day total`() throws {
        let day = Self.calendar.startOfDay(for: Self.now)
        let series = SpendActivitySeries.make(
            from: [.init(day: day, totalTokens: 250)],
            now: Self.now,
            calendar: Self.calendar)
        let dayIndex = try #require(series.daily.indices.last { series.isVisible($0) })

        #expect(series.rankedDaily[dayIndex] == 250)
    }

    @Test
    func `the narrowed grid keeps today in its last column`() {
        let day = Self.calendar.startOfDay(for: Self.now)
        let full = SpendActivitySeries.make(
            from: [.init(day: day, totalTokens: 10)],
            now: Self.now,
            calendar: Self.calendar)
        let narrowed = full.trailingWeeks(SpendActivityMenuCardView.weekCount)

        #expect(narrowed.columnCount == SpendActivityMenuCardView.weekCount)
        #expect(narrowed.today == full.today)
        #expect(narrowed.daily.reduce(0, +) == 10)
        #expect(narrowed.date(at: 0) == full.date(at: (53 - SpendActivityMenuCardView.weekCount) * 7))
        #expect(full.trailingWeeks(53).columnCount == 53)
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200) // 2026-07-16 00:00:00 UTC

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func point(
        on day: Date,
        in model: SpendDashboardModel) -> SpendDashboardModel.TokenActivityPoint?
    {
        model.tokenActivity.first { Self.calendar.isDate($0.day, inSameDayAs: day) }
    }

    private static func activity(
        provider: UsageProvider,
        name: String,
        tokens: Int) -> SpendDashboardModel.ProviderActivity
    {
        SpendDashboardModel.ProviderActivity(
            provider: provider,
            displayName: name,
            tokens: tokens,
            costUSD: 0)
    }

    private static func input(
        id: String,
        provider: UsageProvider,
        name: String,
        tokens: Int,
        cost: Double) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: name,
            modelProviderName: name,
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                currencyCode: "USD",
                historyDays: 365,
                daily: [CostUsageDailyReport.Entry(
                    date: "2026-07-16",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: tokens,
                    costUSD: cost,
                    modelsUsed: nil,
                    modelBreakdowns: nil)],
                updatedAt: self.now))
    }
}
