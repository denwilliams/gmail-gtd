import Foundation
import Testing
@testable import GmailGTD
@testable import GTDCore

private func summaryThread(_ id: String, messageID: String = "message") throws -> GmailThread {
    let json = """
    {"id":"\(id)","messages":[{"id":"\(messageID)","threadId":"\(id)"}]}
    """
    return try JSONDecoder().decode(GmailThread.self, from: Data(json.utf8))
}

@MainActor private func cacheSummary(_ summary: String, id: String, in model: AppModel) throws {
    model.store.setSuggestion(
        TriageSuggestion(bucket: .nextAction, nextAction: "Reply", summary: summary),
        for: try summaryThread(id), prompt: model.categorisationSettings.localPrompt)
}

@Test @MainActor func todaySummaryUsesTheRequestedThreadAndPreservesFullText() throws {
    let model = AppModel(signedIn: false, settings: CategorisationSettings())
    let summary = "First sentence. More details with *literal markup*.\nA second paragraph."
    try cacheSummary("  \(summary)\n", id: "first", in: model)
    try cacheSummary("A different item's summary.", id: "second", in: model)

    // Today has no selected detail thread; each tooltip must use its own row ID.
    #expect(model.selection == nil)
    #expect(model.nextActionSummary(for: "first") == summary)
    #expect(model.nextActionSummary(for: "second") == "A different item's summary.")
    #expect(model.selection == nil)
    #expect(model.pending.isEmpty)
    #expect(model.inflight.isEmpty)
}

@Test @MainActor func todaySummaryOmitsMissingEmptyAndWhitespaceOnlyText() throws {
    let model = AppModel(signedIn: false, settings: CategorisationSettings())
    try cacheSummary("", id: "empty", in: model)
    try cacheSummary(" \t\n \r\n", id: "blank", in: model)
    #expect(model.nextActionSummary(for: "missing") == nil)
    #expect(model.nextActionSummary(for: "empty") == nil)
    #expect(model.nextActionSummary(for: "blank") == nil)
}

@Test @MainActor func todaySummaryTracksCacheUpdatesAndInvalidation() throws {
    let model = AppModel(signedIn: false, settings: CategorisationSettings())
    try cacheSummary("Original summary.", id: "item", in: model)
    #expect(model.nextActionSummary(for: "item") == "Original summary.")
    try cacheSummary("Updated summary.", id: "item", in: model)
    #expect(model.nextActionSummary(for: "item") == "Updated summary.")

    // A new reply invalidates the summary instead of leaving stale help on the row.
    model.store.note(try summaryThread("item", messageID: "new-reply"), header: nil)
    #expect(model.nextActionSummary(for: "item") == nil)
    try cacheSummary("Summary before prompt change.", id: "item", in: model)
    model.categorisationSettings.localPrompt += " Updated instructions."
    #expect(model.nextActionSummary(for: "item") == nil)
}

@Test @MainActor func todaySummaryDoesNotChangeOpenCompleteOrUndoActions() async throws {
    let model = AppModel(signedIn: true, settings: CategorisationSettings())
    model.demo = true // Never open a browser, persist mail, or clear real credentials.
    defer { model.signOut() }
    await model.connect(using: DemoMailService(), persist: false)
    let row = try #require(model.nextActions.first)
    try cacheSummary("The hovered item's summary.", id: row.id, in: model)
    let otherIDs = model.nextActions.dropFirst().map(\.id)
    #expect(model.nextActionSummary(for: row.id) == "The hovered item's summary.")

    model.openInGmail(row.id)
    #expect(model.notice?.contains("#all/\(row.id)") == true)
    #expect(model.nextActions.first?.id == row.id)
    await model.finish(row)
    #expect(model.nextActions.map(\.id) == otherIDs)
    #expect(model.undoToast?.threadID == row.id)
    #expect(model.undoToast?.destination == .done)
    await model.undoLastMove()
    #expect(model.nextActions.first?.id == row.id)
    #expect(model.nextActionSummary(for: row.id) == "The hovered item's summary.")
}
