import CodexBarCore
import Foundation

/// The dashboard's data shapes, split out so the model type itself stays within its size budget.
extension SpendDashboardModel {
    struct ProviderInput: Sendable {
        let id: String
        let provider: UsageProvider
        let displayName: String
        let modelProviderName: String
        let snapshot: CostUsageTokenSnapshot
        let tokenActivityCache: CostUsageTokenActivityCache?

        init(
            id: String? = nil,
            provider: UsageProvider,
            displayName: String,
            modelProviderName: String? = nil,
            snapshot: CostUsageTokenSnapshot,
            tokenActivityCache: CostUsageTokenActivityCache? = nil)
        {
            self.id = id ?? provider.rawValue
            self.provider = provider
            self.displayName = displayName
            self.modelProviderName = modelProviderName ?? displayName
            self.snapshot = snapshot
            self.tokenActivityCache = tokenActivityCache
        }
    }

    struct ProviderRow: Identifiable, Equatable, Sendable {
        let id: String
        let rank: Int
        let provider: UsageProvider
        let displayName: String
        let totalTokens: Int?
        let totalCost: Double?
        let coveredDayCount: Int
    }

    struct ModelRow: Identifiable, Equatable, Sendable {
        let rank: Int
        let provider: UsageProvider
        let providerName: String
        let modelName: String
        let totalTokens: Int?
        let totalCost: Double?

        var id: String {
            "\(self.provider.rawValue):\(self.modelName)"
        }
    }

    /// A project roll-up scoped to the requested window. Projects are keyed per source so
    /// the same repository used under two Codex accounts stays attributed to each subscription.
    struct ProjectRow: Identifiable, Equatable, Sendable {
        let rank: Int
        let provider: UsageProvider
        let providerName: String
        let sourceID: String
        let projectName: String
        let path: String?
        let totalTokens: Int?
        let totalCost: Double?

        var id: String {
            "\(self.sourceID):\(self.projectName)"
        }
    }

    struct DailyPoint: Identifiable, Equatable, Sendable {
        let sourceID: String
        let provider: UsageProvider
        let providerName: String
        let day: Date
        let cost: Double
        let stackStart: Double
        let stackEnd: Double

        var id: String {
            "\(self.sourceID):\(Int(self.day.timeIntervalSince1970))"
        }
    }

    /// One provider's share of a single day, merged across every account that provider owns.
    /// Tokens and cost are separate readings of the same day: an archive can price a day it has
    /// no token buckets for, which is why a zero token count with a cost is still worth a line.
    struct ProviderActivity: Equatable, Sendable {
        let provider: UsageProvider
        let displayName: String
        let tokens: Int
        let costUSD: Double

        /// Collapses repeated providers into one entry each and drops the ones with nothing to
        /// report, in the order a tooltip reads them. Both the day builder (merging a provider's
        /// accounts) and the grid (merging points that land on the same day) need this same rule,
        /// and a provider listed twice in one cell is what they are both avoiding.
        static func merged(_ activities: [Self]) -> [Self] {
            var merged: [UsageProvider: Self] = [:]
            for activity in activities {
                let existing = merged[activity.provider]
                let sum = (existing?.tokens ?? 0).addingReportingOverflow(activity.tokens)
                merged[activity.provider] = Self(
                    provider: activity.provider,
                    displayName: existing?.displayName ?? activity.displayName,
                    tokens: sum.overflow ? Int.max : sum.partialValue,
                    costUSD: (existing?.costUSD ?? 0) + activity.costUSD)
            }
            return merged.values
                .filter { $0.tokens > 0 || $0.costUSD > 0 }
                .sorted { $0.displayName < $1.displayName }
        }
    }

    struct TokenActivityPoint: Identifiable, Equatable, Sendable {
        let day: Date
        /// `nil` means at least one included source cannot establish coverage for this day.
        /// This must stay distinct from a proven zero so the heatmap does not fabricate inactivity.
        let totalTokens: Int?
        /// `false` means at least one source never scanned this day, so the gap is a window edge
        /// rather than missing data. A `nil` total with `true` means every source scanned the day
        /// and still cannot report it, which is a real gap the heatmap must keep visible.
        let isScanned: Bool
        /// Providers that did something on this day, sorted by display name so a cell keeps the
        /// same reading order every day. A provider with neither tokens nor cost carries no line
        /// and is not listed. Empty on days no source can report.
        let providers: [ProviderActivity]

        init(
            day: Date,
            totalTokens: Int?,
            isScanned: Bool = true,
            providers: [ProviderActivity] = [])
        {
            self.day = day
            self.totalTokens = totalTokens
            self.isScanned = isScanned
            self.providers = providers
        }

        var id: Date {
            self.day
        }
    }

    enum ModelHistoryCompleteness: Equatable, Sendable {
        case complete
        case incomplete
    }

    struct CurrencyGroup: Identifiable, Equatable, Sendable {
        let currencyCode: String
        let providers: [ProviderRow]
        let models: [ModelRow]
        let projects: [ProjectRow]
        let dailyPoints: [DailyPoint]
        let totalTokens: Int?
        let totalCost: Double?
        let coveredDayCount: Int
        let chartDomain: ClosedRange<Date>
        let modelHistoryCompleteness: ModelHistoryCompleteness

        var id: String {
            self.currencyCode
        }
    }
}
