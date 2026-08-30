import Foundation

/// Talks to a local LM Studio server over its OpenAI-compatible REST API.
/// https://lmstudio.ai/docs/developer/rest/quickstart
///
/// Stateless `struct` — instantiate with the user's `baseURL` from `AppSettings`
/// and call `listModels()` (Settings UI) or `chatCompletion(...)` (generator).
/// Two known divergences from OpenAI's API are handled here — see `chatCompletion`.
struct LMStudioClient: Sendable {
    let baseURL: URL

    /// Errors thrown by both `listModels()` and `chatCompletion(...)`. All
    /// `LocalizedError` so they appear as readable strings in alerts and the log.
    enum Error: LocalizedError {
        case invalidURL
        case http(Int, body: String = "")
        case decode(String)
        case network(String)
        /// LM Studio ran out of KV-cache room. Broken out from `.http` because the
        /// remedy is specific and actionable, and because the raw form of it —
        /// a 400 wrapping a 500 wrapping a message — tells the user nothing.
        case contextExceeded

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "LM Studio URL is invalid."
            case .http(let s, let body):
                return body.isEmpty
                    ? "LM Studio returned HTTP \(s)."
                    : "LM Studio returned HTTP \(s): \(body)"
            case .decode(let s): return "Couldn't read LM Studio response: \(s)"
            case .network(let s): return "Couldn't reach LM Studio: \(s)"
            case .contextExceeded:
                return "LM Studio ran out of context. Raise the model's context length, or lower \"Parallel requests\" in Settings so fewer playlists are generated at once."
            }
        }

        /// LM Studio reports this as a 400 whose body wraps an engine-level 500,
        /// so the status code alone can't distinguish it from a malformed request.
        static func fromHTTP(_ status: Int, body: String) -> Error {
            if body.localizedCaseInsensitiveContains("context size has been exceeded")
                || body.localizedCaseInsensitiveContains("context length")
                || body.localizedCaseInsensitiveContains("n_keep") {
                return .contextExceeded
            }
            return .http(status, body: body)
        }
    }

    /// Decodable shape of `/v1/models` (just the model IDs we display in the picker).
    private struct ModelsResponse: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }

    /// One message in a chat-completion conversation. Two-role helpers (`.system`,
    /// `.user`) cover everything we send — we never construct multi-turn dialogs.
    struct ChatMessage: Sendable {
        let role: String
        let content: String

        static func system(_ content: String) -> ChatMessage { .init(role: "system", content: content) }
        static func user(_ content: String) -> ChatMessage { .init(role: "user", content: content) }
    }

    /// Tells the server to constrain output to a named JSON schema. LM Studio requires
    /// this form (`response_format.type = "json_schema"`); plain `"json_object"` is rejected.
    /// `schemaJSON` is the raw JSON of the schema body itself (the value of `json_schema.schema`).
    struct ResponseSchema: Sendable {
        let name: String
        let schemaJSON: String
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Message
            let finish_reason: String?
            struct Message: Decodable {
                let content: String?
                /// Reasoning models (Qwen3, DeepSeek-R1, …) put their structured output here
                /// when "thinking mode" is on; `content` ends up empty in that case.
                let reasoning_content: String?
            }
        }
    }

    /// Single-shot chat completion. Returns the assistant's content string.
    /// Pass `responseSchema` to constrain output via LM Studio's `json_schema` mode.
    ///
    /// Two LM Studio quirks handled inside:
    ///
    /// 1. We build the request body with `JSONSerialization` (not `Encodable`)
    ///    because injecting the user's raw schema JSON as a nested object is much
    ///    cleaner that way than constructing a parallel Encodable hierarchy.
    /// 2. The decoded response checks BOTH `message.content` and
    ///    `message.reasoning_content`, falling back to the latter when the
    ///    former is empty. Reasoning models (Qwen3, DeepSeek-R1, etc.) emit
    ///    their structured output via the reasoning channel and leave `content`
    ///    blank — without this fallback we'd silently get empty results.
    ///
    /// Long timeout (180 s) because slow local models (large parameter counts on
    /// modest hardware) can take a minute+ to generate even a few KB of JSON.
    func chatCompletion(
        model: String,
        messages: [ChatMessage],
        temperature: Double = 0.8,
        maxTokens: Int? = nil,
        responseSchema: ResponseSchema? = nil
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        Log.info("POST \(url.absoluteString) model=\(model) messages=\(messages.count) schema=\(responseSchema?.name ?? "none") maxTokens=\(maxTokens.map { String($0) } ?? "default")", category: LogCategory.llm)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 180

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
        ]
        if let maxTokens {
            body["max_tokens"] = maxTokens
        }
        if let schema = responseSchema {
            let parsedSchema: Any
            do {
                parsedSchema = try JSONSerialization.jsonObject(with: Data(schema.schemaJSON.utf8))
            } catch {
                throw Error.decode("invalid response schema JSON: \(error.localizedDescription)")
            }
            // LM Studio's structured outputs follow OpenAI's json_schema shape, but
            // some servers reject `strict: true` outright. Omit it for compatibility.
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": schema.name,
                    "schema": parsedSchema,
                ],
            ]
        }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw Error.decode("encode request: \(error.localizedDescription)")
        }

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            Log.error("LM Studio network error: \(error.localizedDescription)", category: LogCategory.llm)
            throw Error.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.http(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyPreview = String(data: data.prefix(400), encoding: .utf8) ?? ""
            Log.error("LM Studio HTTP \(http.statusCode): \(bodyPreview)", category: LogCategory.llm)
            throw Error.fromHTTP(http.statusCode, body: bodyPreview)
        }

        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw Error.decode(error.localizedDescription)
        }
        guard let choice = decoded.choices.first else {
            throw Error.decode("no choices in response")
        }
        let primary = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reasoning = choice.message.reasoning_content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let actual = !primary.isEmpty ? primary : reasoning
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let source = !primary.isEmpty ? "content" : (reasoning.isEmpty ? "(empty)" : "reasoning_content")
        Log.info(
            "LM Studio chat completion done in \(elapsedMs)ms (\(actual.count) chars from \(source), finish_reason=\(choice.finish_reason ?? "?"))",
            category: LogCategory.llm
        )
        if actual.isEmpty {
            // Surface the raw body so we can diagnose schema-rejected or refusal cases.
            let preview = String(data: data.prefix(4000), encoding: .utf8) ?? "(binary)"
            Log.warning("LM Studio returned no usable content. Raw body preview:\n\(preview)", category: LogCategory.llm)
        }
        return actual
    }

    /// `GET /v1/models`. Used by the Settings → LLM tab to populate the model
    /// picker and by the Test Connection button. Short timeout (5 s) since the
    /// endpoint is a cheap directory listing — slow responses indicate the
    /// server is wedged.
    func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("v1/models")
        Log.debug("GET \(url.absoluteString)", category: LogCategory.llm)

        var req = URLRequest(url: url)
        req.timeoutInterval = 5

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            Log.error("LM Studio network error: \(error.localizedDescription)", category: LogCategory.llm)
            throw Error.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.http(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            Log.error("LM Studio HTTP \(http.statusCode)", category: LogCategory.llm)
            throw Error.http(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let ids = decoded.data.map(\.id)
            Log.info("LM Studio /v1/models -> \(ids.count) models", category: LogCategory.llm)
            return ids
        } catch {
            Log.error("LM Studio JSON decode failed: \(error)", category: LogCategory.llm)
            throw Error.decode(error.localizedDescription)
        }
    }
}
