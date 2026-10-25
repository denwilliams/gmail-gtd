import Foundation
import Testing
@testable import GmailGTD
@testable import GTDCore

private enum ProbeError: Error { case tooManyAttempts }

private actor PlanProbe {
    private(set) var attempts = 0
    private var available = false
    func enable() { available = true }
    func unavailable(_ thread: GmailThread) throws -> ProjectPlan {
        attempts += 1
        if available { return ProjectPlan(summary: "Recovered plan.", steps: ["Draft next step"]) }
        // Bound the buggy implementation too: a regression must fail, not hang CI forever.
        if attempts > 3 { throw ProbeError.tooManyAttempts }
        throw TriageError.modelUnavailable("disabled for test")
    }
}

@MainActor private func eventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for app model")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func unavailableProjectPlanningStopsUntilExplicitRetry() async throws {
    let probe = PlanProbe()
    let model = AppModel(signedIn: true, settings: CategorisationSettings(), folder: .bucket(.project),
                         makePlan: { try await probe.unavailable($0) }, loadJevToken: { nil })
    model.demo = true   // Cleanup must never touch real-account credentials.
    await model.connect(using: DemoMailService(), persist: false)
    try await eventually { model.aiNote != nil && !model.planning }
    let id = try #require(model.selection)
    #expect(await probe.attempts == 1)
    #expect(model.pending.isEmpty)
    #expect(model.store.plan(for: id) == nil)
    #expect(model.aiNote?.contains("disabled for test") == true)

    // Re-enqueue all visible projects, then open another one: unavailable is model-wide.
    for row in model.rows { model.rowAppeared(row.id) }
    model.selection = try #require(model.rows.first { $0.id != id }).id
    try await Task.sleep(for: .milliseconds(450))
    #expect(await probe.attempts == 1)
    #expect(model.pending.isEmpty)
    #expect(!model.planning)
    #expect(model.aiNote?.contains("disabled for test") == true)

    // Both supported explicit recovery paths permit one new attempt, then stop again.
    model.regenerateSelected()
    try await eventually { await probe.attempts >= 2 && !model.planning }
    #expect(await probe.attempts == 2)
    await model.refresh()
    try await eventually { await probe.attempts >= 3 && !model.planning }
    try await Task.sleep(for: .milliseconds(450))
    #expect(await probe.attempts == 3)
    #expect(model.pending.isEmpty)
    #expect(!model.planning)

    // Successful recovery normally plans every visible project; isolate this attempt to the selection.
    for row in model.rows { model.rowDisappeared(row.id) }
    await probe.enable()
    let retryID = try #require(model.selection)
    model.regenerateSelected()
    try await eventually { model.store.plan(for: retryID) != nil && !model.planning }
    #expect(await probe.attempts == 4)
    #expect(model.aiNote == nil)
    model.signOut()
}

@Test @MainActor func localFailureDoesNotHideJevSuccessInFiledTriageFolders() async throws {
    for bucket in [GTDBucket.nextAction, .waitingFor] {
        var settings = CategorisationSettings(); settings.jevEnabled = true
        let categoriser = Categoriser(local: { _, _, _ in
            throw TriageError.modelUnavailable("disabled for test")
        }, remote: { _, _, _, _ in JevClassification(bucket: .project) })
        let model = AppModel(signedIn: true, settings: settings, folder: .bucket(bucket),
                             categoriser: categoriser, loadJevToken: { nil })
        model.demo = true   // Cleanup must never touch real-account credentials.
        await model.connect(using: DemoMailService(), persist: false)
        try await eventually { model.aiNote != nil && model.approvalBucket != nil && !model.suggesting }
        #expect(model.suggestion == nil)
        #expect(model.aiNote?.contains("disabled for test") == true)
        #expect(model.approvalBucket == .project)
        for tab in [DetailTab.original, .summary] {
            model.chooseTab(tab)
            // ThreadDetailView uses this visibility policy above (not inside) either tab.
            #expect(model.showsFiledJevStatus)
            #expect(model.jevStatus?.text == "Jev: Project")
            #expect(model.jevStatus?.bucket == .project)
            #expect(model.jevStatus?.pending == false)
            #expect(model.jevStatus?.failed == false)
        }
        model.categorisationSettings.jevEnabled = false
        #expect(!model.showsFiledJevStatus)
        #expect(model.jevStatus == nil)
        #expect(model.approvalBucket == nil)
        model.signOut()
    }
}

