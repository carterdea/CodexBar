import Foundation

/// Launches the `codex` CLI. Injectable so tests can assert the command without spawning anything.
public typealias CodexKickLaunch = @Sendable (
    _ binary: String,
    _ arguments: [String],
    _ environment: [String: String]) async throws -> Void

/// Starts a Codex session window by running one throwaway `codex exec`.
///
/// Unlike Claude, this cannot be an HTTP call. The ChatGPT backend starts the window off actual
/// Codex usage, and the CLI is what produces usage the backend counts — so the kick has to be the
/// CLI, which is also why `codexHome` matters: `codex exec` takes its login from `$CODEX_HOME` and
/// offers no flag to select an account.
public enum CodexKickRunner {
    /// A cheap general model. Deliberately **not** a Spark model: Spark bills to its own
    /// `weekly_scoped` bucket, so it would not open the window the kick exists for.
    public static let model = "gpt-5.6-sol"

    /// The prompt is one word because the response is irrelevant — only that a turn happened.
    public static let prompt = "hi"

    /// `--ephemeral` and `--ignore-user-config` keep the kick out of the user's session history and
    /// away from their config; `--sandbox=read-only` with `--cd=/tmp` means it cannot touch a repo.
    ///
    /// The `--name=value` spellings are the ones proven in practice. They originally worked around
    /// an argv cap that no longer applies here, but the flag parsing is what is known-good, so they
    /// are kept rather than re-derived. `model_reasoning_effort="minimal"` keeps its quotes: the
    /// value is TOML, and it is passed as one argv element with no shell to strip them.
    public static func arguments(model: String = CodexKickRunner.model) -> [String] {
        [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--skip-git-repo-check",
            "--ignore-rules",
            "--sandbox=read-only",
            "--cd=/tmp",
            "--model=\(model)",
            "--config=model_reasoning_effort=\"minimal\"",
            "--json",
            self.prompt,
        ]
    }

    /// Runs the kick against one Codex login.
    ///
    /// - Parameter codexHome: the account's `CODEX_HOME`. `nil` means the ambient login.
    public static func kick(codexHome: String?) async -> KickOutcome {
        await self.kick(
            codexHome: codexHome,
            environment: ProcessInfo.processInfo.environment,
            resolveExecutable: defaultCodexExecutableResolver,
            launch: self.defaultLaunch)
    }

    /// Seam for tests. Stays internal because `CodexExecutableResolver` is; widening upstream's
    /// access level for a fork's convenience would be a needless merge conflict.
    static func kick(
        codexHome: String?,
        environment: [String: String],
        resolveExecutable: CodexExecutableResolver,
        launch: CodexKickLaunch) async -> KickOutcome
    {
        // Provider-specific by design: this whole runner is the Codex kick, and "codex" here is the
        // executable name to look for on PATH, not a provider selector that could be derived.
        guard let resolution = resolveExecutable(environment, "codex") else {
            return .unsupported(reason: "The codex CLI was not found. Install it, or set CODEX_CLI_PATH.")
        }

        var base = environment
        // A resolved login-shell PATH is what makes `#!/usr/bin/env node` style launchers work.
        if let loginPATH = resolution.loginPATH, !loginPATH.isEmpty {
            base["PATH"] = loginPATH.joined(separator: ":")
        }
        let scoped = CodexHomeScope.scopedEnvironment(base: base, codexHome: codexHome)

        do {
            try await launch(resolution.executable, self.arguments(), scoped)
            return .started
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// The real launcher. Runs to natural exit: a kick that is killed partway may still have
    /// spent a turn, so interrupting it buys nothing and loses the outcome.
    public static let defaultLaunch: CodexKickLaunch = { binary, arguments, environment in
        _ = try await SubprocessRunner.runToCompletion(
            binary: binary,
            arguments: arguments,
            environment: environment,
            acceptsNonZeroExit: false,
            label: "codex-kick")
    }
}
