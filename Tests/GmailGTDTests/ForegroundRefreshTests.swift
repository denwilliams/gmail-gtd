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
    private var inflight = 0
    private(set) var calls = 0
    private(set) var maxInflight = 0
    private(set) var requestedMax: [Int] = []
    func arrive(_ id: String) { ids.insert(id, at: 0) }
    func useIDs(_ ids: [String]) { self.ids = ids }
    func hold() { held = true }
    func release() { held = false }
    func failNext() { shouldFail = true }

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
        return ThreadPage(refs: page.map { ThreadRef(id: $0, snippet: "Mail \($0)") },
                          nextPageToken: start + page.count < ids.count ? String(start + page.count) : nil)
    }
    func thread(_ id: String, full: Bool) async throws -> GmailThread { try await base.thread(id, full: full) }
    func labels() async throws -> [GmailLabel] { try await base.labels() }
    func createLabel(_ name: String) async throws -> GmailLabel { try await base.createLabel(name) }
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        try await base.modifyThread(id, add: add, remove: remove)
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
