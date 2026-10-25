import Foundation
import Testing
@testable import GmailGTD
@testable import GTDCore

private enum CorrectionTestError: Error { case unavailable }

private actor CorrectionMail: MailService {
    let base = DemoMailService()
    private var failNext = false
    private var pauseNext = false
    private(set) var held = false
    private(set) var modifications: [(add: [String], remove: [String])] = []
    private(set) var listings = 0
    func fail() { failNext = true }
    func pause() { pauseNext = true }
    func release() { pauseNext = false }
    func listThreadPage(labelIDs: [String], query: String?, max: Int, pageToken: String?) async throws -> ThreadPage {
        listings += 1
        return try await base.listThreadPage(labelIDs: labelIDs, query: query, max: max, pageToken: pageToken)
    }
    func thread(_ id: String, full: Bool) async throws -> GmailThread { try await base.thread(id, full: full) }
    func labels() async throws -> [GmailLabel] { try await base.labels() }
    func createLabel(_ name: String) async throws -> GmailLabel { try await base.createLabel(name) }
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        if pauseNext {
            held = true
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while pauseNext && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            held = false
        }
        if failNext { failNext = false; throw CorrectionTestError.unavailable }
        try await base.modifyThread(id, add: add, remove: remove)
        modifications.append((add, remove))
    }
    func threadCount(labelID: String) async throws -> Int { try await base.threadCount(labelID: labelID) }
    func emailAddress() async throws -> String { "corrections@example.test" }
}

@MainActor private func correctionEventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await condition()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await condition(), "Timed out waiting for correction state")
}

@MainActor private func correctionFixture(jevEnabled: Bool = false, local: GTDBucket? = .noise,
                                          jev: GTDBucket? = .noise) async throws -> (AppModel, CorrectionMail, String) {
    let mail = CorrectionMail()
    var settings = CategorisationSettings()
    settings.jevEnabled = jevEnabled
    let categoriser = Categoriser(local: { _, _, _ in
        guard let local else { throw CorrectionTestError.unavailable }
        return TriageSuggestion(bucket: local, nextAction: "", summary: "Sample summary")
    }, remote: { _, _, _, _ in
        guard let jev else { throw CorrectionTestError.unavailable }
        return JevClassification(bucket: jev)
    })
    let model = AppModel(signedIn: true, settings: settings, folder: .inbox,
                         categoriser: categoriser, loadJevToken: { "mock-token" })
    model.demo = true // Never touch real credentials or persist private mail.
    await model.connect(using: mail, persist: false)
    let id = try #require(model.selection)
    try await correctionEventually { model.detail?.id == id && !model.isQueued(id) && (local == nil ? model.aiNote != nil : model.suggestion != nil) }
    return (model, mail, id)
}

@Test(arguments: [false, true]) @MainActor func manualMismatchPreservesChoiceTimeSnapshotAcrossLaterPromptEdits(jevEnabled: Bool) async throws {
    let (model, mail, id) = try await correctionFixture(jevEnabled: jevEnabled, local: .reference, jev: .noise)
    defer { model.signOut() }
    let original = model.categorisationSettings
    let originalLabels = try await mail.labels().map(\.name).sorted()
    await mail.pause()
    await model.fileSelected(into: jevEnabled ? .reference : .nextAction)
    try await correctionEventually { await mail.held }
    #expect(model.corrections.records.isEmpty) // Not a completed correction until Gmail succeeds.
    model.categorisationSettings.localPrompt = "A later local prompt."
    model.categorisationSettings.jevPrompt = "A later Jev prompt."
    await mail.release()
    await model.refreshQuietly()
    let record = try #require(model.corrections.records.first)
    #expect(record.threadID == id)
    #expect(record.subject != "(no subject)")
    #expect(!record.from.isEmpty)
    #expect(record.localBucket == .reference)
    #expect(record.jevBucket == (jevEnabled ? .noise : nil))
    #expect(record.localPrompt == original.localPrompt)
    #expect(record.jevPrompt == (jevEnabled ? original.jevPrompt : nil))
    #expect(record.chosenBucket == (jevEnabled ? .reference : .nextAction))
    #expect(try await mail.labels().map(\.name).sorted() == originalLabels)
    let modifications = await mail.modifications
    #expect(modifications.count == 1)
    #expect(modifications[0].add.contains(DemoMailService.labelID(record.chosenBucket)))
    #expect(modifications.flatMap { $0.add + $0.remove }.allSatisfy { $0 == "INBOX" || $0.hasPrefix("Label_") })
    await model.undoLastMove()
    await model.refreshQuietly()
    #expect(model.corrections.records.isEmpty)
}

