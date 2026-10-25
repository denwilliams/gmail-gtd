import Foundation
import Testing
@testable import GmailGTD
@testable import GTDCore

private enum DeNoiseTestError: Error { case unavailable }

/// Real demo filing semantics, with observable writes and a one-shot failure injection.
private actor DeNoiseMail: MailService {
    let base = DemoMailService()
    private var failNext: Set<String> = []
    private(set) var writes: [String] = []
    private var holdListing = false
    private(set) var listingHeld = false
    func pauseListing() { holdListing = true }
    func releaseListing() { holdListing = false }

    func prepare() async throws {
        let labels = LabelManager(client: base)
        for ref in try await base.listThreads(labelIDs: [], max: 100) {
            try await labels.unfile(thread: ref.id)
        }
    }
    func fail(_ id: String) { failNext.insert(id) }
    func listThreadPage(labelIDs: [String], query: String?, max: Int, pageToken: String?) async throws -> ThreadPage {
        if holdListing {
            listingHeld = true
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while holdListing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            listingHeld = false
        }
        return try await base.listThreadPage(labelIDs: labelIDs, query: query, max: max, pageToken: pageToken)
    }
    func thread(_ id: String, full: Bool) async throws -> GmailThread { try await base.thread(id, full: full) }
    func labels() async throws -> [GmailLabel] { try await base.labels() }
    func createLabel(_ name: String) async throws -> GmailLabel { try await base.createLabel(name) }
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        if failNext.remove(id) != nil { throw DeNoiseTestError.unavailable }
        try await base.modifyThread(id, add: add, remove: remove)
        writes.append(id)
    }
    func threadCount(labelID: String) async throws -> Int { try await base.threadCount(labelID: labelID) }
    func emailAddress() async throws -> String { try await base.emailAddress() }
    func labelSet(_ id: String) async throws -> Set<String> {
        Set(try await base.thread(id, full: true).messages?.flatMap { $0.labelIds ?? [] } ?? [])
    }
}

private actor DeNoiseRemote {
    private var held: Bool
    let result: GTDBucket?
    private(set) var calls = 0
    init(result: GTDBucket?, held: Bool = false) { self.result = result; self.held = held }
    func release() { held = false }
    func classify() async throws -> GTDBucket {
        calls += 1
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while held && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard let result else { throw DeNoiseTestError.unavailable }
        return result
    }
}

@MainActor private func deNoiseEventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await condition()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await condition(), "Timed out waiting for De-noise state")
}

@MainActor private func deNoiseFixture(remote: DeNoiseRemote? = nil, localBucket: GTDBucket = .noise) async throws -> (AppModel, DeNoiseMail) {
    let mail = DeNoiseMail()
    try await mail.prepare()
    var settings = CategorisationSettings(); settings.jevEnabled = remote != nil
    let categoriser = Categoriser(local: { _, _, _ in throw DeNoiseTestError.unavailable },
                                  remote: { _, _, _, _ in
        guard let remote else { throw DeNoiseTestError.unavailable }
        return try await remote.classify()
    })
    let model = AppModel(signedIn: true, settings: settings, folder: .inbox,
                         categoriser: categoriser, loadJevToken: { "mock-token" })
    model.demo = true   // Never use real credentials or persist private state.
    await model.connect(using: mail, persist: false)
    while model.hasMore { await model.loadMore() }
    // Simulate already loaded/classified inbox rows without invoking Apple Intelligence.
    var loaded: [ThreadRow] = []
    for row in model.rows {
        let thread = try await mail.thread(row.id, full: true)
        let last = try #require(thread.messages?.last)
        model.store.note(thread, header: nil)
        model.store.setSuggestion(TriageSuggestion(bucket: localBucket, nextAction: "", summary: "A newsletter."),
                                  for: thread, prompt: settings.localPrompt)
        loaded.append(ThreadRow(id: row.id, subject: last.subject, from: last.from,
                                snippet: row.snippet, date: last.date, unread: last.isUnread))
    }
    model.rows = loaded
    #expect(model.rows.count > 10)
    return (model, mail)
}

@Test @MainActor func deNoiseEligibilityRequiresTenReadyLoadedInboxThreads() async throws {
    let (model, _) = try await deNoiseFixture()
    defer { model.signOut() }
    let all = model.rows
    model.rows = Array(all.prefix(9))
    #expect(!model.canStartDeNoiseMode)
    model.startDeNoiseMode()
    #expect(model.deNoiseBatch == nil)
    model.rows.append(all[0])   // Duplicate rows are not extra eligible emails.
    #expect(!model.canStartDeNoiseMode)
    model.rows = Array(all.prefix(10))
    model.rows[9].loaded = false
    #expect(!model.canStartDeNoiseMode)
    model.rows = all
    model.store.clearSuggestion(for: all[0].id)
    #expect(!model.deNoiseEligibleRows.contains { $0.id == all[0].id })
    let expected = Array(all.dropFirst().prefix(10))
    #expect(model.canStartDeNoiseMode)
    model.startDeNoiseMode()
    let batch = try #require(model.deNoiseBatch)
    #expect(batch.rows == expected)
    model.startDeNoiseMode()
    #expect(model.deNoiseBatch?.id == batch.id)
    #expect(!model.canStartDeNoiseMode)
}

