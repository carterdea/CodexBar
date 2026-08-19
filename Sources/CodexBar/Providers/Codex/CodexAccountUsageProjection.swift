import CodexBarCore
import Foundation

/// Flattens Codex's visible accounts and their per-account usage into the provider-neutral shape the
/// account cards, the compact layout planner, and headroom ranking all read.
///
/// Callers that already hold a menu display should go through `CodexAccountMenuDisplay.projectedAccounts`.
enum CodexAccountUsageProjection {
    /// `activeVisibleAccountID` is only needed by callers whose accounts do not already carry the
    /// projection's `isActive` -- rows written by a menu refresh do, and must not re-read the
    /// visible-account projection just to learn it.
    static func project(
        accounts: [CodexVisibleAccount],
        snapshots: [CodexAccountUsageSnapshot],
        activeVisibleAccountID: String? = nil) -> [ProviderAccountUsageSnapshot]
    {
        let snapshotsByAccountID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.account.id, $0) })
        return accounts.map { account in
            let accountSnapshot = snapshotsByAccountID[account.id]
            let health = CodexAccountHealth.status(for: account, error: accountSnapshot?.error)
            let isActive = account.id == activeVisibleAccountID || account.isActive
            return ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: "codex-account", opaqueID: account.id),
                provider: .codex,
                displayLabel: account.menuDisplayName,
                isActive: isActive,
                canActivate: !isActive,
                snapshot: accountSnapshot?.snapshot,
                error: health.label,
                sourceLabel: accountSnapshot?.sourceLabel)
        }
    }
}