@Test(arguments: [false, true]) @MainActor func matchingManualChoicesAndApprovalsDoNotCreateCorrections(approve: Bool) async throws {
    let (model, _, _) = try await correctionFixture(jevEnabled: true, local: .reference, jev: .noise)
    defer { model.signOut() }
    if approve { await model.acceptSuggestion() } else { await model.fileSelected(into: .noise) }
    await model.refreshQuietly()
    #expect(model.corrections.records.isEmpty)
    #expect(model.undoStack.count == 1)
}

@Test(arguments: [false, true]) @MainActor func failedMovesLeaveNoCorrectionAndFailedUndoRetainsIt(undo: Bool) async throws {
    let (model, mail, _) = try await correctionFixture()
    defer { model.signOut() }
    if !undo { await mail.fail() }
    await model.fileSelected(into: .reference)
    await model.refreshQuietly()
    if undo {
        #expect(model.corrections.records.count == 1)
        await mail.fail()
        await model.undoLastMove()
        await model.refreshQuietly()
        #expect(model.corrections.records.count == 1)
    } else { #expect(model.corrections.records.isEmpty) }
    #expect(model.error != nil)
}

@Test(arguments: [false, true]) @MainActor func missingLocalOrJevResultsAreNotInvented(localMissing: Bool) async throws {
    let (model, _, _) = try await correctionFixture(jevEnabled: true, local: localMissing ? nil : .noise,
                                                   jev: localMissing ? .noise : nil)
    defer { model.signOut() }
    await model.fileSelected(into: .reference)
    await model.refreshQuietly()
    if localMissing {
        let record = try #require(model.corrections.records.first)
        #expect(record.localBucket == nil)
        #expect(record.localPrompt == nil)
        #expect(record.jevBucket == .noise)
    } else {
        #expect(model.corrections.records.isEmpty) // Jev failure: AFM display fallback isn't an active suggestion.
    }
}

@Test @MainActor func inboxMovesAreNotCorrectionsAndRepeatedThreadChoicesRemainDistinct() async throws {
    let (model, _, id) = try await correctionFixture()
    defer { model.signOut() }
    await model.fileSelected(into: .nextAction)
    await model.refreshQuietly()
    let first = try #require(model.corrections.records.first)
    model.selection = id
    await model.unfileSelected()
    await model.refreshQuietly()
    #expect(model.corrections.records == [first])
    model.selection = id
    await model.fileSelected(into: .reference)
    await model.refreshQuietly()
    #expect(model.corrections.records.count == 2)
    #expect(model.corrections.records.allSatisfy { $0.threadID == id })
    #expect(model.corrections.records.last == first)
    await model.undoLastMove()
    await model.refreshQuietly()
    #expect(model.corrections.records == [first])
}

@Test @MainActor func correctionsNavigationAndRefreshNeverListGmailOrRetainHistoryAfterSignOut() async throws {
    let (model, mail, _) = try await correctionFixture()
    defer { model.demo = true; model.signOut() }
    await model.fileSelected(into: .reference)
    await model.refreshQuietly()
    model.folder = .corrections
    try await correctionEventually { model.selection == nil && model.rows.isEmpty }
    let listings = await mail.listings
    await model.refresh()
    await model.refreshQuietly()
    #expect(await mail.listings == listings)
    #expect(model.detail == nil)
    #expect(model.corrections.records.count == 1)
    model.signOut()
    #expect(model.corrections.records.isEmpty)
}

@Test @MainActor func immediateUndoOfPendingMoveRemovesOnlyItsCompletedCorrection() async throws {
    let (model, mail, id) = try await correctionFixture()
    defer { model.signOut() }
    await mail.pause()
    await model.fileSelected(into: .reference)
    try await correctionEventually { await mail.held }
    await model.undoLastMove()
    #expect(model.corrections.records.isEmpty)
    await mail.release()
    await model.refreshQuietly()
    #expect(model.corrections.records.isEmpty)
    #expect(try await mail.thread(id, full: true).messages?.first?.labelIds?.contains("INBOX") == true)
}

@Test @MainActor func todayCompletionCapturesManualChoiceAndPendingMoveKeepsOriginatingMailbox() async throws {
    let (model, mail, id) = try await correctionFixture()
    defer { model.demo = true; model.signOut() }
    let row = try #require(model.rows.first { $0.id == id })
    let originStore = model.corrections
    await mail.pause()
    await model.finish(row)
    try await correctionEventually { await mail.held }
    model.signOut()
    await mail.release()
    try await correctionEventually { originStore.records.count == 1 }
    #expect(originStore.records.first?.chosenBucket == .done)
    #expect(model.corrections.records.isEmpty)
}
