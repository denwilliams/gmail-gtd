import Foundation
import Testing
@testable import GmailGTD
@testable import GTDCore

@MainActor private func refreshEventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await condition()) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await condition(), "Timed out waiting for foreground refresh")
}

/// A virtual clock: tests advance foreground/background minutes without real delays.
@MainActor private final class RefreshClock {
    private var now: Duration = .zero
    private var waits: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    var waiting: Int { waits.count }
    private(set) var intervals: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        intervals.append(duration)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waits[id] = (now + duration, continuation)
            }
        } onCancel: {
            Task { @MainActor in
                self.waits.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
            }
        }
    }

    func advance(_ duration: Duration) {
        now += duration
        let due = waits.filter { $0.value.0 <= now }.map(\.key)
        for id in due { waits.removeValue(forKey: id)?.1.resume() }
    }
}

@Test @MainActor func activationRefreshesAndForegroundTimerRunsEveryTenMinutes() async throws {
    let clock = RefreshClock()
    var calls = 0
    let refresh = ForegroundMailRefresh(refresh: { calls += 1 }, sleep: { try await clock.sleep($0) })
    defer { refresh.setActive(false) }
    refresh.setActive(true)
    try await refreshEventually { calls == 1 && clock.waiting == 1 }
    #expect(clock.intervals == [.seconds(600)])
    // Repeated active notifications must not refresh or create another timer.
    refresh.setActive(true)
    clock.advance(.seconds(599))
    #expect(calls == 1)
    #expect(clock.waiting == 1)
    clock.advance(.seconds(1))
    try await refreshEventually { calls == 2 && clock.waiting == 1 }
    clock.advance(.seconds(600))
    try await refreshEventually { calls == 3 && clock.waiting == 1 }

    refresh.setActive(false)
    try await refreshEventually { clock.waiting == 0 }
    clock.advance(.seconds(1800))
    #expect(calls == 3)
    refresh.setActive(true)
    try await refreshEventually { calls == 4 && clock.waiting == 1 }
    #expect(clock.intervals.allSatisfy { $0 == .seconds(600) })
}

@Test @MainActor func rapidReactivationDoesNotResurrectCancelledTimers() async throws {
    let clock = RefreshClock()
    var calls = 0
    let refresh = ForegroundMailRefresh(refresh: { calls += 1 }, sleep: { try await clock.sleep($0) })
    defer { refresh.setActive(false) }
    refresh.setActive(true)
    try await refreshEventually { calls == 1 && clock.waiting == 1 }
    refresh.setActive(false)
    refresh.setActive(true)
    try await refreshEventually { calls == 2 && clock.waiting == 1 }
    clock.advance(.seconds(600))
    try await refreshEventually { calls == 3 && clock.waiting == 1 }
}

private enum RefreshTestError: Error { case unavailable }

