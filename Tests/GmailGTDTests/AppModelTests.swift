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
        }, remote: { _, _, _, _ in .project })
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