@Test(arguments: [GTDBucket.noise, .reference, nil]) @MainActor
func deNoiseEligibilityFollowsJevApprovalNotLocalDisplayFallback(result: GTDBucket?) async throws {
    let remote = DeNoiseRemote(result: result)
    let (model, _) = try await deNoiseFixture(remote: remote, localBucket: result == .noise ? .reference : .noise)
    defer { model.signOut() }
    for row in model.rows { model.rowAppeared(row.id) }
    let count = model.rows.count
    try await deNoiseEventually { await remote.calls == count && model.rows.allSatisfy { !model.isQueued($0.id) } }
    #expect(model.canStartDeNoiseMode == (result == .noise))
    #expect(model.deNoiseEligibleRows.count == (result == .noise ? count : 0))
    if result == nil { #expect(model.inboxBucket(for: model.rows[0].id) == .noise) }
}

@Test @MainActor func deNoiseJevPendingCannotApproveLocalNoise() async throws {
    let remote = DeNoiseRemote(result: .noise, held: true)
    let (model, _) = try await deNoiseFixture(remote: remote)
    defer { model.signOut() }
    for row in model.rows { model.rowAppeared(row.id) }
    try await deNoiseEventually { await remote.calls > 0 }
    #expect(model.deNoiseEligibleRows.isEmpty)
    model.startDeNoiseMode()
    #expect(model.deNoiseBatch == nil)
    await remote.release()
    try await deNoiseEventually { model.canStartDeNoiseMode }
}

@Test(arguments: GTDBucket.allCases.filter { $0 != .noise }) @MainActor
func deNoiseCorrectionsShrinkAndLGTMFilesOnlyRemainingSnapshot(bucket: GTDBucket) async throws {
    let (model, mail) = try await deNoiseFixture()
    defer { model.signOut() }
    let all = model.rows
    model.rows = Array(all.prefix(10))
    model.startDeNoiseMode()
    let batch = try #require(model.deNoiseBatch)
    model.rows += all.dropFirst(10)   // Newly loaded eligible rows must not join this review.
    let corrected = batch.rows[0]
    let outsiders = model.rows.filter { row in !batch.rows.contains { $0.id == row.id } }
    model.beginDeNoiseCorrection(for: outsiders[0].id)
    #expect(model.deNoiseCorrection == nil)
    model.beginDeNoiseCorrection(for: corrected.id)
    let cancelled = try #require(model.deNoiseCorrection)
    #expect(!model.canApproveDeNoiseBatch)
    model.approveDeNoiseBatch(batch.id)   // LGTM cannot bypass an open correction modal.
    #expect(model.undoStack.isEmpty)
    model.cancelDeNoiseCorrection()
    #expect(model.deNoiseBatch?.rows == batch.rows)
    #expect(await mail.writes.isEmpty)
    model.beginDeNoiseCorrection(for: corrected.id)
    let correction = try #require(model.deNoiseCorrection)
    model.confirmDeNoiseCorrection(bucket, correctionID: cancelled.id)   // Stale modal action.
    model.confirmDeNoiseCorrection(.noise, correctionID: correction.id)
    #expect(model.deNoiseBatch?.rows.count == 10)
    model.confirmDeNoiseCorrection(bucket, correctionID: correction.id)
    model.confirmDeNoiseCorrection(bucket, correctionID: correction.id)   // Double click.
    #expect(model.deNoiseCorrection == nil)
    #expect(model.deNoiseBatch?.rows == Array(batch.rows.dropFirst()))
    #expect(model.undoStack.count == 1)
    await model.refreshQuietly()   // Also waits for the serialized correction to reach the backend.
    #expect(model.deNoiseBatch?.id == batch.id)   // Quiet refresh must not replace reviewed members.
    let labels = try await mail.labelSet(corrected.id)
    #expect(labels.contains(DemoMailService.labelID(bucket)))
    #expect(!labels.contains(DemoMailService.labelID(.noise)))
    #expect(labels.contains("INBOX") == [GTDBucket.nextAction, .waitingFor, .someday].contains(bucket))

    model.selection = outsiders[0].id   // LGTM must not use selection.
    await model.fileSelected(into: .noise)   // Ordinary shortcuts are suppressed during review.
    #expect(model.undoStack.count == 1)
    model.approveDeNoiseBatch(batch.id)
    model.approveDeNoiseBatch(batch.id)
    #expect(model.deNoiseBatch == nil)
    #expect(model.undoStack.count == 10)
    await model.refreshQuietly()
    #expect(try await mail.labelSet(corrected.id) == labels)
    for row in batch.rows.dropFirst() {
        let labels = try await mail.labelSet(row.id)
        #expect(labels.contains(DemoMailService.labelID(.noise)))
        #expect(!labels.contains("INBOX"))
    }
    for row in outsiders { #expect(try await mail.labelSet(row.id) == Set(["INBOX"] + (row.unread ? ["UNREAD"] : []))) }
    #expect(await mail.writes.count == 10)

    // LGTM uses the same per-thread undo snapshots, including the original INBOX label.
    let last = try #require(model.undoStack.last)
    await model.undoLastMove()
    await model.refreshQuietly()
    let restored = try await mail.labelSet(last.threadID)
    #expect(restored.contains("INBOX"))
    #expect(!restored.contains(DemoMailService.labelID(.noise)))
}

@Test @MainActor func deNoiseAllCorrectedHasNoActionableLGTM() async throws {
    let (model, mail) = try await deNoiseFixture()
    defer { model.signOut() }
    model.startDeNoiseMode()
    let batch = try #require(model.deNoiseBatch)
    for row in batch.rows {
        model.beginDeNoiseCorrection(for: row.id)
        let correction = try #require(model.deNoiseCorrection)
        model.confirmDeNoiseCorrection(.reference, correctionID: correction.id)
    }
    #expect(model.deNoiseBatch?.rows.isEmpty == true)
    #expect(!model.canApproveDeNoiseBatch)
    model.approveDeNoiseBatch(batch.id)
    await model.refreshQuietly()
    #expect(await mail.writes.count == 10)
    for row in batch.rows { #expect(try await mail.labelSet(row.id).contains(DemoMailService.labelID(.reference))) }
}

@Test(arguments: [true, false]) @MainActor func deNoiseFailedFilingRestoresEmailAndReportsError(correction: Bool) async throws {
    let (model, mail) = try await deNoiseFixture()
    defer { model.signOut() }
    model.startDeNoiseMode()
    let batch = try #require(model.deNoiseBatch)
    let failed = batch.rows[0]
    await mail.fail(failed.id)
    if correction {
        model.beginDeNoiseCorrection(for: failed.id)
        let modal = try #require(model.deNoiseCorrection)
        model.confirmDeNoiseCorrection(.reference, correctionID: modal.id)
    } else { model.approveDeNoiseBatch(batch.id) }
    await model.refreshQuietly()
    #expect(model.deNoiseBatch == nil)
    #expect(model.deNoiseCorrection == nil)
    #expect(model.error?.contains("Couldn’t move") == true)
    #expect(model.rows.contains { $0.id == failed.id })
    #expect(try await mail.labelSet(failed.id).contains("INBOX"))
    #expect(!model.undoStack.contains { $0.threadID == failed.id })
    #expect(await mail.writes.count == (correction ? 0 : 9))
}

@Test(arguments: ["navigation", "refresh", "settings", "settings-open", "undo", "signout", "leave"]) @MainActor
func deNoiseContextChangesInvalidateStaleActions(change: String) async throws {
    let (model, mail) = try await deNoiseFixture()
    defer { model.demo = true; model.signOut() }
    model.startDeNoiseMode()
    let batch = try #require(model.deNoiseBatch)
    model.beginDeNoiseCorrection(for: batch.rows[0].id)
    let correction = try #require(model.deNoiseCorrection)
    switch change {
    case "navigation": model.folder = .bucket(.reference)
    case "refresh": await model.refresh()
    case "settings": model.categorisationSettings.jevEnabled = true
    case "settings-open": model.showingCategorisationSettings = true
    case "undo": await model.undoLastMove()
    case "signout": model.signOut()
    default: model.endDeNoiseMode()
    }
    #expect(model.deNoiseBatch == nil)
    #expect(model.deNoiseCorrection == nil)
    model.confirmDeNoiseCorrection(.reference, correctionID: correction.id)
    model.approveDeNoiseBatch(batch.id)
    #expect(await mail.writes.isEmpty)
}

@Test @MainActor func deNoiseInFlightQuietRefreshCannotReplaceReviewedInbox() async throws {
    let (model, mail) = try await deNoiseFixture()
    defer { model.signOut() }
    model.rows = Array(model.rows.prefix(16))   // Within the quiet-refresh paging threshold.
    let before = model.rows
    await mail.pauseListing()
    let refresh = Task { await model.refreshQuietly() }
    try await deNoiseEventually { await mail.listingHeld }
    model.startDeNoiseMode()
    let batch = try #require(model.deNoiseBatch)
    await mail.releaseListing()
    await refresh.value
    #expect(model.rows == before)
    #expect(model.deNoiseBatch?.rows == batch.rows)
    #expect(model.canApproveDeNoiseBatch)
    #expect(await mail.writes.isEmpty)
}

@Test @MainActor func deNoiseOldBatchCannotApproveNewSessionOrMissingMember() async throws {
    let (model, mail) = try await deNoiseFixture()
    defer { model.signOut() }
    model.startDeNoiseMode()
    let old = try #require(model.deNoiseBatch)
    model.endDeNoiseMode()
    model.startDeNoiseMode()
    let current = try #require(model.deNoiseBatch)
    model.approveDeNoiseBatch(old.id)
    #expect(model.deNoiseBatch?.id == current.id)
    model.rows.removeAll { $0.id == current.rows[0].id }
    #expect(!model.canApproveDeNoiseBatch)
    model.approveDeNoiseBatch(current.id)
    #expect(model.deNoiseBatch == nil)
    #expect(await mail.writes.isEmpty)
}