private actor RefreshMail: MailService {
    let base = DemoMailService()
    private var ids = ["in01", "in02"]
    private var held = false
    private var shouldFail = false
    private var heldMove = false
    private var replies: Set<String> = []
    private(set) var moves = 0
    private(set) var threadCalls: [String: Int] = [:]
    private var inflight = 0
    private(set) var calls = 0
    private(set) var maxInflight = 0
    private(set) var requestedMax: [Int] = []
    func arrive(_ id: String) { ids.insert(id, at: 0) }
    func useIDs(_ ids: [String]) { self.ids = ids }
    func hold() { held = true }
    func release() { held = false }
    func failNext() { shouldFail = true }
    func holdMoves() { heldMove = true }
    func releaseMoves() { heldMove = false }
    func reply(to id: String) { replies.insert(id) }

    func listThreadPage(labelIDs: [String], query: String?, max: Int, pageToken: String?) async throws -> ThreadPage {
        calls += 1
        requestedMax.append(max)
        inflight += 1
        maxInflight = Swift.max(maxInflight, inflight)
        defer { inflight -= 1 }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while held && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if shouldFail { shouldFail = false; throw RefreshTestError.unavailable }
        let start = pageToken.flatMap(Int.init) ?? 0
        let page = Array(ids.dropFirst(start).prefix(max))
        return ThreadPage(refs: page.map {
            ThreadRef(id: $0, snippet: replies.contains($0) ? "Reply \($0)" : "Mail \($0)",
                      historyId: replies.contains($0) ? "2" : "1")
        },
                          nextPageToken: start + page.count < ids.count ? String(start + page.count) : nil)
    }
    func thread(_ id: String, full: Bool) async throws -> GmailThread {
        threadCalls[id, default: 0] += 1
        let original = try await base.thread(id, full: full)
        guard replies.contains(id) else {
            return GmailThread(id: id, historyId: "1", messages: original.messages)
        }
        let reply = GmailMessage(id: "\(id)-reply", threadId: id, labelIds: ["INBOX", "UNREAD"],
                                 snippet: "Reply \(id)", internalDate: "1800000000000",
                                 payload: .init(mimeType: "text/plain",
                                                headers: [.init(name: "Subject", value: "Reply subject \(id)"),
                                                          .init(name: "From", value: "Reply sender <reply@example.com>")],
                                                body: nil, parts: nil))
        return GmailThread(id: id, historyId: "2", messages: (original.messages ?? []) + [reply])
    }
    func labels() async throws -> [GmailLabel] { try await base.labels() }
    func createLabel(_ name: String) async throws -> GmailLabel { try await base.createLabel(name) }
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        moves += 1
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while heldMove && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await base.modifyThread(id, add: add, remove: remove)
        if remove.contains("INBOX") { ids.removeAll { $0 == id } }
    }
    func threadCount(labelID: String) async throws -> Int { try await base.threadCount(labelID: labelID) }
    func emailAddress() async throws -> String { try await base.emailAddress() }
}

@MainActor private func refreshFixture(_ mail: RefreshMail) async -> AppModel {
    let model = AppModel(signedIn: true, settings: CategorisationSettings(), folder: .inbox,
                         categoriser: Categoriser(local: { _, _, _ in throw RefreshTestError.unavailable }),
                         loadJevToken: { nil })
    model.demo = true
    await model.connect(using: mail, persist: false)
    return model
}

@Test @MainActor func appActivationBypassesListTTLAndShowsArrivalsWithoutChangingSelection() async throws {
    let mail = RefreshMail()
    let model = await refreshFixture(mail)
    defer { model.setAppActive(false); model.signOut() }
    let selection = try #require(model.selection)
    #expect(await mail.calls == 1)
    await mail.arrive("in03")
    model.setAppActive(true)
    try await refreshEventually { model.rows.first?.id == "in03" }
    #expect(await mail.calls == 2)
    #expect(model.selection == selection)
    model.setAppActive(false)
    await mail.arrive("in04")
    model.setAppActive(true)
    try await refreshEventually { model.rows.first?.id == "in04" }
    #expect(await mail.calls == 3)
    #expect(model.selection == selection)
}

@Test @MainActor func automaticQuietAndManualRefreshesDoNotOverlapAndRetryAfterFailure() async throws {
    let mail = RefreshMail()
    let model = await refreshFixture(mail)
    defer { model.setAppActive(false); model.signOut() }
    await mail.arrive("in03")
    await mail.hold()
    model.setAppActive(true)
    try await refreshEventually { await mail.calls == 2 }
    await model.refresh()
    await model.refreshQuietly()
    await model.refreshQuietly(force: true)
    #expect(await mail.calls == 2)
    #expect(await mail.maxInflight == 1)
    await mail.release()
    // Waiting for the result to be applied also proves the refresh lock has been released.
    try await refreshEventually { model.rows.first?.id == "in03" }
    model.setAppActive(false)
    try await Task.sleep(for: .milliseconds(30))
    await mail.failNext()
    model.setAppActive(true)
    try await refreshEventually { await mail.calls == 3 }
    try await Task.sleep(for: .milliseconds(30))
    #expect(model.rows.count == 3)
    #expect(model.error == nil) // Automatic failures should not interrupt the user.
    await mail.arrive("in04")
    model.setAppActive(false)
    model.setAppActive(true)
    try await refreshEventually { model.rows.first?.id == "in04" }
    #expect(await mail.calls == 4)
    #expect(await mail.maxInflight == 1)
}

