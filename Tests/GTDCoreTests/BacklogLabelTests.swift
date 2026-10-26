import Foundation
import Testing
@testable import GTDCore

@Test(arguments: GTDBucket.allCases)
func backlogFilingClearsQueueAndUndoRestoresExactArchivedLabels(bucket: GTDBucket) async throws {
    let service = DemoMailService()
    let manager = LabelManager(client: service)
    let ids = try await manager.ensureLabels()
    let backlog = try await service.createLabel(LabelManager.backlogLabelName)
    let unrelated = try await service.createLabel("Keep me")
    let oldBucket: GTDBucket = bucket == .reference ? .noise : .reference
    try await service.modifyThread("in01", add: [backlog.id, unrelated.id, "STARRED", ids[oldBucket]!], remove: ["INBOX"])
    let before = try await service.thread("in01", full: true)
    let beforeLabels = try #require(before.messages?.last?.labelIds)
    let snapshot = try await manager.managedLabels(in: beforeLabels)
    #expect(snapshot == [backlog.id, ids[oldBucket]!])
    #expect(await manager.bucket(for: [backlog.id]) == nil) // Not a GTD destination.
    let mappings: [Character: GTDBucket] = ["1": .nextAction, "2": .waitingFor, "3": .someday,
                                           "4": .reference, "5": .project, "6": .noise, "7": .done]
    #expect(mappings[bucket.shortcut] == bucket)

    try await manager.file(thread: "in01", into: bucket)
    let after = try await service.thread("in01", full: true)
    var expected: Set<String> = [unrelated.id, "STARRED", "UNREAD", ids[bucket]!]
    if [GTDBucket.nextAction, .waitingFor, .someday].contains(bucket) { expected.insert("INBOX") }
    #expect(after.messages?.allSatisfy { Set($0.labelIds ?? []) == expected } == true)
    #expect(try await service.listThreads(labelIDs: [backlog.id], max: 50).isEmpty)
    #expect(after.messages?.map(\.plainText) == before.messages?.map(\.plainText))

    try await manager.restore(thread: "in01", to: snapshot)
    let undone = try await service.thread("in01", full: true)
    #expect(undone.messages?.map { Set($0.labelIds ?? []) } == before.messages?.map { Set($0.labelIds ?? []) })
}

@Test func backlogLookupNeverCreatesOrFilesMail() async throws {
    let service = DemoMailService()
    let manager = LabelManager(client: service)
    #expect(try await manager.backlogLabelID() == nil)
    #expect(try await service.labels().allSatisfy { $0.name != LabelManager.backlogLabelName })
    let created = try await service.createLabel(LabelManager.backlogLabelName)
    #expect(try await manager.backlogLabelID() == created.id)
    #expect(try await service.threadCount(labelID: created.id) == 0)
    #expect(try await service.threadCount(labelID: "INBOX") == 20)
}


@Test func backlogLabelLivesUnderGTDAndAPlainBacklogLabelIsIgnored() async throws {
    #expect(LabelManager.backlogLabelName == "GTD/Backlog")
    let service = DemoMailService()
    let manager = LabelManager(client: service)
    _ = try await service.createLabel("Backlog")                      // the old, un-nested name
    #expect(try await manager.backlogLabelID() == nil)
    let nested = try await service.createLabel("GTD/Backlog")
    #expect(try await manager.backlogLabelID() == nested.id)
}
