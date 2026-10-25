import Foundation
import Testing
@testable import GTDCore

@Test func jevOnlyRunDoesNotStartLocalModel() async {
    var settings = CategorisationSettings(); settings.jevEnabled = true
    let categoriser = Categoriser(local: { _, _, _ in
        Issue.record("Jev queue must not start local work")
        return TriageSuggestion(bucket: .reference, nextAction: "", summary: "", waitingOn: nil)
    }, remote: { _, _, _, _ in JevClassification(bucket: .noise) })
    let collector = CategorisationCollector()
    await categoriser.run(GmailThread(id: "t", historyId: "1", messages: []), me: nil,
                          settings: settings, token: "mock", sources: [.jev]) { event in
        await collector.record(event)
        guard case .jev(let result) = event else { Issue.record("Expected only Jev event"); return }
        #expect(result.bucket == .noise)
    }
    #expect(await collector.output.jev?.bucket == .noise)
}

@Test func localOnlyRunNeverCallsJevEvenWhenEnabled() async {
    var settings = CategorisationSettings(); settings.jevEnabled = true
    let categoriser = Categoriser(local: { _, _, _ in
        TriageSuggestion(bucket: .reference, nextAction: "", summary: "", waitingOn: nil)
    }, remote: { _, _, _, _ in Issue.record("Local queue must not start Jev work"); return JevClassification(bucket: .noise) })
    let collector = CategorisationCollector()
    await categoriser.run(GmailThread(id: "t", historyId: "1", messages: []), me: nil,
                          settings: settings, token: "mock", sources: [.local]) { event in
        await collector.record(event)
        guard case .local(let result) = event else { Issue.record("Expected only local event"); return }
        #expect(result.bucket == .reference)
    }
    #expect(await collector.output.local?.bucket == .reference)
}

@Test func jevQueueStillRespectsOptOut() async {
    let categoriser = Categoriser(local: { _, _, _ in
        Issue.record("No local work requested")
        return TriageSuggestion(bucket: .reference, nextAction: "", summary: "", waitingOn: nil)
    }, remote: { _, _, _, _ in Issue.record("Opt-out must not call Jev"); return JevClassification(bucket: .noise) })
    await categoriser.run(GmailThread(id: "t", historyId: "1", messages: []), me: nil,
                          settings: CategorisationSettings(), token: "mock", sources: [.jev]) { _ in
        Issue.record("Opt-out must not publish Jev results")
    }
}