@Test @MainActor func activationDoesNotOverlapManualRefreshOrRunWhileSignedOut() async throws {
    let mail = RefreshMail()
    let model = await refreshFixture(mail)
    defer { model.setAppActive(false); model.signOut() }
    await mail.hold()
    let manual = Task { await model.refresh() }
    try await refreshEventually { await mail.calls == 2 }
    model.setAppActive(true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await mail.calls == 2)
    await mail.release()
    await manual.value
    model.signOut()
    model.setAppActive(false)
    model.setAppActive(true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await mail.calls == 2)
    #expect(model.rows.isEmpty)
}

@Test @MainActor func arrivalDoesNotDisplaceSelectionAtFirstPageBoundary() async throws {
    let mail = RefreshMail()
    await mail.useIDs((1...8).map { String(format: "in%02d", $0) })
    let model = await refreshFixture(mail)
    defer { model.setAppActive(false); model.signOut() }
    model.selection = "in08"
    await mail.arrive("in09")
    model.setAppActive(true)
    try await refreshEventually { model.rows.first?.id == "in09" }
    #expect(model.selection == "in08")
    #expect(model.rows.count == 9)
    model.setAppActive(false)
    await mail.arrive("in10")
    await model.refreshQuietly(force: true)
    #expect(await mail.calls == 2)
    #expect(model.rows.first?.id == "in09")
}

@Test @MainActor func activationRefreshRetainsPaginatedTailAndDeduplicatesFurtherPages() async throws {
    let mail = RefreshMail()
    await mail.useIDs((1...20).map { String(format: "in%02d", $0) })
    let model = await refreshFixture(mail)
    defer { model.setAppActive(false); model.signOut() }
    await model.loadMore()
    #expect(model.rows.count == 16)
    model.selection = "in16"
    await mail.arrive("in21")
    model.setAppActive(true)
    try await refreshEventually { model.rows.first?.id == "in21" }
    #expect(model.rows.count == 17)
    #expect(model.selection == "in16")
    #expect(await mail.calls == 3) // One fresh first-page list, not a reload of every loaded page.
    while model.hasMore { await model.loadMore() }
    #expect(model.rows.count == 21)
    #expect(Set(model.rows.map(\.id)).count == 21)
    #expect(model.selection == "in16")
    #expect(await mail.requestedMax.allSatisfy { $0 == 8 })
}

