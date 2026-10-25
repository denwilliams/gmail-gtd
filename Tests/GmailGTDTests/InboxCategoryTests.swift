import Foundation
import Testing
@testable import GmailGTD
@testable import GTDCore

private enum InboxCategoryError: Error { case unavailable }

@MainActor private func waitForInboxCategory(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for inbox category")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(arguments: [true, false]) @MainActor
func inboxPrefersJevWithOrWithoutLocalResult(localAvailable: Bool) async throws {
    var settings = CategorisationSettings(); settings.jevEnabled = true
    let categoriser = Categoriser(local: { _, _, _ in
        guard localAvailable else { throw InboxCategoryError.unavailable }
        return TriageSuggestion(bucket: .nextAction, nextAction: "Reply", summary: "Local summary.")
    }, remote: { _, _, _, _ in JevClassification(bucket: .noise) })
    let model = AppModel(signedIn: true, settings: settings, folder: .inbox,
                         categoriser: categoriser, loadJevToken: { nil })
    model.demo = true
    defer { model.signOut() }
    #expect(model.inboxBucket(for: "missing") == nil)
    await model.connect(using: DemoMailService(), persist: false)
    try await waitForInboxCategory { model.jevStatus?.bucket == .noise && !model.suggesting }
    let id = try #require(model.selection)
    #expect(model.inboxBucket(for: id) == .noise)
    #expect(model.approvalBucket == .noise)
    #expect(model.localSuggestion(for: id)?.bucket == (localAvailable ? .nextAction : nil))
    #expect(model.localSuggestion(for: id)?.summary == (localAvailable ? "Local summary." : nil))

    // The badge reads the row's result, not whichever thread is selected in the detail pane.
    model.selection = nil
    #expect(model.inboxBucket(for: id) == .noise)
    #expect(model.inboxBucket(for: "another-thread") == nil)
    model.categorisationSettings.jevEnabled = false
    #expect(model.inboxBucket(for: id) == (localAvailable ? .nextAction : nil))
}

@Test(arguments: [true, false]) @MainActor
func inboxFallsBackToLocalWhenJevFailsOrIsDisabled(jevEnabled: Bool) async throws {
    var settings = CategorisationSettings(); settings.jevEnabled = jevEnabled
    let categoriser = Categoriser(local: { _, _, _ in
        TriageSuggestion(bucket: .nextAction, nextAction: "Reply", summary: "Local summary.")
    }, remote: { _, _, _, _ in throw InboxCategoryError.unavailable })
    let model = AppModel(signedIn: true, settings: settings, folder: .inbox,
                         categoriser: categoriser, loadJevToken: { nil })
    model.demo = true
    defer { model.signOut() }
    await model.connect(using: DemoMailService(), persist: false)
    try await waitForInboxCategory { model.suggestion != nil && !model.suggesting }
    let id = try #require(model.selection)
    #expect(model.inboxBucket(for: id) == .nextAction)
    #expect(model.jevStatus?.failed == (jevEnabled ? true : nil))
    // A display fallback must not silently enable local approval while Jev is enabled.
    #expect(model.approvalBucket == (jevEnabled ? nil : .nextAction))
}

@Test @MainActor func inboxBadgeUpdatesFromLocalFallbackWhenJevArrives() async throws {
    let (results, continuation) = AsyncStream<GTDBucket>.makeStream()
    defer { continuation.finish() }
    var settings = CategorisationSettings(); settings.jevEnabled = true
    let categoriser = Categoriser(local: { _, _, _ in
        TriageSuggestion(bucket: .nextAction, nextAction: "Reply", summary: "Local summary.")
    }, remote: { _, _, _, _ in
        for await bucket in results { return JevClassification(bucket: bucket) }
        throw InboxCategoryError.unavailable
    })
    let model = AppModel(signedIn: true, settings: settings, folder: .inbox,
                         categoriser: categoriser, loadJevToken: { nil })
    model.demo = true
    defer { model.signOut() }
    await model.connect(using: DemoMailService(), persist: false)
    try await waitForInboxCategory { model.suggestion != nil }
    let id = try #require(model.selection)
    #expect(model.jevStatus?.pending == true)
    #expect(model.inboxBucket(for: id) == .nextAction)
    #expect(model.approvalBucket == nil)

    continuation.yield(.noise)
    continuation.finish()
    try await waitForInboxCategory { model.inboxBucket(for: id) == .noise && !model.suggesting }
    #expect(model.inboxBucket(for: id) == .noise)
    #expect(model.localSuggestion(for: id)?.bucket == .nextAction)
    #expect(model.approvalBucket == .noise)
}
