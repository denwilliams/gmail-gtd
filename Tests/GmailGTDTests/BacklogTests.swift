import Foundation
import Testing
@testable import GmailGTD
@testable import GTDCore

private enum BacklogTestError: Error { case refused }

private actor BacklogProbe: MailService {
    let base = DemoMailService()
    private(set) var writes = 0
    private(set) var requestedLabels: [[String]] = []
    var refuseWrites = false

    func setRefuseWrites() { refuseWrites = true }
    func listThreadPage(labelIDs: [String], query: String?, max: Int, pageToken: String?) async throws -> ThreadPage {
        requestedLabels.append(labelIDs)
        return try await base.listThreadPage(labelIDs: labelIDs, query: query, max: max, pageToken: pageToken)
    }
    func thread(_ id: String, full: Bool) async throws -> GmailThread { try await base.thread(id, full: full) }
    func labels() async throws -> [GmailLabel] { try await base.labels() }
    func createLabel(_ name: String) async throws -> GmailLabel { try await base.createLabel(name) }
    func threadCount(labelID: String) async throws -> Int { try await base.threadCount(labelID: labelID) }
    func emailAddress() async throws -> String { try await base.emailAddress() }
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        writes += 1
        if refuseWrites { throw BacklogTestError.refused }
        try await base.modifyThread(id, add: add, remove: remove)
    }
}

@MainActor private func backlogEventually(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition(), "Timed out waiting for Backlog")
}

@MainActor private func backlogModel(using service: any MailService) async -> AppModel {
    var settings = CategorisationSettings(); settings.jevEnabled = false
    let model = AppModel(signedIn: true, settings: settings, folder: .backlog,
                         categoriser: Categoriser(local: { _, _, _ in
        TriageSuggestion(bucket: .reference, nextAction: "", summary: "Saved information.")
    }), loadJevToken: { nil })
    model.demo = true
    await model.connect(using: service, persist: false)
    return model
}

@Test @MainActor func missingBacklogIsEmptyAndAppearsAfterCreationAndRefresh() async throws {
    let service = BacklogProbe()
    let model = await backlogModel(using: service)
    defer { model.signOut() }
    #expect(model.rows.isEmpty)
    #expect(model.selection == nil)
    #expect(model.error == nil)
    #expect(await service.requestedLabels.isEmpty) // No all-mail fallback for a missing label.
    #expect(try await service.labels().allSatisfy { $0.name != LabelManager.backlogLabelName })

    let backlog = try await service.createLabel(LabelManager.backlogLabelName)
    try await service.base.modifyThread("in01", add: [backlog.id], remove: ["INBOX"])
    await model.refresh()
    try await backlogEventually { model.detail?.id == "in01" && model.suggestion != nil }
    #expect(model.rows.map(\.id) == ["in01"])
    #expect(model.approvalBucket == .reference)
    #expect(model.folder.isTriage)
    #expect(!model.canStartDeNoiseMode)
    #expect(await service.writes == 0)
}

@Test @MainActor func backlogListsArchivedMailPagesWithoutRestoringInbox() async throws {
    let service = BacklogProbe()
    let backlog = try await service.createLabel(LabelManager.backlogLabelName)
    let refs = try await service.base.listThreads(labelIDs: ["INBOX"], max: 50)
    let oldIDs = Array(refs.prefix(10).map(\.id))
    for id in oldIDs {
        try await service.base.modifyThread(id, add: [backlog.id], remove: ["INBOX"])
    }
    let beforeInbox = try await service.base.threadCount(labelID: "INBOX")
    let model = await backlogModel(using: service)
    defer { model.signOut() }
    #expect(model.rows.count == 8)
    #expect(model.hasMore)
    await model.loadMore()
    #expect(model.rows.map(\.id) == oldIDs)
    #expect(!model.hasMore)
    try await backlogEventually { model.detail?.id == model.selection && model.suggestion != nil }
    await model.refreshQuietly()
    #expect(await service.writes == 0)
    #expect(await service.requestedLabels.allSatisfy { $0 == [backlog.id] })
    #expect(try await service.base.threadCount(labelID: "INBOX") == beforeInbox)

    model.folder = .inbox
    try await backlogEventually { !model.rows.isEmpty && model.rows.allSatisfy { !oldIDs.contains($0.id) } }
    #expect(model.rows.allSatisfy { !oldIDs.contains($0.id) })
    #expect(await service.writes == 0)
    for id in oldIDs {
        let thread = try await service.thread(id, full: true)
        #expect(thread.messages?.allSatisfy { ($0.labelIds ?? []).contains(backlog.id) && !($0.labelIds ?? []).contains("INBOX") } == true)
    }
}

@Test @MainActor func failedBacklogFilingRestoresRowAndKeepsLabels() async throws {
    let service = BacklogProbe()
    let backlog = try await service.createLabel(LabelManager.backlogLabelName)
    try await service.base.modifyThread("in01", add: [backlog.id], remove: ["INBOX"])
    let before = try await service.thread("in01", full: true)
    let model = await backlogModel(using: service)
    defer { model.signOut() }
    try await backlogEventually { model.detail?.id == "in01" }
    await service.setRefuseWrites()
    await model.fileSelected(into: .noise)
    await model.refreshQuietly()
    #expect(model.rows.map(\.id) == ["in01"])
    #expect(model.selection == "in01")
    #expect(model.undoStack.isEmpty)
    #expect(model.error?.contains("move") == true)
    let after = try await service.thread("in01", full: true)
    #expect(after.messages?.map { Set($0.labelIds ?? []) } == before.messages?.map { Set($0.labelIds ?? []) })
}
