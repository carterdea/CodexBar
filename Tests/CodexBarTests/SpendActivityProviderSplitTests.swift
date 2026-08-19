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
    func `a day that only cost money does not draw as an empty day`() throws {
        let day = Self.calendar.startOfDay(for: Self.now)
        let earlier = try #require(Self.calendar.date(byAdding: .day, value: -1, to: day))
        // Codex priced the day but reported no token buckets for it, so its token count is 0.
        let series = SpendActivitySeries.make(
            from: [
                .init(day: earlier, totalTokens: 0, providers: []),
                .init(
                    day: day,
                    totalTokens: 0,
                    providers: [Self.activity(provider: .codex, name: "Codex", tokens: 0, cost: 3)]),
            ],
            now: Self.now,
            calendar: Self.calendar)
        let dayIndex = try #require(series.daily.indices.last { series.isVisible($0) })

        #expect(series.dailyLevels[dayIndex] == 1)
        #expect(series.dailyLevels[dayIndex - 1] == 0)
    }

    @Test
    func `flooring a priced day leaves the token ramp alone`() throws {
        let day = Self.calendar.startOfDay(for: Self.now)
        let quiet = try #require(Self.calendar.date(byAdding: .day, value: -1, to: day))
        let series = SpendActivitySeries.make(
            from: [
                .init(
                    day: quiet,
                    totalTokens: 100,
                    providers: [Self.activity(provider: .codex, name: "Codex", tokens: 100)]),
                .init(
                    day: day,
                    totalTokens: 1000,
                    providers: [Self.activity(provider: .claude, name: "Claude", tokens: 1000)]),
            ],
            now: Self.now,
            calendar: Self.calendar)
        let dayIndex = try #require(series.daily.indices.last { series.isVisible($0) })

        #expect(series.dailyLevels[dayIndex] == 4)
        #expect(series.dailyLevels[dayIndex - 1] == 1)
    }

    @Test
    func `two points on one day list their provider once`() throws {
        let day = Self.calendar.startOfDay(for: Self.now)
        let series = SpendActivitySeries.make(
            from: [
                .init(
                    day: day,
                    totalTokens: 40,
                    providers: [Self.activity(provider: .codex, name: "Codex", tokens: 40, cost: 1)]),
                .init(
                    day: day,
                    totalTokens: 60,
                    providers: [Self.activity(provider: .codex, name: "Codex", tokens: 60, cost: 2)]),
            ],
            now: Self.now,
            calendar: Self.calendar)
        let dayIndex = try #require(series.daily.indices.last { series.isVisible($0) })

        #expect(series.providers[dayIndex].map(\.tokens) == [100])
        #expect(series.providers[dayIndex].map(\.costUSD) == [3])
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
        tokens: Int,
        cost: Double = 0) -> SpendDashboardModel.ProviderActivity
    {
        SpendDashboardModel.ProviderActivity(
            provider: provider,
            displayName: name,
            tokens: tokens,
            costUSD: cost)
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
