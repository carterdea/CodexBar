import CodexBarCore
import Foundation

/// How the heatmap's 365 days are built: one point per local day, each carrying the day total and
/// the per-provider split behind it. Kept apart from the window roll-ups in `SpendDashboardModel`
/// because it answers a different question — what happened on a day, not what a period cost.
extension SpendDashboardModel {
    private struct TokenActivityInputSummary {
        let provider: UsageProvider
        let providerName: String
        let coveredInterval: ClosedRange<Date>?
        let totalsByDay: [Date: Int]
        let costsByDay: [Date: Double]
        let invalidDays: Set<Date>
        let hasCompleteHistory: Bool
        let isGloballyInvalid: Bool

        /// Whether the scan window reached this day at all. A day outside the window is unknown
        /// because nobody looked; a day inside it is unknown because the data itself is missing.
        func scanned(_ day: Date) -> Bool {
            self.coveredInterval?.contains(day) == true
        }

        func tokens(on day: Date) -> Int? {
            guard self.scanned(day),
                  !self.isGloballyInvalid,
                  !self.invalidDays.contains(day)
            else { return nil }
            if let tokens = self.totalsByDay[day] {
                return tokens
            }
            return self.hasCompleteHistory ? 0 : nil
        }

        /// Priced spend for the day in USD. Zero covers both "nothing happened" and "nothing was
        /// priced"; the tooltip renders both as an empty money cell rather than as `$0.00`.
        func costUSD(on day: Date) -> Double {
            self.costsByDay[day] ?? 0
        }
    }

    /// The heatmap's series: one point per local day in the window, newest last.
    static func tokenActivityPoints(
        inputs: [ProviderInput],
        now: Date,
        calendar: Calendar) -> [TokenActivityPoint]
    {
        guard !inputs.isEmpty else { return [] }
        let bounds = Self.bounds(days: Self.tokenActivityDayCount, now: now, calendar: calendar)
        let summaries = inputs.map {
            Self.tokenActivityInputSummary(input: $0, bounds: bounds, calendar: calendar)
        }
        return (0..<Self.tokenActivityDayCount).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: bounds.lowerBound) else {
                return nil
            }
            var total = 0
            for summary in summaries {
                guard let tokens = summary.tokens(on: day) else {
                    // Every source must have scanned the day before an unknown counts as a real
                    // gap. If any source never reached it, this is the edge of a scan window.
                    return TokenActivityPoint(
                        day: day,
                        totalTokens: nil,
                        isScanned: summaries.allSatisfy { $0.scanned(day) })
                }
                let addition = total.addingReportingOverflow(tokens)
                total = addition.overflow ? Int.max : addition.partialValue
            }
            return TokenActivityPoint(
                day: day,
                totalTokens: total,
                providers: Self.providerActivity(on: day, summaries: summaries))
        }
    }

    /// One reading per source for the day, merged down to one line's worth of numbers each.
    private static func providerActivity(
        on day: Date,
        summaries: [TokenActivityInputSummary]) -> [ProviderActivity]
    {
        ProviderActivity.merged(summaries.map {
            ProviderActivity(
                provider: $0.provider,
                displayName: $0.providerName,
                tokens: $0.tokens(on: day) ?? 0,
                costUSD: $0.costUSD(on: day))
        })
    }

    private static func tokenActivityInputSummary(
        input: ProviderInput,
        bounds: ClosedRange<Date>,
        calendar: Calendar) -> TokenActivityInputSummary
    {
        let coveredInterval = Self.tokenActivityCoverageInterval(
            input: input,
            bounds: bounds,
            displayCalendar: calendar)
        var totalsByDay: [Date: Int] = [:]
        var costsByDay: [Date: Double] = [:]
        var invalidDays: Set<Date> = []
        var hasUnplacedTokens = false
        for entry in input.tokenActivityCache?.daily ?? input.snapshot.daily {
            guard let day = Self.day(entry.date, provider: input.provider, displayCalendar: calendar) else {
                hasUnplacedTokens = hasUnplacedTokens || !Self.hasProvenZeroTokens(entry)
                continue
            }
            guard coveredInterval?.contains(day) == true else { continue }
            if let cost = entry.costUSD, cost.isFinite, cost > 0 {
                costsByDay[day, default: 0] += cost
            }
            guard let tokens = Self.nonnegative(entry.totalTokens) else {
                invalidDays.insert(day)
                continue
            }
            guard !invalidDays.contains(day) else { continue }
            let addition = (totalsByDay[day] ?? 0).addingReportingOverflow(tokens)
            if addition.overflow {
                totalsByDay.removeValue(forKey: day)
                invalidDays.insert(day)
            } else {
                totalsByDay[day] = addition.partialValue
            }
        }

        let hasCompleteHistory = input.tokenActivityCache != nil
            || Self.hasCompleteTokenHistory(input, displayCalendar: calendar)
        let aggregateIsInconsistent = input.tokenActivityCache == nil
            && input.snapshot.last30DaysTokens != nil
            && !hasCompleteHistory
        return TokenActivityInputSummary(
            provider: input.provider,
            providerName: input.modelProviderName,
            coveredInterval: coveredInterval,
            totalsByDay: totalsByDay,
            costsByDay: costsByDay,
            invalidDays: invalidDays,
            hasCompleteHistory: hasCompleteHistory,
            isGloballyInvalid: hasUnplacedTokens || aggregateIsInconsistent)
    }

    private static func tokenActivityCoverageInterval(
        input: ProviderInput,
        bounds: ClosedRange<Date>,
        displayCalendar: Calendar) -> ClosedRange<Date>?
    {
        guard let cache = input.tokenActivityCache else {
            return self.coverageInterval(input: input, bounds: bounds, displayCalendar: displayCalendar)
        }
        guard let start = Self.day(
            cache.coverageSinceKey,
            provider: input.provider,
            displayCalendar: displayCalendar),
            let end = Self.day(
                cache.coverageUntilKey,
                provider: input.provider,
                displayCalendar: displayCalendar)
        else { return nil }
        let overlapStart = max(bounds.lowerBound, start)
        let overlapEnd = min(bounds.upperBound, end)
        return overlapStart <= overlapEnd ? overlapStart...overlapEnd : nil
    }
}
