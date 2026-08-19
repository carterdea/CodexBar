import Foundation
import Testing
@testable import CodexBarCore

/// Claude edit records (`toolUseResult`) are the only source of "code written" in either provider's
/// logs; Codex rollouts carry none. These cover the three shapes the parser has to get right.
struct CostUsageScannerClaudeEditsTests {
    @Test
    func `parseClaudeFile counts structuredPatch additions and removals`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 4)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/edits-patch.jsonl",
            contents: env.jsonl([
                Self.editRecord(
                    uuid: "edit-1",
                    timestamp: env.isoString(for: day),
                    patchLines: [["+added one", "-removed one", " context", "+added two"]]),
                Self.editRecord(
                    uuid: "edit-2",
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    patchLines: [["-gone"], ["+back", "+again"]]),
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.edits.count == 2)
        #expect(parsed.edits.map(\.added) == [2, 2])
        #expect(parsed.edits.map(\.removed) == [1, 1])
        #expect(parsed.edits.allSatisfy { $0.created == 0 })
    }

    @Test
    func `parseClaudeFile counts a repeated uuid once`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 4)
        let record = Self.editRecord(
            uuid: "edit-repeat",
            timestamp: env.isoString(for: day),
            patchLines: [["+one", "+two", "-three"]])
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/edits-dedupe.jsonl",
            contents: env.jsonl([record, record, record]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.edits.count == 1)
        #expect(parsed.edits[0].added == 2)
        #expect(parsed.edits[0].removed == 1)
    }

    @Test
    func `parseClaudeFile falls back to content line count for a created file`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 4)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/edits-create.jsonl",
            contents: env.jsonl([
                [
                    "type": "user",
                    "uuid": "edit-create",
                    "timestamp": env.isoString(for: day),
                    "toolUseResult": [
                        "type": "create",
                        "filePath": "/tmp/new.swift",
                        "content": "line one\nline two\nline three\n",
                        "structuredPatch": [],
                    ],
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.edits.count == 1)
        #expect(parsed.edits[0].added == 3)
        #expect(parsed.edits[0].removed == 0)
        #expect(parsed.edits[0].created == 1)
    }

    /// A create that already carries a patch keeps the patch's numbers; only the empty case falls
    /// back to splitting `content`.
    @Test
    func `parseClaudeFile prefers a create record's patch over its content`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 4)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/edits-create-patch.jsonl",
            contents: env.jsonl([
                [
                    "type": "user",
                    "uuid": "edit-create-patch",
                    "timestamp": env.isoString(for: day),
                    "toolUseResult": [
                        "type": "create",
                        "content": "a\nb\nc\nd\ne\nf\ng",
                        "structuredPatch": [["lines": ["+a", "+b"]]],
                    ],
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.edits.count == 1)
        #expect(parsed.edits[0].added == 2)
        #expect(parsed.edits[0].created == 1)
    }

    @Test
    func `loadDailyReport reports Claude lines written per day and in the summary`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 4)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/report-edits.jsonl",
            contents: env.jsonl([
                Self.assistantRecord(timestamp: env.isoString(for: day)),
                Self.editRecord(
                    uuid: "report-edit-1",
                    timestamp: env.isoString(for: day),
                    patchLines: [["+one", "+two", "-three"]]),
                [
                    "type": "user",
                    "uuid": "report-edit-2",
                    "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                    "toolUseResult": [
                        "type": "create",
                        "content": "alpha\nbeta",
                        "structuredPatch": [],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        let entry = try #require(report.data.first)
        #expect(entry.edits == CostUsageEditCounts(linesAdded: 4, linesRemoved: 1, filesCreated: 1))
    }

    /// Forking or resuming a session copies the transcript, so the same edit uuid lands in two
    /// files. Reconciliation across files must not double the line count.
    @Test
    func `loadDailyReport counts a forked transcript's shared edits once`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 4)
        let shared = try env.jsonl([
            Self.assistantRecord(timestamp: env.isoString(for: day)),
            Self.editRecord(
                uuid: "shared-edit",
                timestamp: env.isoString(for: day),
                patchLines: [["+one", "+two", "-three"]]),
        ])
        _ = try env.writeClaudeProjectFile(relativePath: "project-a/original.jsonl", contents: shared)
        _ = try env.writeClaudeProjectFile(relativePath: "project-a/forked.jsonl", contents: shared)

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        let entry = try #require(report.data.first)
        #expect(entry.edits == CostUsageEditCounts(linesAdded: 2, linesRemoved: 1, filesCreated: 0))
    }

    /// The Claude fetcher always merges its report with a Pi sessions report, even an empty one.
    /// `merged(_:)` therefore has to carry edit counts through, or the scanner's work is discarded
    /// before the dashboard ever sees it and the panel cannot appear.
    @Test
    func `merged reports keep Claude edit counts`() {
        let claude = CostUsageDailyReport(
            data: [CostUsageDailyReport.Entry(
                date: "2026-03-04",
                inputTokens: 10,
                outputTokens: 5,
                totalTokens: 15,
                costUSD: 1,
                modelsUsed: ["claude-sonnet-4-20250514"],
                modelBreakdowns: nil,
                edits: CostUsageEditCounts(linesAdded: 400, linesRemoved: 90, filesCreated: 3))],
            summary: nil)
        let empty = CostUsageDailyReport(data: [], summary: nil)

        let merged = claude.merged(with: empty)

        let entry = merged.data.first
        #expect(entry?.totalTokens == 15)
        #expect(entry?.edits == CostUsageEditCounts(linesAdded: 400, linesRemoved: 90, filesCreated: 3))
    }

    /// Provider siloing lives at the display layer, not in `merged(_:)`: the dashboard only sums
    /// Claude inputs, so a report blending providers can never present Claude's count as the total.
    @Test
    func `merged reports sum edit counts across inputs`() {
        let first = CostUsageDailyReport(
            data: [CostUsageDailyReport.Entry(
                date: "2026-03-04",
                inputTokens: 10,
                outputTokens: 5,
                totalTokens: 15,
                costUSD: 1,
                modelsUsed: nil,
                modelBreakdowns: nil,
                edits: CostUsageEditCounts(linesAdded: 4, linesRemoved: 1, filesCreated: 1))],
            summary: nil)
        let second = CostUsageDailyReport(
            data: [CostUsageDailyReport.Entry(
                date: "2026-03-04",
                inputTokens: 20,
                outputTokens: 6,
                totalTokens: 26,
                costUSD: 2,
                modelsUsed: nil,
                modelBreakdowns: nil,
                edits: CostUsageEditCounts(linesAdded: 6, linesRemoved: 2, filesCreated: 0))],
            summary: nil)

        let merged = first.merged(with: second)

        #expect(merged.data.first?.edits == CostUsageEditCounts(linesAdded: 10, linesRemoved: 3, filesCreated: 1))
    }

    private static func editRecord(
        uuid: String,
        timestamp: String,
        patchLines: [[String]]) -> [String: Any]
    {
        [
            "type": "user",
            "uuid": uuid,
            "timestamp": timestamp,
            "toolUseResult": [
                "filePath": "/tmp/edited.swift",
                "structuredPatch": patchLines.map { ["lines": $0] },
            ],
        ]
    }

    private static func assistantRecord(timestamp: String) -> [String: Any] {
        [
            "type": "assistant",
            "timestamp": timestamp,
            "requestId": "req_edits",
            "isSidechain": false,
            "message": [
                "id": "msg_edits",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 20,
                ],
            ],
        ]
    }
}