@Test @MainActor func localFailureDoesNotHideJevFailureInFiledTriageFolders() async throws {
    for bucket in [GTDBucket.nextAction, .waitingFor] {
        var settings = CategorisationSettings(); settings.jevEnabled = true
        let categoriser = Categoriser(local: { _, _, _ in
            throw TriageError.modelUnavailable("disabled for test")
        }, remote: { _, _, _, _ in throw ProbeError.tooManyAttempts })
        let model = AppModel(signedIn: true, settings: settings, folder: .bucket(bucket),
                             categoriser: categoriser, loadJevToken: { nil })
        model.demo = true   // Cleanup must never touch real-account credentials.
        await model.connect(using: DemoMailService(), persist: false)
        try await eventually { model.jevStatus?.failed == true && !model.suggesting }
        #expect(model.suggestion == nil)
        #expect(model.showsFiledJevStatus)
        #expect(model.jevStatus?.text.hasPrefix("Jev: ") == true)
        #expect(model.jevStatus?.pending == false)
        #expect(model.approvalBucket == nil)
        model.signOut()
    }
}

@Test(arguments: [true, false], [true, false]) @MainActor
func todayDoneUndoRestoresActualLabels(initiallyInInbox: Bool, immediateUndo: Bool) async throws {
    let demo = DemoMailService()
    let labels = LabelManager(client: demo)
    let ids = try await labels.ensureLabels()
    let custom = try await demo.createLabel("Keep me")
    if initiallyInInbox {
        // Model newly filed actionable mail; the archived case models existing mail with no INBOX.
        try await labels.file(thread: "na01", into: .nextAction)
    }
    try await demo.modifyThread("na01", add: ["UNREAD", "STARRED", custom.id], remove: [])
    let before = try await demo.thread("na01", full: true)
    let beforeMessages = try #require(before.messages)
    #expect(beforeMessages.allSatisfy { ($0.labelIds ?? []).contains("INBOX") == initiallyInInbox })

    let model = AppModel(signedIn: true, settings: CategorisationSettings(), folder: .today,
                         loadJevToken: { nil })
    model.demo = true   // Cleanup must never touch real-account credentials.
    defer { model.signOut() }
    await model.connect(using: demo, persist: false)
    let row = try #require(model.nextActions.first { $0.id == "na01" })
    #expect(model.selection == nil)
    #expect(model.detail == nil)   // Today has no open detail to supply the prior labels.

    await model.finish(row)
    #expect(!model.nextActions.contains { $0.id == row.id })
    #expect(model.undoStack.count == 1)
    if !immediateUndo {
        try await eventually {
            let thread = try? await demo.thread(row.id, full: true)
            return thread?.messages?.allSatisfy { ($0.labelIds ?? []).contains(ids[.done]!) } == true
        }
        let done = try await demo.thread(row.id, full: true)
        #expect(done.messages?.allSatisfy { !($0.labelIds ?? []).contains("INBOX") } == true)
    }
    await model.undoLastMove()
    #expect(model.nextActions.contains { $0.id == row.id })
    #expect(model.undoStack.isEmpty)
    await model.refreshQuietly()   // Wait for the serialized move and undo to reach the backend.

    let after = try await demo.thread(row.id, full: true)
    let afterMessages = try #require(after.messages)
    #expect(afterMessages.map(\.id) == beforeMessages.map(\.id))
    #expect(afterMessages.map(\.plainText) == beforeMessages.map(\.plainText))
    #expect(afterMessages.map { Set($0.labelIds ?? []) } == beforeMessages.map { Set($0.labelIds ?? []) })
    #expect(model.nextActions.contains { $0.id == row.id })
    #expect(model.error == nil)
}

@Test func jevPendingPresentationDoesNotRequireLocalSuccess() {
    let states: [JevState?] = [nil, .pending]
    for state in states {
        let status = JevStatusPresentation(state: state)
        #expect(status.text == "Jev: awaiting categorisation…")
        #expect(status.pending)
        #expect(!status.failed)
        #expect(status.bucket == nil)
    }
}
