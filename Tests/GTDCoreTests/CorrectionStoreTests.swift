import Foundation
import Testing
@testable import GTDCore

private func correction(jevEnabled: Bool = false, local: GTDBucket? = .noise,
                        jev: GTDBucket? = nil, chosen: GTDBucket = .reference,
                        localPrompt: String? = "Bulk notices are noise.", jevPrompt: String? = "Use the latest message.",
                        date: Date = Date()) -> CorrectionRecord? {
    CorrectionRecord.capture(threadID: "thread-1", subject: "Subject", from: "Sender",
                             chosenBucket: chosen, jevEnabled: jevEnabled, localBucket: local, jevBucket: jev,
                             localPrompt: localPrompt, jevPrompt: jevPrompt, recordedAt: date)
}

@Test(arguments: [false, true])
func correctionsFollowActiveApprovalNotFallbackOrOtherModel(jevEnabled: Bool) {
    for local in [GTDBucket.noise, .reference, nil] {
        for jev in [GTDBucket.noise, .reference, nil] {
    let record = correction(jevEnabled: jevEnabled, local: local, jev: jev)
    let active = jevEnabled ? jev : local
    #expect((record != nil) == (active != nil && active != .reference))
    if let record {
        #expect(record.localBucket == local)
        #expect(record.jevBucket == jev)
        #expect(record.activeSource == (jevEnabled ? .jev : .afm))
        #expect(record.chosenBucket == .reference)
        #expect((record.localPrompt != nil) == (local != nil))
        #expect((record.jevPrompt != nil) == (jev != nil))
    }
        }
    }
}

@Test func correctionHypothesisUsesCapturedPromptAndNeverInventsMissingEvidence() throws {
    let record = try #require(correction())
    #expect(record.possibleExplanation.contains("Bulk notices are noise."))
    #expect(record.possibleExplanation.contains("hypothesis"))
    #expect(record.possibleExplanation.contains("not a verified cause"))
    #expect(record.jevBucket == nil)
    #expect(record.jevPrompt == nil)
    let missing = try #require(correction(localPrompt: nil))
    #expect(missing.possibleExplanation.contains("unavailable"))
    #expect(!missing.possibleExplanation.contains("Bulk notices"))
    let blank = try #require(correction(localPrompt: "  "))
    #expect(blank.possibleExplanation.contains("unavailable"))
    let remote = try #require(correction(jevEnabled: true, local: nil, jev: .noise))
    #expect(remote.possibleExplanation.contains("Use the latest message."))
    #expect(remote.localPrompt == nil)
}

@Test @MainActor func correctionHistoryPersistsImmutableDistinctEventsAndUndoAcrossRestart() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try #require(CorrectionStore.fileURL(for: "one@example.test", directory: directory))
    let other = try #require(CorrectionStore.fileURL(for: "two@example.test", directory: directory))
    #expect(url != other)
    #expect(CorrectionStore.fileURL(for: " ONE@example.test ", directory: directory) == url)
    #expect(CorrectionStore.fileURL(for: " ", directory: directory) == nil)
    let first = try #require(correction(date: Date(timeIntervalSince1970: 100)))
    let second = try #require(correction(chosen: .nextAction, localPrompt: "Changed prompt.", date: Date(timeIntervalSince1970: 200)))
    let store = CorrectionStore(fileURL: url)
    store.append(first)
    store.append(second)
    store.append(first) // Repeated completion cannot duplicate an event.
    #expect(store.records == [second, first])
    #expect(store.persistenceError == nil)
    let restarted = CorrectionStore(fileURL: url)
    #expect(restarted.records == [second, first])
    #expect(restarted.records.last?.localPrompt == "Bulk notices are noise.")
    #expect(CorrectionStore(fileURL: other).records.isEmpty)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    restarted.remove(id: second.id)
    #expect(CorrectionStore(fileURL: url).records == [first])
    // A new in-memory/demo store neither loads nor changes persisted mailbox history.
    let demo = CorrectionStore()
    demo.append(second)
    #expect(CorrectionStore(fileURL: url).records == [first])
}

@Test @MainActor func correctionDiskFailuresRemainVisibleAndDoNotOverwriteUnreadableHistory() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "history.json")
    let corrupt = Data("not JSON".utf8)
    try corrupt.write(to: url)
    let unreadable = CorrectionStore(fileURL: url)
    #expect(unreadable.persistenceError != nil)
    let event = try #require(correction())
    unreadable.append(event)
    #expect(unreadable.records == [event])
    #expect(try Data(contentsOf: url) == corrupt)
    // A regular file cannot be the destination's parent directory.
    let unavailable = CorrectionStore(fileURL: url.appending(path: "history.json"))
    unavailable.append(event)
    #expect(unavailable.records == [event])
    #expect(unavailable.persistenceError != nil)
    unavailable.remove(id: event.id)
    #expect(unavailable.records.isEmpty)
}
