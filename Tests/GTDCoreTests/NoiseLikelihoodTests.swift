import Foundation
import Testing
@testable import GTDCore

private func scoredJev(_ body: String) async throws -> JevClassification {
    let client = JevClient { request in
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let thread = GmailThread(id: "score", historyId: "1", messages: [
        GmailMessage(id: "m", threadId: "score", labelIds: [], snippet: "", internalDate: nil, payload: nil)
    ])
    return try await client.categorise(thread, me: nil, prompt: TriagePrompts.jev, token: "mock-token")
}

@Test(arguments: [0.0, 0.899999, 0.90, 0.91, 1.0])
func jevReadsNoiseProbabilityNotChoiceConfidence(score: Double) async throws {
    let result = try await scoredJev("""
        {"answers":{"bucket":{"type":"choice","choice":"noise","confidence":0.01,
        "probabilities":{"noise":\(score),"reference":\(1 - score)}}}}
        """)
    #expect(result.bucket == .noise)
    #expect(result.noiseLikelihood == score)
}

@Test(arguments: [
    "", ",\"confidence\":1", ",\"probabilities\":null", ",\"probabilities\":{}",
    ",\"probabilities\":{\"reference\":1}", ",\"probabilities\":{\"noise\":-0.1}",
    ",\"probabilities\":{\"noise\":1.1}", ",\"probabilities\":{\"noise\":\"0.99\"}",
    ",\"probabilities\":{\"noise\":null}", ",\"probabilities\":{\"noise\":true}",
    ",\"probabilities\":{\"noise\":\"NaN\"}"
])
func unusableJevScoresRemainUnscoredButKeepOrdinaryApproval(extra: String) async throws {
    let result = try await scoredJev("{\"answers\":{\"bucket\":{\"type\":\"choice\",\"choice\":\"noise\"\(extra)}}}")
    #expect(result.bucket == .noise)
    #expect(result.noiseLikelihood == nil)
    let state = JevState.success(result.bucket, noiseLikelihood: result.noiseLikelihood)
    #expect(ApprovalPolicy.bucket(jevEnabled: true, local: nil, jev: state) == .noise)
    #expect(!NoiseLikelihood.qualifies(bucket: state.bucket, score: state.noiseLikelihood, threshold: 0))
}

@Test(arguments: [Double.nan, .infinity, -.infinity, -0.01, 1.01])
func invalidLikelihoodsAndThresholdsNeverQualify(value: Double) {
    #expect(NoiseLikelihood.validated(value) == nil)
    #expect(JevClassification(bucket: .noise, noiseLikelihood: value).noiseLikelihood == nil)
    #expect(JevState.success(.noise, noiseLikelihood: value).noiseLikelihood == nil)
    #expect(!NoiseLikelihood.qualifies(bucket: .noise, score: value, threshold: 0))
    #expect(!NoiseLikelihood.qualifies(bucket: .noise, score: 1, threshold: value))
}

@Test func thresholdsAreInclusiveAndMissingScoresNeverQualify() {
    #expect(NoiseLikelihood.qualifies(bucket: .noise, score: 0.90, threshold: 0.90))
    #expect(!NoiseLikelihood.qualifies(bucket: .noise, score: 0.899999, threshold: 0.90))
    #expect(NoiseLikelihood.qualifies(bucket: .noise, score: 0, threshold: 0))
    #expect(NoiseLikelihood.qualifies(bucket: .noise, score: 1, threshold: 1))
    #expect(!NoiseLikelihood.qualifies(bucket: .noise, score: 0.999999, threshold: 1))
    #expect(!NoiseLikelihood.qualifies(bucket: .noise, score: nil, threshold: 0))
    #expect(!NoiseLikelihood.qualifies(bucket: .reference, score: 1, threshold: 0))
    #expect(!NoiseLikelihood.qualifies(bucket: nil, score: 1, threshold: 0))
}

@Test func scoresFollowOnlyTheActiveApprovalSource() {
    let local = TriageSuggestion(bucket: .noise, nextAction: "", summary: "", noiseLikelihood: 0.99)
    for state in [nil, .pending, .failure("Offline"), .success(.noise)] as [JevState?] {
        #expect(ApprovalPolicy.noiseLikelihood(jevEnabled: true, local: local, jev: state) == nil)
        #expect(ApprovalPolicy.noiseLikelihood(jevEnabled: false, local: local, jev: state) == 0.99)
    }
    let remote = JevState.success(.noise, noiseLikelihood: 0.80)
    #expect(ApprovalPolicy.noiseLikelihood(jevEnabled: true, local: local, jev: remote) == 0.80)
    #expect(ApprovalPolicy.noiseLikelihood(jevEnabled: false, local: nil, jev: remote) == nil)
    let invalidLocal = TriageSuggestion(bucket: .noise, nextAction: "", summary: "", noiseLikelihood: .nan)
    #expect(ApprovalPolicy.noiseLikelihood(jevEnabled: false, local: invalidLocal, jev: remote) == nil)
}

@Test func categoriserCarriesScoresWithoutCombiningSources() async {
    var settings = CategorisationSettings(); settings.jevEnabled = true
    let categoriser = Categoriser(local: { _, _, _ in
        TriageSuggestion(bucket: .reference, nextAction: "", summary: "", noiseLikelihood: 0.2)
    }, remote: { _, _, _, _ in JevClassification(bucket: .noise, noiseLikelihood: 0.95) })
    let output = await categoriser.evaluate(GmailThread(id: "t", historyId: "1", messages: []),
                                           me: nil, settings: settings, token: "mock")
    #expect(output.local?.noiseLikelihood == 0.2)
    #expect(output.jev?.noiseLikelihood == 0.95)
    #expect(output.jev?.bucket == .noise)
}

@Test func oldLocalCachesDecodeWithoutInventingConfidence() throws {
    let old = Data(#"{"bucket":"noise","nextAction":"","summary":"Cached newsletter."}"#.utf8)
    var suggestion = try JSONDecoder().decode(TriageSuggestion.self, from: old)
    #expect(suggestion.bucket == .noise)
    #expect(suggestion.noiseLikelihood == nil)
    suggestion.noiseLikelihood = 0.92
    let roundTrip = try JSONDecoder().decode(TriageSuggestion.self, from: JSONEncoder().encode(suggestion))
    #expect(roundTrip.noiseLikelihood == 0.92)
}
