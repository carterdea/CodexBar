import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeKickRunnerTests {
    /// Records every request it is handed, then answers from a caller-supplied script of status
    /// codes. One entry per attempt, so a script shorter than the model list proves the runner
    /// stopped early.
    private final class RecordingTransport: @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        private var statuses: [Int]

        init(statuses: [Int]) {
            self.statuses = statuses
        }

        var transport: ProviderHTTPTransportHandler {
            ProviderHTTPTransportHandler { [self] request in
                self.requests.append(request)
                let status = self.statuses.isEmpty ? 500 : self.statuses.removeFirst()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data("{}".utf8), response)
            }
        }
    }

    private func decodedBody(_ request: URLRequest) -> [String: Any] {
        let body = request.httpBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    // MARK: - Request shape

    @Test
    func `kick posts to the anthropic messages endpoint`() async throws {
        let recorder = RecordingTransport(statuses: [200])
        _ = await ClaudeKickRunner.kick(accessToken: "token", transport: recorder.transport)

        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
    }

    @Test
    func `kick identifies as claude code so oauth inference accepts it`() async throws {
        let recorder = RecordingTransport(statuses: [200])
        _ = await ClaudeKickRunner.kick(accessToken: "token", transport: recorder.transport)

        let request = try #require(recorder.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.219 (external, cli)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func `kick sends the smallest possible message with the claude code system prompt`() async throws {
        let recorder = RecordingTransport(statuses: [200])
        _ = await ClaudeKickRunner.kick(accessToken: "token", transport: recorder.transport)

        let request = try #require(recorder.requests.first)
        let body = self.decodedBody(request)
        #expect(body["model"] as? String == ClaudeKickRunner.models.first)
        #expect(body["max_tokens"] as? Int == 1)
        #expect(body["system"] as? String == "You are Claude Code, Anthropic's official CLI for Claude.")

        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "hi")
    }

    // MARK: - Outcome mapping

    @Test
    func `a successful response starts the window`() async {
        let recorder = RecordingTransport(statuses: [200])
        let outcome = await ClaudeKickRunner.kick(accessToken: "token", transport: recorder.transport)

        #expect(outcome == .started)
        #expect(outcome.warrantsRefresh)
    }

    @Test
    func `an unauthorized response reports missing credentials and stops`() async {
        let recorder = RecordingTransport(statuses: [401, 200, 200])
        let outcome = await ClaudeKickRunner.kick(accessToken: "token", transport: recorder.transport)

        #expect(outcome == .noCredentials)
        // 401 is about the account, not the model, so trying the rest would only burn requests.
        #expect(recorder.requests.count == 1)
    }

    @Test
    func `a forbidden response reports an unsupported account and stops`() async {
        let recorder = RecordingTransport(statuses: [403, 200, 200])
        let outcome = await ClaudeKickRunner.kick(accessToken: "token", transport: recorder.transport)

        guard case .unsupported = outcome else {
            Issue.record("expected .unsupported, got \(outcome)")
            return
        }
        #expect(recorder.requests.count == 1)
    }

    @Test
    func `a rate limited response stops rather than hammering the next model`() async {
        let recorder = RecordingTransport(statuses: [429, 200, 200])
        let outcome = await ClaudeKickRunner.kick(accessToken: "token", transport: recorder.transport)

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(recorder.requests.count == 1)
        #expect(!outcome.warrantsRefresh)
    }

    // MARK: - Model fallback

    @Test
    func `an unavailable model falls through to the next one in order`() async {
        let recorder = RecordingTransport(statuses: [404, 200])
        let outcome = await ClaudeKickRunner.kick(accessToken: "token", transport: recorder.transport)

        #expect(outcome == .started)
        #expect(recorder.requests.count == 2)

        let models = recorder.requests.map { self.decodedBody($0)["model"] as? String }
        #expect(models == [ClaudeKickRunner.models[0], ClaudeKickRunner.models[1]])
    }

    @Test
    func `exhausting every model reports failure`() async {
        let recorder = RecordingTransport(statuses: [500, 500, 500])
        let outcome = await ClaudeKickRunner.kick(accessToken: "token", transport: recorder.transport)

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(recorder.requests.count == ClaudeKickRunner.models.count)
    }

    // MARK: - Guards

    @Test
    func `an empty token sends nothing at all`() async {
        let recorder = RecordingTransport(statuses: [200])
        let outcome = await ClaudeKickRunner.kick(accessToken: "   ", transport: recorder.transport)

        #expect(outcome == .noCredentials)
        #expect(recorder.requests.isEmpty)
    }

    @Test
    func `only a started kick warrants a usage refresh`() {
        #expect(KickOutcome.started.warrantsRefresh)
        #expect(!KickOutcome.alreadyRunning.warrantsRefresh)
        #expect(!KickOutcome.noCredentials.warrantsRefresh)
        #expect(!KickOutcome.unsupported(reason: "nope").warrantsRefresh)
        #expect(!KickOutcome.failed(message: "nope").warrantsRefresh)
    }
}
