import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Starts a Claude 5-hour session window by sending one minimal message.
///
/// Claude's session window does not begin on a schedule; it begins with the first request. Waiting
/// until you actually need the account means the window ends five hours after you started working,
/// not five hours after you wanted to. A kick moves that boundary to a moment you chose.
///
/// This talks to the same host and uses the same OAuth access token as
/// ``ClaudeOAuthUsageFetcher``, so an account whose usage CodexBar can read is an account it can
/// kick — with the exception of ClaudeSwap accounts, whose credentials belong to the `cswap`
/// subprocess and are never read here.
public enum ClaudeKickRunner {
    private static let baseURL = "https://api.anthropic.com"
    private static let messagesPath = "/v1/messages"
    private static let betaHeader = "oauth-2025-04-20"
    private static let apiVersion = "2023-06-01"

    /// Anthropic's OAuth inference path rejects requests that do not identify as Claude Code, so
    /// this User-Agent is load-bearing rather than cosmetic. Note it differs in shape from the
    /// `claude-code/<version>` string ``ClaudeOAuthUsageFetcher`` sends: this is the value proven
    /// against `/v1/messages`, and the two endpoints are not interchangeable about it. A wrong
    /// User-Agent here comes back as a `rate_limit_error` that never clears, which reads as
    /// throttling and is not.
    private static let userAgent = "claude-cli/2.1.219 (external, cli)"

    /// Also load-bearing: OAuth inference expects the Claude Code system prompt and refuses
    /// requests without it.
    private static let systemPrompt = "You are Claude Code, Anthropic's official CLI for Claude."

    /// Tried in order, cheapest first. The list exists because model availability differs by plan
    /// and Anthropic retires aliases; the kick only needs *a* model that answers.
    public static let models = [
        "claude-haiku-4-5-20251001",
        "claude-haiku-4-5",
        "claude-sonnet-5",
    ]

    /// Sends the smallest request that starts a window: one token of output, one word of input.
    ///
    /// Falls through ``models`` on any failure that is not an auth or rate-limit refusal, since
    /// those two are about the account rather than the model and retrying cannot help.
    public static func kick(
        accessToken: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async -> KickOutcome
    {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .noCredentials }

        var lastFailure = "Claude did not accept the request."

        for model in self.models {
            switch await self.attempt(model: model, accessToken: token, transport: transport) {
            case .started:
                return .started
            case let .terminal(outcome):
                return outcome
            case let .retryable(message):
                lastFailure = message
            }
        }

        return .failed(message: lastFailure)
    }

    // MARK: - Internals

    /// One model's worth of attempt, classified into "done", "done badly", or "try the next model".
    private enum Attempt {
        case started
        case terminal(KickOutcome)
        case retryable(String)
    }

    private static func attempt(
        model: String,
        accessToken: String,
        transport: any ProviderHTTPTransport) async -> Attempt
    {
        guard let request = self.makeRequest(model: model, accessToken: accessToken) else {
            return .retryable("Could not build the request for \(model).")
        }

        do {
            let response = try await transport.response(for: request)
            switch response.statusCode {
            case 200..<300:
                return .started
            case 401:
                return .terminal(.noCredentials)
            case 403:
                return .terminal(.unsupported(
                    reason: "This Claude account is not allowed to send messages."))
            case 429:
                return .terminal(.failed(
                    message: "Claude is rate limiting this account. Try again in a few minutes."))
            default:
                return .retryable("Claude returned HTTP \(response.statusCode) for \(model).")
            }
        } catch {
            return .retryable(error.localizedDescription)
        }
    }

    static func makeRequest(model: String, accessToken: String) -> URLRequest? {
        guard let url = URL(string: self.baseURL + self.messagesPath) else { return nil }
        guard let body = try? JSONEncoder().encode(KickMessageBody(model: model, system: self.systemPrompt))
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}

/// The request body, kept as a type so the shape is checked rather than string-built.
struct KickMessageBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    init(model: String, system: String) {
        self.model = model
        self.maxTokens = 1
        self.system = system
        self.messages = [Message(role: "user", content: "hi")]
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}
