import CodexBarCore
import Foundation

/// What one heatmap cell says when you point at it: a date line, then one line per provider that
/// did something that day. Pure formatting — no view state — so the rules below can be pinned by
/// tests instead of by looking at a tooltip.
struct SpendActivityTooltipContent: Equatable {
    let dayLine: String
    let providerLines: [String]

    /// The same reading collapsed onto one line, for VoiceOver. The label and the tooltip are
    /// built from the same lines so they can never disagree about which providers are reported.
    var accessibilityLine: String {
        ([self.dayLine] + self.providerLines).joined(separator: " · ")
    }
}

enum SpendActivityTooltipFormatting {
    /// A provider's token cell. `nil` means the provider gets no line at all: it neither spent
    /// tokens nor money. `--` means it spent money the payload counted no tokens for, which is a
    /// row written before that provider's token buckets existed — dropping the line would lose
    /// the dollar figure that goes with it.
    static func tokenCell(tokens: Int, costUSD: Double) -> String? {
        if tokens > 0 {
            return "\(UsageFormatter.tokenCountString(tokens)) \(L("tok"))"
        }
        return costUSD > 0 ? "--" : nil
    }

    /// A provider's money cell, EMPTY at zero. A day with tokens and no price came from an
    /// archive written before that provider was priced; `$0.00` there reads as "this was free"
    /// rather than "not known".
    static func moneyCell(costUSD: Double) -> String {
        costUSD > 0 ? UsageFormatter.usdString(costUSD) : ""
    }

    /// One provider's line: name, tokens, and money when the money is known. `nil` when the
    /// token cell is empty, which is the gate the whole line is omitted on.
    static func providerLine(name: String, tokens: Int, costUSD: Double) -> String? {
        guard let tokenCell = self.tokenCell(tokens: tokens, costUSD: costUSD) else { return nil }
        return [name, tokenCell, self.moneyCell(costUSD: costUSD)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func content(
        date: Date,
        providers: [SpendDashboardModel.ProviderActivity],
        isCovered: Bool,
        locale: Locale? = nil) -> SpendActivityTooltipContent
    {
        let day = SpendActivityDateFormatting.weekdayDateString(date, locale: locale)
        guard isCovered else {
            return SpendActivityTooltipContent(
                dayLine: "\(day) · \(L("Unavailable"))",
                providerLines: [])
        }
        let lines = providers.compactMap {
            self.providerLine(name: $0.displayName, tokens: $0.tokens, costUSD: $0.costUSD)
        }
        guard !lines.isEmpty else {
            return SpendActivityTooltipContent(
                dayLine: "\(day) · \(L("no usage"))",
                providerLines: [])
        }
        return SpendActivityTooltipContent(dayLine: day, providerLines: lines)
    }

    /// The weekly and cumulative grids report one aggregate value rather than a provider split,
    /// so they reuse the same shape with a single detail line.
    static func aggregateContent(
        weekStart: Date,
        value: String,
        locale: Locale? = nil) -> SpendActivityTooltipContent
    {
        SpendActivityTooltipContent(
            dayLine: SpendActivityDateFormatting.mediumDateString(weekStart, locale: locale),
            providerLines: [value])
    }
}
