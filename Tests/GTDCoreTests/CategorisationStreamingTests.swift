import Foundation
import Testing
@testable import GTDCore

private actor StreamingProbe {
    var sources: [String] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func waitUntilLocalIsDisplayed() async {
        if sources.contains("local") { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func record(_ event: CategorisationEvent) {
        switch event {
        case .local:
            sources.append("local")
            waiter?.resume(); waiter = nil
        case .jev: sources.append("jev")
        default: Issue.record("Unexpected failure")
        }
    }
}

@Test func localResultIsPublishedWhileJevIsStillPending() async throws {
    let probe = StreamingProbe()
    var settings = CategorisationSettings(); settings.jevEnabled = true
    let categoriser = Categoriser(local: { _, _, _ in
        TriageSuggestion(bucket: .reference, nextAction: "", summary: "Local result.", waitingOn: nil)
    }, remote: { _, _, _, _ in
        await probe.waitUntilLocalIsDisplayed()
        return .project
    })
    let thread = GmailThread(id: "t", historyId: "1", messages: [])
    await categoriser.run(thread, me: nil, settings: settings, token: "test") { await probe.record($0) }
    #expect(await probe.sources == ["local", "jev"])
}
