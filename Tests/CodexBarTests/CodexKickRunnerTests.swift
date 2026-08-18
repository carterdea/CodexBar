import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexKickRunnerTests {
    private final class LaunchRecorder: @unchecked Sendable {
        private(set) var binary: String?
        private(set) var arguments: [String] = []
        private(set) var environment: [String: String] = [:]
        private(set) var launchCount = 0
        private let error: Error?

        init(error: Error? = nil) {
            self.error = error
        }

        var launch: CodexKickLaunch {
            { [self] binary, arguments, environment in
                self.launchCount += 1
                self.binary = binary
                self.arguments = arguments
                self.environment = environment
                if let error = self.error { throw error }
            }
        }
    }

    private struct StubError: LocalizedError {
        var errorDescription: String? {
            "codex exited with status 1"
        }
    }

    private func resolver(
        executable: String = "/usr/local/bin/codex",
        loginPATH: [String]? = nil) -> CodexExecutableResolver
    {
        { _, _ in CodexExecutableResolution(executable: executable, loginPATH: loginPATH) }
    }

    private var missingResolver: CodexExecutableResolver {
        { _, _ in nil }
    }

    // MARK: - Command shape

    @Test
    func `kick runs codex exec against the resolved binary`() async {
        let recorder = LaunchRecorder()
        let outcome = await CodexKickRunner.kick(
            codexHome: nil,
            environment: [:],
            resolveExecutable: self.resolver(),
            launch: recorder.launch)

        #expect(outcome == .started)
        #expect(recorder.binary == "/usr/local/bin/codex")
        #expect(recorder.arguments.first == "exec")
        #expect(recorder.arguments.last == "hi")
    }

    @Test
    func `kick cannot touch the users config repo or filesystem`() async {
        let recorder = LaunchRecorder()
        _ = await CodexKickRunner.kick(
            codexHome: nil,
            environment: [:],
            resolveExecutable: self.resolver(),
            launch: recorder.launch)

        #expect(recorder.arguments.contains("--ephemeral"))
        #expect(recorder.arguments.contains("--ignore-user-config"))
        #expect(recorder.arguments.contains("--skip-git-repo-check"))
        #expect(recorder.arguments.contains("--ignore-rules"))
        #expect(recorder.arguments.contains("--sandbox=read-only"))
        #expect(recorder.arguments.contains("--cd=/tmp"))
    }

    /// A Spark model bills to its own weekly_scoped bucket, so kicking with one would not open the
    /// session window the feature exists for.
    @Test
    func `kick never uses a spark model`() async {
        let recorder = LaunchRecorder()
        _ = await CodexKickRunner.kick(
            codexHome: nil,
            environment: [:],
            resolveExecutable: self.resolver(),
            launch: recorder.launch)

        let modelArgs = recorder.arguments.filter { $0.hasPrefix("--model=") }
        #expect(modelArgs == ["--model=\(CodexKickRunner.model)"])
        #expect(!CodexKickRunner.model.lowercased().contains("spark"))
    }

    /// The value is TOML and there is no shell in the path, so the quotes must survive verbatim.
    @Test
    func `reasoning effort is passed as a quoted toml value`() async {
        let recorder = LaunchRecorder()
        _ = await CodexKickRunner.kick(
            codexHome: nil,
            environment: [:],
            resolveExecutable: self.resolver(),
            launch: recorder.launch)

        #expect(recorder.arguments.contains("--config=model_reasoning_effort=\"minimal\""))
    }

    // MARK: - Account routing

    @Test
    func `a managed account home is passed through CODEX_HOME`() async {
        let recorder = LaunchRecorder()
        _ = await CodexKickRunner.kick(
            codexHome: "/Users/someone/Library/Application Support/CodexBar/managed-codex-homes/a",
            environment: ["EXISTING": "1"],
            resolveExecutable: self.resolver(),
            launch: recorder.launch)

        #expect(
            recorder.environment["CODEX_HOME"] ==
                "/Users/someone/Library/Application Support/CodexBar/managed-codex-homes/a")
        #expect(recorder.environment["EXISTING"] == "1")
    }

    @Test
    func `no managed home leaves CODEX_HOME alone so the ambient login is used`() async {
        let recorder = LaunchRecorder()
        _ = await CodexKickRunner.kick(
            codexHome: nil,
            environment: [:],
            resolveExecutable: self.resolver(),
            launch: recorder.launch)

        #expect(recorder.environment["CODEX_HOME"] == nil)
    }

    @Test
    func `a resolved login shell PATH is handed to the launcher`() async {
        let recorder = LaunchRecorder()
        _ = await CodexKickRunner.kick(
            codexHome: nil,
            environment: ["PATH": "/usr/bin"],
            resolveExecutable: self.resolver(loginPATH: ["/opt/homebrew/bin", "/usr/bin"]),
            launch: recorder.launch)

        #expect(recorder.environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
    }

    // MARK: - Failures

    @Test
    func `a missing codex CLI is reported as unsupported and launches nothing`() async {
        let recorder = LaunchRecorder()
        let outcome = await CodexKickRunner.kick(
            codexHome: nil,
            environment: [:],
            resolveExecutable: self.missingResolver,
            launch: recorder.launch)

        guard case let .unsupported(reason) = outcome else {
            Issue.record("expected .unsupported, got \(outcome)")
            return
        }
        #expect(reason.contains("codex"))
        #expect(recorder.launchCount == 0)
    }

    @Test
    func `a failing codex run reports the underlying error`() async {
        let recorder = LaunchRecorder(error: StubError())
        let outcome = await CodexKickRunner.kick(
            codexHome: nil,
            environment: [:],
            resolveExecutable: self.resolver(),
            launch: recorder.launch)

        #expect(outcome == .failed(message: "codex exited with status 1"))
        #expect(!outcome.warrantsRefresh)
    }
}
