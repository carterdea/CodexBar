import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendActivityTooltipContentTests {
    @Test
    func `token cell renders a count, a placeholder for priced days, or nothing at all`() {
        #expect(SpendActivityTooltipFormatting.tokenCell(tokens: 1_237_113_490, costUSD: 0) == "1.2B tok")
        #expect(SpendActivityTooltipFormatting.tokenCell(tokens: 812, costUSD: 4) == "812 tok")
        // Priced but uncounted: dropping the line would take the dollar figure with it.
        #expect(SpendActivityTooltipFormatting.tokenCell(tokens: 0, costUSD: 0.01) == "--")
        // Neither tokens nor money means the provider gets no line.
        #expect(SpendActivityTooltipFormatting.tokenCell(tokens: 0, costUSD: 0) == nil)
    }

    @Test
    func `money cell is empty at zero rather than a free-looking zero dollars`() {
        #expect(SpendActivityTooltipFormatting.moneyCell(costUSD: 0).isEmpty)
        #expect(SpendActivityTooltipFormatting.moneyCell(costUSD: 18.16) == "$18.16")
        #expect(SpendActivityTooltipFormatting.moneyCell(costUSD: 31785.01) == "$31,785.01")
    }

    @Test
    func `a provider line drops the money clause when the price is unknown`() {
        #expect(SpendActivityTooltipFormatting.providerLine(
            name: "Claude",
            tokens: 1_237_113_490,
            costUSD: 18.16) == "Claude 1.2B tok $18.16")
        #expect(SpendActivityTooltipFormatting.providerLine(
            name: "Claude",
            tokens: 2_500_000,
            costUSD: 0) == "Claude 2.5M tok")
        #expect(SpendActivityTooltipFormatting.providerLine(
            name: "Codex",
            tokens: 0,
            costUSD: 2.5) == "Codex -- $2.50")
        #expect(SpendActivityTooltipFormatting.providerLine(name: "Codex", tokens: 0, costUSD: 0) == nil)
    }

    @Test
    func `a covered day carries one line per provider that did something`() throws {
        let content = try SpendActivityTooltipFormatting.content(
            date: Self.date(year: 2026, month: 6, day: 3),
            providers: [
                Self.activity(provider: .claude, name: "Claude", tokens: 1_237_113_490, costUSD: 18.16),
                Self.activity(provider: .codex, name: "Codex", tokens: 2_500_000, costUSD: 0),
            ],
            isCovered: true,
            locale: Self.english)

        #expect(content.dayLine == "Wed, Jun 3")
        #expect(content.providerLines == ["Claude 1.2B tok $18.16", "Codex 2.5M tok"])
    }

    @Test
    func `a provider with neither tokens nor money is omitted entirely`() throws {
        let content = try SpendActivityTooltipFormatting.content(
            date: Self.date(year: 2026, month: 6, day: 3),
            providers: [
                Self.activity(provider: .claude, name: "Claude", tokens: 0, costUSD: 0),
                Self.activity(provider: .codex, name: "Codex", tokens: 2_500_000, costUSD: 1.5),
            ],
            isCovered: true,
            locale: Self.english)

        #expect(content.providerLines == ["Codex 2.5M tok $1.50"])
    }

    @Test
    func `a quiet day and an unreadable day say different things`() throws {
        let date = try Self.date(year: 2026, month: 6, day: 3)
        let quiet = SpendActivityTooltipFormatting.content(
            date: date,
            providers: [],
            isCovered: true,
            locale: Self.english)
        let unavailable = SpendActivityTooltipFormatting.content(
            date: date,
            providers: [Self.activity(provider: .claude, name: "Claude", tokens: 2_500_000, costUSD: 1)],
            isCovered: false,
            locale: Self.english)

        #expect(quiet.dayLine == "Wed, Jun 3 · no usage")
        #expect(quiet.providerLines.isEmpty)
        #expect(unavailable.dayLine == "Wed, Jun 3 · Unavailable")
        #expect(unavailable.providerLines.isEmpty)
    }

    @Test
    func `the accessible label reports the same providers the tooltip draws`() throws {
        let content = try SpendActivityTooltipFormatting.content(
            date: Self.date(year: 2026, month: 6, day: 3),
            providers: [
                Self.activity(provider: .claude, name: "Claude", tokens: 1_237_113_490, costUSD: 18.16),
                Self.activity(provider: .codex, name: "Codex", tokens: 2_500_000, costUSD: 0),
            ],
            isCovered: true,
            locale: Self.english)

        #expect(content.accessibilityLine == "Wed, Jun 3 · Claude 1.2B tok $18.16 · Codex 2.5M tok")
    }

    @Test
    func `tooltip height grows one line at a time`() {
        let quiet = SpendActivityGridGeometry.tooltipHeight(detailLineCount: 0)
        let single = SpendActivityGridGeometry.tooltipHeight(detailLineCount: 1)
        let double = SpendActivityGridGeometry.tooltipHeight(detailLineCount: 2)

        #expect(single - quiet == SpendActivityGridGeometry.tooltipDetailLineHeight)
        #expect(double - single == SpendActivityGridGeometry.tooltipDetailLineHeight)
    }

    private static let english = Locale(identifier: "en_US")

    private static func date(year: Int, month: Int, day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return try #require(calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }

    private static func activity(
        provider: UsageProvider,
        name: String,
        tokens: Int,
        costUSD: Double) -> SpendDashboardModel.ProviderActivity
    {
        SpendDashboardModel.ProviderActivity(
            provider: provider,
            displayName: name,
            tokens: tokens,
            costUSD: costUSD)
    }
}