@Test @MainActor func reactivationWaitsForCancelledRefreshBeforeStartingOneTimer() async throws {
    let clock = RefreshClock()
    var calls = 0
    var inflight = 0
    var maxInflight = 0
    var release: CheckedContinuation<Void, Never>?
    let refresh = ForegroundMailRefresh(refresh: {
        calls += 1
        inflight += 1
        maxInflight = max(maxInflight, inflight)
        defer { inflight -= 1 }
        if calls == 1 { await withCheckedContinuation { release = $0 } }
    }, sleep: { try await clock.sleep($0) })
    defer { refresh.setActive(false) }
    refresh.setActive(true)
    try await refreshEventually { release != nil }
    // Model a refresh awaiting a non-cancellable remote write after losing foreground status.
    refresh.setActive(false)
    refresh.setActive(true)
    refresh.setActive(false)
    refresh.setActive(true)
    refresh.setActive(true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(calls == 1)
    #expect(clock.waiting == 0)
    release?.resume()
    try await refreshEventually { calls == 2 && clock.waiting == 1 }
    #expect(maxInflight == 1)
    clock.advance(.seconds(600))
    try await refreshEventually { calls == 3 && clock.waiting == 1 }
    refresh.setActive(false)
    try await refreshEventually { clock.waiting == 0 }
    clock.advance(.seconds(1800))
    #expect(calls == 3)
}

@Test @MainActor func reactivationRefreshIsNotLostWhileCancelledRefreshAwaitsRemoteMove() async throws {
    let mail = RefreshMail()
    let model = await refreshFixture(mail)
    defer { model.setAppActive(false); model.signOut() }
    try await refreshEventually { model.detail != nil && !model.suggesting }
    await mail.holdMoves()
    await model.fileSelected(into: .reference)
    try await refreshEventually { await mail.moves == 1 }
    await mail.arrive("in03")
    model.setAppActive(true)
    // Give the activation refresh time to acquire ownership and await the held write.
    try await Task.sleep(for: .milliseconds(30))
    model.setAppActive(false)
    model.setAppActive(true)
    model.setAppActive(true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await mail.calls == 1)
    await mail.releaseMoves()
    try await refreshEventually { model.rows.first?.id == "in03" }
    #expect(await mail.calls == 2)
    #expect(await mail.maxInflight == 1)
    try await Task.sleep(for: .milliseconds(60))
    #expect(await mail.calls == 2)
}

@Test @MainActor func activationRevalidatesChangedRowsDetailAndCategorisationButReusesUnchangedThreads() async throws {
    let mail = RefreshMail()
    await mail.useIDs(["in03", "in02", "in01"])
    var settings = CategorisationSettings()
    settings.jevEnabled = true
    let categoriser = Categoriser(local: { thread, _, _ in
        TriageSuggestion(bucket: thread.historyId == "2" ? .nextAction : .reference,
                         nextAction: "", summary: "History \(thread.historyId ?? "")", waitingOn: nil)
    }, remote: { thread, _, _, _ in
        JevClassification(bucket: thread.historyId == "2" ? .nextAction : .reference)
    })
    let model = AppModel(signedIn: true, settings: settings, folder: .inbox,
                         categoriser: categoriser, loadJevToken: { "test-token" })
    model.demo = true
    defer { model.setAppActive(false); model.signOut() }
    await model.connect(using: mail, persist: false)
    for row in model.rows { model.rowAppeared(row.id) }
    try await refreshEventually {
        model.rows.allSatisfy { $0.loaded && model.localSuggestion(for: $0.id) != nil
            && model.inboxBucket(for: $0.id) == .reference && !model.isQueued($0.id) }
            && model.detail?.historyId == "1"
    }
    #expect(model.selection == "in03")
    #expect(model.rows.first?.unread == false)
    #expect(await mail.threadCalls == ["in03": 1, "in02": 1, "in01": 1])
    let oldMessageCount = model.detail?.messages?.count ?? 0
    model.chooseTab(.original)
    await mail.reply(to: "in03")  // Selected, even if its row is not on screen.
    model.rowDisappeared("in03")
    await mail.reply(to: "in02")  // Visible but not selected: hydration must update it too.
    model.setAppActive(true)
    try await refreshEventually {
        model.detail?.historyId == "2" && model.rows.prefix(2).allSatisfy {
            $0.loaded && $0.snippet == "Reply \($0.id)" && $0.subject == "Reply subject \($0.id)"
                && $0.unread && model.localSuggestion(for: $0.id)?.summary == "History 2"
                && model.inboxBucket(for: $0.id) == .nextAction && !model.isQueued($0.id)
        }
    }
    #expect(model.selection == "in03")
    #expect(model.detail?.messages?.count == oldMessageCount + 1)
    #expect(model.detail?.messages?.last?.plainText == "Reply in03")
    #expect(model.detailTab == .original) // Do not undo the user's explicit tab choice.
    #expect(await mail.calls == 2)
    #expect(await mail.threadCalls == ["in03": 2, "in02": 2, "in01": 1])

    model.setAppActive(false)
    model.setAppActive(true)
    try await refreshEventually { await mail.calls == 3 }
    try await Task.sleep(for: .milliseconds(400))
    #expect(model.rows.allSatisfy { $0.loaded })
    #expect(model.selection == "in03")
    #expect(await mail.threadCalls == ["in03": 2, "in02": 2, "in01": 1])
}
