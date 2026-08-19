import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// "Code written" is sourced from Claude edit records. Codex rollouts have none, so the figure has
/// to stay Claude-scoped rather than reading as a total across both providers.
struct SpendDashboardCodeWrittenTests {
    @Test
    func `code written sums Claude edit counts inside the window`() {
        let input = SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(entries: [
                Self.entry(
                    day: "2026-07-16",
                    edits: CostUsageEditCounts(linesAdded: 400, linesRemoved: 90, filesCreated: 3)),
                Self.entry(
                    day: "2026-07-15",
                    edits: CostUsageEditCounts(linesAdded: 12, linesRemoved: 8, filesCreated: 1)),
                Self.entry(
                    day: "2026-06-01",
                    edits: CostUsageEditCounts(linesAdded: 999, linesRemoved: 999, filesCreated: 9)),
            ]))

        let model = SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar)

        #expect(model.codeWritten == CostUsageEditCounts(linesAdded: 412, linesRemoved: 98, filesCreated: 4))
    }

    @Test
    func `code written ignores non-Claude sources`() {
        let codex = SpendDashboardModel.ProviderInput(
            provider: .codex,
            displayName: "Codex",
            snapshot: Self.snapshot(entries: [
                Self.entry(
                    day: "2026-07-16",
                    edits: CostUsageEditCounts(linesAdded: 500, linesRemoved: 100, filesCreated: 5)),
            ]))

        let model = SpendDashboardModel.build(
            inputs: [codex],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar)

        #expect(model.codeWritten == nil)
    }

    @Test
    func `code written stays nil when no source reports edits`() {
        let input = SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(entries: [Self.entry(day: "2026-07-16")]))

        let model = SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar)

        #expect(model.codeWritten == nil)
    }

    @Test
    func `lines changed text carries the sign of each side`() {
        #expect(spendDashboardLinesChangedText(added: 412_300, removed: 98100) == "+412.3K / -98.1K")
        #expect(spendDashboardLinesChangedText(added: 1234, removed: 0) == "+1.2K / -0")
        // A whole number keeps no trailing ".0", and sub-thousand counts stay exact.
        #expect(spendDashboardLinesChangedText(added: 2_000_000, removed: 950) == "+2M / -950")
    }

    private static func snapshot(entries: [CostUsageDailyReport.Entry]) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: "USD",
            historyDays: 30,
            daily: entries,
            projects: [],
            updatedAt: self.now)
    }

    private static func entry(day: String, edits: CostUsageEditCounts? = nil) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 10,
            costUSD: 1,
            modelsUsed: nil,
            modelBreakdowns: nil,
            edits: edits)
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200) // 2026-07-16 00:00:00 UTC
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
