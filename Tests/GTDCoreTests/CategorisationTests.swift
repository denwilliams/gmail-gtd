import Foundation
import Testing
@testable import GTDCore

private let localSuggestion = TriageSuggestion(bucket: .reference, nextAction: "", summary: "Local summary.", waitingOn: nil)

private func email(_ body: String = "Please review the document.") throws -> GmailThread {
    let json: [String: Any] = ["id": "thread", "messages": [[
        "id": "m1", "threadId": "thread", "payload": [
            "mimeType": "text/plain", "headers": [["name": "From", "value": "me@example.com"], ["name": "Subject", "value": "Review"]],
            "body": ["data": Data(body.utf8).base64EncodedString()]
        ]
    ]]]
    return try JSONDecoder().decode(GmailThread.self, from: JSONSerialization.data(withJSONObject: json))
}

@Test func jevIsExplicitlyOptInAndPromptsPersistIndependently() throws {
    let suite = "categorisation-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!CategorisationSettings.load(from: defaults).jevEnabled)
    var settings = CategorisationSettings()
    settings.localPrompt = "Custom local instructions"
    settings.jevPrompt = String(repeating: "Detailed Jev guidance. ", count: 600)
    settings.jevEnabled = true
    try settings.save(to: defaults)
    let loaded = CategorisationSettings.load(from: defaults)
    #expect(loaded == settings)
    settings.localPrompt = TriagePrompts.local
    try settings.save(to: defaults)
    #expect(CategorisationSettings.load(from: defaults).jevPrompt == loaded.jevPrompt)
    settings.jevPrompt = TriagePrompts.jev
    try settings.save(to: defaults)
    #expect(CategorisationSettings.load(from: defaults).localPrompt == TriagePrompts.local)
}

@Test func invalidAndOverLimitPromptsAreRejectedWithoutTruncation() {
    #expect(throws: (any Error).self) { try TriagePrompts.validate("  \n", maxBytes: 100, source: "Jev") }
    #expect(throws: (any Error).self) {
        try TriagePrompts.validate(String(repeating: "é", count: 1001), maxBytes: TriagePrompts.localMaxBytes, source: "Local")
    }
    #expect(throws: (any Error).self) {
        try JevClient.request(email(), me: nil, prompt: String(repeating: "x", count: TriagePrompts.jevMaxBytes + 1), token: "test")
    }
}

