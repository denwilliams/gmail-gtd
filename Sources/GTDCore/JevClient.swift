import Foundation

/// TypeSafe System One Choice API, not a chat-completions endpoint.
public struct JevClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    public static let model = "jev-1.14.0"
    // Docs: 64k tokens/request, 32k/question (state + instructions + criteria).
    // A single question, capped at 30k *encoded UTF-8 bytes*, conservatively budgets tokens
    // without assuming English's usual characters/token ratio. Reserve room for provider framing.
    public static let maxRequestBytes = 30_000

    public init(transport: @escaping Transport = { request in
        // Ephemeral storage avoids caching private mail; never follow redirects with a bearer token.
        let session = URLSession(configuration: .ephemeral, delegate: NoJevRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CategorisationError.message("Jev returned an invalid HTTP response. Retry.")
        }
        return (data, response)
    }) { self.transport = transport }

    public func categorise(_ thread: GmailThread, me: String?, prompt: String, token: String) async throws -> GTDBucket {
        let request = try Self.request(thread, me: me, prompt: prompt, token: token)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch { throw CategorisationError.message("Jev could not be reached. Check your connection and retry.") }
        guard (200..<300).contains(response.statusCode) else {
            // Provider error bodies may echo prompts/mail: never expose them in errors or logs.
            throw CategorisationError.message("Jev HTTP \(response.statusCode). Check the token, quota and prompt in Settings, then retry.")
        }
        struct Answer: Decodable { let type: String; let choice: GTDBucket }
        struct Response: Decodable { let answers: [String: Answer] }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let answer = decoded.answers["bucket"], answer.type == "choice" else {
            throw CategorisationError.message("Jev returned no usable GTD category. Retry; manual filing is still available.")
        }
        return answer.choice
    }

    static func request(_ thread: GmailThread, me: String?, prompt: String, token: String) throws -> URLRequest {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else {
            throw CategorisationError.message("Add a valid Jev API token in Settings, or disable Jev to use local-only triage.")
        }
        try TriagePrompts.validate(prompt, maxBytes: TriagePrompts.jevMaxBytes, source: "Jev")
        struct Question: Encodable { let type = "choice"; let instructions: String; let criteria: [String: String] }
        struct Request: Encodable { let model = JevClient.model; let state: String; let questions: [String: Question] }
        let criteria = [
            "nextAction": "One concrete action, decision, review or reply required from the user.",
            "waitingFor": "The user has asked someone else and is waiting for their next move.",
            "someday": "An optional idea or nice-to-have with no deadline.",
            "reference": "Useful information worth keeping, with no action required.",
            "project": "An outcome requiring multiple separate steps over time.",
            "noise": "Bulk marketing, newsletters, promotions or unhelpful automated notices.",
            "done": "A completed task needing no further action."
        ]
        let questions = ["bucket": Question(instructions: prompt, criteria: criteria)]
        let encoder = JSONEncoder()
        let overhead = try encoder.encode(Request(state: "", questions: questions)).count
        // Limit the *JSON-encoded* state, including escapes, not just its character count.
        var state = transcript(thread, me: me, maxBytes: max(0, maxRequestBytes - overhead))
        var body = try encoder.encode(Request(state: state, questions: questions))
        while body.count > maxRequestBytes && !state.isEmpty {
            state = String(state.prefix(state.count * 9 / 10))
            body = try encoder.encode(Request(state: state, questions: questions))
        }
        guard body.count <= maxRequestBytes, !state.isEmpty else {
            throw CategorisationError.message("Jev input is empty or too large. Shorten the prompt in Settings.")
        }
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func transcript(_ thread: GmailThread, me: String?, maxBytes: Int) -> String {
        var result = "Email thread (newest message first):\n"
        for message in (thread.messages ?? []).reversed() {
            let mine = me.map { message.from.localizedCaseInsensitiveContains($0) } ?? false
            let body = message.plainText.modelFriendly.split(separator: "\n", omittingEmptySubsequences: true)
                .filter { !$0.hasPrefix(">") }.joined(separator: "\n")
            result += "From: \(message.from)\(mine ? " (you)" : "")\nSubject: \(message.subject)\n\(body)\n---\n"
            if result.utf8.count >= maxBytes { break }
        }
        // Decode a possibly split UTF-8 sequence without adding replacement characters.
        var bytes = Array(result.utf8.prefix(maxBytes))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

private final class NoJevRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
