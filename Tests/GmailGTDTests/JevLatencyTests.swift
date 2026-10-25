import Foundation
import Testing
@testable import GmailGTD
@testable import GTDCore

private actor HeldLocalModel {
    private(set) var started: [String] = []
    private var released = false

    func suggest(_ thread: GmailThread) async throws -> TriageSuggestion {
        started.append(thread.id)
        // Bounded even on regressions, so a failed assertion cannot strand the suite.
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !released && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return TriageSuggestion(bucket: .reference, nextAction: "", summary: "Local summary.", waitingOn: nil)
    }

    func release() { released = true }
}

@MainActor private func waitForLatencyTest(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await condition()) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await condition(), "Timed out waiting for independently available Jev result")
}

@Test @MainActor func selectedThreadJevDoesNotWaitForPreviousThreadsLocalModel() async throws {
    let local = HeldLocalModel()
    var settings = CategorisationSettings(); settings.jevEnabled = true
    let categoriser = Categoriser(local: { thread, _, _ in try await local.suggest(thread) },
                                  remote: { _, _, _, _ in .noise })
    let model = AppModel(signedIn: true, settings: settings, folder: .inbox,
                         categoriser: categoriser, loadJevToken: { "mock-token" })
    model.demo = true
    defer { model.signOut() }
    await model.connect(using: DemoMailService(), persist: false)
    let first = try #require(model.selection)
    try await waitForLatencyTest { await local.started == [first] && model.approvalBucket == .noise }
    let second = try #require(model.rows.first { $0.id != first }).id

    // The old shared worker cannot publish this Jev result until the gate opens.
    // The new bounded Jev lane must publish it while the FIRST local request is still held.
    let start = ContinuousClock.now
    model.selection = second
    try await waitForLatencyTest { model.detail?.id == second && model.approvalBucket == .noise }
    let jevWait = start.duration(to: .now)
    #expect(model.jevStatus?.text == "Jev: Noise")
    #expect(model.suggestion == nil)
    #expect(await local.started == [first])   // Preserve a single local-model worker.
    print("Controlled Jev wait with previous local request held: \(jevWait)")

    await local.release()
    try await waitForLatencyTest { model.suggestion?.bucket == .reference && !model.suggesting }
    #expect(model.approvalBucket == .noise)   // Differing sources do not change approval policy.
    #expect(await local.started == [first, second])
}

@Test @MainActor func cachedLocalResultIsNotRegeneratedWhenOnlyJevIsMissing() async throws {
    let local = HeldLocalModel()
    await local.release()
    var settings = CategorisationSettings(); settings.jevEnabled = true
    let categoriser = Categoriser(local: { thread, _, _ in try await local.suggest(thread) },
                                  remote: { _, _, _, _ in .noise })
    let model = AppModel(signedIn: true, settings: settings, folder: .inbox,
                         categoriser: categoriser, loadJevToken: { "mock-token" })
    model.demo = true
    defer { model.signOut() }
    // Cache a different thread before selecting it, while a real first thread is processed.
    await model.connect(using: DemoMailService(), persist: false)
    let first = try #require(model.selection)
    try await waitForLatencyTest { !model.suggesting && model.approvalBucket == .noise }
    let id = try #require(model.rows.first { $0.id != first }).id
    let thread = try await DemoMailService().thread(id, full: true)
    model.store.setSuggestion(TriageSuggestion(bucket: .project, nextAction: "", summary: "Cached.", waitingOn: nil),
                              for: thread, prompt: settings.localPrompt)
    model.selection = id
    try await waitForLatencyTest { model.detail?.id == id && model.approvalBucket == .noise && !model.suggesting }
    #expect(model.suggestion?.bucket == .project)
    #expect(await local.started == [first])
}