@Test func jevUsesDocumentedEndpointAuthAndChoiceSchema() async throws {
    let client = JevClient { request in
        #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Long-Context") == nil)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "jev-1.14.0")
        #expect((body["state"] as? String)?.contains("(you)") == true)
        let questions = try #require(body["questions"] as? [String: [String: Any]])
        #expect(questions.count == 1)
        #expect(questions["bucket"]?["type"] as? String == "choice")
        #expect(questions["bucket"]?["instructions"] as? String == "Custom Jev instructions")
        let criteria = try #require(questions["bucket"]?["criteria"] as? [String: String])
        #expect(Set(criteria.keys) == Set(GTDBucket.allCases.map(\.rawValue)))
        return (Data(#"{"answers":{"bucket":{"type":"choice","choice":"nextAction","confidence":0.99}}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    #expect(try await client.categorise(email(), me: "me@example.com", prompt: "Custom Jev instructions", token: "test-token") == .nextAction)
}

@Test func jevHasLargerIndependentBudgetAndBoundsEncodedUnicodeInput() throws {
    let thread = try email(String(repeating: "🦋 \"review\"\n", count: 15_000))
    let prompt = String(repeating: "p", count: 20_000)
    let request = try JevClient.request(thread, me: nil, prompt: prompt, token: "test")
    let data = try #require(request.httpBody)
    #expect(data.count <= JevClient.maxRequestBytes)
    #expect(data.count > 6_000)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let questions = try #require(body["questions"] as? [String: [String: Any]])
    #expect(questions["bucket"]?["instructions"] as? String == prompt)
    #expect(!(body["state"] as? String ?? "").contains("�"))
}

@Test(arguments: ["", " \n", "bad\r\ntoken"])
func missingAndInvalidTokensFailBeforeHTTP(_ token: String) async throws {
    let client = JevClient { _ in Issue.record("No request should be sent"); throw URLError(.badURL) }
    await #expect(throws: (any Error).self) {
        try await client.categorise(email(), me: nil, prompt: TriagePrompts.jev, token: token)
    }
}

@Test(arguments: [
    #"{"answers":{"bucket":{"type":"choice","choice":"not-a-bucket"}}}"#,
    #"{"answers":{}}"#,
    #"{"answers":{"bucket":{"type":"score","choice":"reference"}}}"#,
    "not json"
])
func unusableJevOutputCannotApprove(_ body: String) async throws {
    let client = JevClient { request in
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    await #expect(throws: (any Error).self) {
        try await client.categorise(email(), me: nil, prompt: TriagePrompts.jev, token: "test")
    }
}

@Test(arguments: [401, 429, 500])
func jevErrorsDoNotExposeProviderBodiesOrCredentials(_ status: Int) async throws {
    let client = JevClient { request in
        (Data("PRIVATE EMAIL test-token".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    do {
        _ = try await client.categorise(email(), me: nil, prompt: TriagePrompts.jev, token: "test-token")
        Issue.record("Expected HTTP failure")
    } catch {
        #expect(error.localizedDescription.contains("\(status)"))
        #expect(!error.localizedDescription.contains("PRIVATE EMAIL"))
        #expect(!error.localizedDescription.contains("test-token"))
    }
}

@Test func approvalAlwaysPrefersEnabledJevAndNeverFallsBack() {
    #expect(ApprovalPolicy.bucket(jevEnabled: false, local: localSuggestion, jev: .success(.noise)) == .reference)
    #expect(ApprovalPolicy.bucket(jevEnabled: true, local: localSuggestion, jev: .success(.nextAction)) == .nextAction)
    #expect(ApprovalPolicy.bucket(jevEnabled: true, local: nil, jev: .success(.nextAction)) == .nextAction)
    #expect(ApprovalPolicy.bucket(jevEnabled: true, local: localSuggestion, jev: nil) == nil)
    #expect(ApprovalPolicy.bucket(jevEnabled: true, local: localSuggestion, jev: .pending) == nil)
    #expect(ApprovalPolicy.bucket(jevEnabled: true, local: localSuggestion, jev: .failure("Offline")) == nil)
}

@Test func optedOutCategorisationNeverCallsJevEvenWithAToken() async throws {
    let categoriser = Categoriser(local: { _, _, prompt in
        #expect(prompt == TriagePrompts.local); return localSuggestion
    }, remote: { _, _, _, _ in Issue.record("Opt-out must not call Jev"); return .noise })
    let output = await categoriser.evaluate(try email(), me: nil, settings: CategorisationSettings(), token: "stored-token")
    #expect(output.local?.bucket == .reference)
    #expect(output.jev == nil)
}

@Test func dualCategorisationRetainsBothResultsAndIndependentPrompts() async throws {
    var settings = CategorisationSettings()
    settings.jevEnabled = true; settings.localPrompt = "LOCAL"; settings.jevPrompt = "REMOTE"
    let categoriser = Categoriser(local: { _, _, prompt in
        #expect(prompt == "LOCAL"); return localSuggestion
    }, remote: { _, _, prompt, token in
        #expect(prompt == "REMOTE"); #expect(token == "test"); return .nextAction
    })
    let output = await categoriser.evaluate(try email(), me: nil, settings: settings, token: "test")
    #expect(output.local?.bucket == .reference)
    #expect(output.jev?.bucket == .nextAction)
}

@Test func remoteFailureDoesNotCancelLocalAndLocalFailureDoesNotCancelRemote() async throws {
    var settings = CategorisationSettings(); settings.jevEnabled = true
    let remoteFailure = Categoriser(local: { _, _, _ in
        try await Task.sleep(for: .milliseconds(20)); return localSuggestion
    }, remote: { _, _, _, _ in throw URLError(.timedOut) })
    let a = await remoteFailure.evaluate(try email(), me: nil, settings: settings, token: "test")
    #expect(a.local?.bucket == .reference)
    #expect(a.jev?.isFinished == true)
    #expect(ApprovalPolicy.bucket(jevEnabled: true, local: a.local, jev: a.jev) == nil)
    let localFailure = Categoriser(local: { _, _, _ in throw TriageError.modelUnavailable("test") },
                                  remote: { _, _, _, _ in .project })
    let b = await localFailure.evaluate(try email(), me: nil, settings: settings, token: "test")
    #expect(b.localError != nil)
    #expect(b.jev?.bucket == .project)
}

@MainActor @Test func localPromptChangesInvalidateCachedSuggestions() {
    let store = SummaryStore()
    let thread = GmailThread(id: "t", historyId: "1", messages: [])
    store.setSuggestion(localSuggestion, for: thread, prompt: "FIRST")
    #expect(store.suggestion(for: "t", prompt: "FIRST") != nil)
    #expect(store.suggestion(for: "t", prompt: "SECOND") == nil)
    store.setSuggestion(localSuggestion, for: thread)
    #expect(store.suggestion(for: "t", prompt: TriagePrompts.local) != nil)
    #expect(store.suggestion(for: "t", prompt: "CUSTOM") == nil)
}
