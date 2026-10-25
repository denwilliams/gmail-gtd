import Foundation
import Testing
@testable import GmailGTD
@testable import GTDCore

private enum NavigationError: Error { case offline }

/// One real demo thread, with deterministic account/reply changes and actual label moves.
private actor NavigationMailbox: MailService {
    static let id = "in08"
    private let base = DemoMailService()
    private let account: String
    private var reply = false
    private var revision = 1
    private var heldReads: Bool
    private(set) var readsStarted = 0
    private(set) var readsFinished = 0
    init(account: String = DemoMailService.account, heldReads: Bool = false) {
        self.account = account; self.heldReads = heldReads
    }
    func releaseReads() { heldReads = false }
    func holdReads() { heldReads = true }
    func addReply() { reply = true; revision += 1 }
    func listThreadPage(labelIDs: [String], query: String?, max: Int, pageToken: String?) async throws -> ThreadPage {
        let page = try await base.listThreadPage(labelIDs: labelIDs, query: query, max: 100, pageToken: nil)
        return ThreadPage(refs: page.refs.filter { $0.id == Self.id }.map {
            ThreadRef(id: $0.id, snippet: $0.snippet, historyId: String(revision))
        }, nextPageToken: nil)
    }
    func thread(_ id: String, full: Bool) async throws -> GmailThread {
        readsStarted += 1
        let thread = try await base.thread(id, full: full)
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while heldReads && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        readsFinished += 1
        var messages = thread.messages ?? []
        if reply {
            messages.append(GmailMessage(id: "new-reply", threadId: id, labelIds: messages.last?.labelIds,
                                         snippet: "An additional request.", internalDate: nil, payload: nil))
        }
        return GmailThread(id: id, historyId: String(revision), messages: messages)
    }
    func labels() async throws -> [GmailLabel] { try await base.labels() }
    func createLabel(_ name: String) async throws -> GmailLabel { try await base.createLabel(name) }
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        try await base.modifyThread(id, add: add, remove: remove); revision += 1
    }
    func threadCount(labelID: String) async throws -> Int { try await base.threadCount(labelID: labelID) }
    func emailAddress() async throws -> String { account }
}

private actor NavigationProvider {
    private(set) var calls = 0
    private var held: Bool
    private var failing = false
    init(held: Bool = false) { self.held = held }
    func release() { held = false }
    func setFailing(_ value: Bool) { failing = value }
    func classify(mailbox: String?) async throws -> JevClassification {
        calls += 1
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while held && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            await Task.yield() // Intentionally simulate success even if already-sent work was cancelled.
        }
        if failing { throw NavigationError.offline }
        return JevClassification(bucket: mailbox == DemoMailService.account ? .noise : .nextAction, noiseLikelihood: 0.96)
    }
}

@MainActor private func cacheNavigationModel(_ provider: NavigationProvider) -> AppModel {
    var settings = CategorisationSettings(); settings.jevEnabled = true
    let model = AppModel(signedIn: true, settings: settings, folder: .inbox,
                         categoriser: Categoriser(local: { _, _, _ in
                             TriageSuggestion(bucket: .reference, nextAction: "", summary: "Fake local summary.")
                         }, remote: { _, me, _, _ in try await provider.classify(mailbox: me) }),
                         loadJevToken: { "mock-token" })
    model.demo = true // Never touch real Keychain credentials on test cleanup.
    return model
}

@MainActor private func waitForCacheNavigation(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await condition()) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await condition(), "Timed out waiting for fake cache/navigation work")
}

@Test @MainActor func selectionScrollingAndFolderNavigationSharePendingAndCompletedJev() async throws {
    let mailbox = NavigationMailbox()
    let provider = NavigationProvider(held: true)
    let model = cacheNavigationModel(provider)
    defer { model.signOut() }
    await model.connect(using: mailbox, persist: false)
    try await waitForCacheNavigation { await provider.calls == 1 && model.jevStatus?.pending == true }
    for _ in 0..<4 {
        model.rowAppeared(NavigationMailbox.id)
        model.selection = nil
        await Task.yield()
        model.selection = NavigationMailbox.id
        model.rowDisappeared(NavigationMailbox.id)
    }
    try await Task.sleep(for: .milliseconds(450))
    #expect(await provider.calls == 1)
    // Reconnecting during the provider call must still reuse that exact work/result.
    await model.connect(using: mailbox, persist: false)
    await provider.release()
    try await waitForCacheNavigation { model.approvalBucket == .noise && !model.suggesting }
    #expect(await provider.calls == 1)
    #expect(model.noiseLikelihood(for: NavigationMailbox.id) == 0.96)

    await model.fileSelected(into: .nextAction)
    await model.refreshQuietly() // Wait for the serialized label move, not a fixed delay.
    model.folder = .bucket(.nextAction)
    try await waitForCacheNavigation {
        model.selection == NavigationMailbox.id && model.detail?.id == NavigationMailbox.id && !model.suggesting
    }
    for _ in 0..<3 {
        model.selection = nil
        model.folder = .inbox
        try await waitForCacheNavigation {
            model.selection == NavigationMailbox.id && model.approvalBucket == .noise && !model.suggesting
        }
        model.rowAppeared(NavigationMailbox.id)
        model.rowDisappeared(NavigationMailbox.id)
        model.selection = nil
        model.folder = .bucket(.nextAction)
        try await waitForCacheNavigation {
            model.selection == NavigationMailbox.id && model.approvalBucket == .noise && !model.suggesting
        }
    }
    #expect(await provider.calls == 1)
    #expect(model.approvalBucket == .noise)
    // New message IDs/content, unlike label-only history changes, require new provider work.
    await mailbox.addReply()
    model.selection = nil
    await model.refresh()
    try await waitForCacheNavigation { await provider.calls == 2 && model.approvalBucket == .noise && !model.suggesting }
}

@Test @MainActor func appReconnectAndRelaunchReusePrivateCacheButRegenerateAccountAndPromptDoNot() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = NavigationProvider()
    let mailbox = NavigationMailbox()
    let first = cacheNavigationModel(provider)
    let relaunched = cacheNavigationModel(provider)
    defer { first.signOut(); relaunched.signOut() }
    await first.connect(using: mailbox, persist: true, cacheDirectory: directory)
    try await waitForCacheNavigation { first.approvalBucket == .noise && !first.suggesting }
    #expect(await provider.calls == 1)
    await first.connect(using: mailbox, persist: true, cacheDirectory: directory)
    try await waitForCacheNavigation { first.approvalBucket == .noise && !first.suggesting }
    #expect(await provider.calls == 1)
    await relaunched.connect(using: mailbox, persist: true, cacheDirectory: directory)
    try await waitForCacheNavigation { relaunched.approvalBucket == .noise && !relaunched.suggesting }
    #expect(await provider.calls == 1)
    #expect(relaunched.noiseLikelihood(for: NavigationMailbox.id) == 0.96)
    relaunched.regenerateSelected()
    try await waitForCacheNavigation { await provider.calls == 2 && !relaunched.suggesting }
    relaunched.categorisationSettings.localPrompt = "Different local instruction."
    relaunched.setDeNoiseThreshold(0.95)
    try await waitForCacheNavigation { relaunched.approvalBucket == .noise && !relaunched.suggesting }
    #expect(await provider.calls == 2)
    relaunched.categorisationSettings.jevPrompt = "Different remote instruction."
    try await waitForCacheNavigation { await provider.calls == 3 && relaunched.approvalBucket == .noise && !relaunched.suggesting }
    await relaunched.connect(using: NavigationMailbox(account: "other@example.test"), persist: true, cacheDirectory: directory)
    try await waitForCacheNavigation { await provider.calls == 4 && relaunched.approvalBucket == .nextAction && !relaunched.suggesting }
}

@Test @MainActor func navigationDoesNotRetryErrorsButExplicitRetryAndReconnectDo() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = NavigationProvider()
    await provider.setFailing(true)
    let model = cacheNavigationModel(provider)
    let mailbox = NavigationMailbox()
    defer { model.signOut() }
    await model.connect(using: mailbox, persist: true, cacheDirectory: directory)
    try await waitForCacheNavigation { model.jevStatus?.failed == true && !model.suggesting }
    for _ in 0..<3 {
        model.selection = nil
        await Task.yield()
        model.selection = NavigationMailbox.id
        model.rowAppeared(NavigationMailbox.id)
        model.rowDisappeared(NavigationMailbox.id)
    }
    try await Task.sleep(for: .milliseconds(450))
    #expect(await provider.calls == 1)
    model.regenerateSelected()
    try await waitForCacheNavigation { await provider.calls == 2 && model.jevStatus?.failed == true && !model.suggesting }
    await provider.setFailing(false)
    await model.connect(using: mailbox, persist: true, cacheDirectory: directory)
    try await waitForCacheNavigation { await provider.calls == 3 && model.approvalBucket == .noise && !model.suggesting }
}

@Test @MainActor func signOutDuringProviderWorkCannotRestoreCacheOrLeakToAnotherAccount() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = NavigationProvider(held: true)
    let model = cacheNavigationModel(provider)
    defer { model.demo = true; model.signOut() }
    let url = try #require(JevClassificationStore.fileURL(for: DemoMailService.account,
                                                        directory: directory.appending(path: "JevClassifications")))
    await model.connect(using: NavigationMailbox(), persist: true, cacheDirectory: directory)
    try await waitForCacheNavigation { await provider.calls == 1 }
    model.signOut()
    await provider.release()
    try await waitForCacheNavigation { !model.isGenerating(NavigationMailbox.id) }
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(model.approvalBucket == nil)
    model.demo = true; model.signedIn = true
    await model.connect(using: NavigationMailbox(account: "other@example.test"), persist: true, cacheDirectory: directory)
    try await waitForCacheNavigation { await provider.calls == 2 && model.approvalBucket == .nextAction && !model.suggesting }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func oldAccountDetailFetchCannotReplaceNewAccountContentOrClassification() async throws {
    let provider = NavigationProvider()
    let oldMailbox = NavigationMailbox(heldReads: true)
    let newMailbox = NavigationMailbox(account: "other@example.test")
    await newMailbox.addReply() // Same thread ID, different account and content.
    let model = cacheNavigationModel(provider)
    defer { model.demo = true; model.signOut() }
    await model.connect(using: oldMailbox, persist: false)
    try await waitForCacheNavigation { await oldMailbox.readsStarted > 0 }
    model.signOut()
    model.demo = true; model.signedIn = true
    await model.connect(using: newMailbox, persist: false)
    // The single Jev worker can be waiting for the old fetch, but detail loading is independent.
    try await waitForCacheNavigation { model.detail?.messages?.count == 2 }
    await oldMailbox.releaseReads()
    try await waitForCacheNavigation { await oldMailbox.readsFinished > 0 && model.approvalBucket == .nextAction && !model.suggesting }
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.detail?.messages?.count == 2)
    #expect(model.approvalBucket == .nextAction)
    #expect(await provider.calls == 1)
}

@Test @MainActor func changedHistoryWithholdsApprovalUntilContentIsValidatedWithoutReclassifyingLabels() async throws {
    let provider = NavigationProvider()
    let mailbox = NavigationMailbox()
    let model = cacheNavigationModel(provider)
    defer { model.signOut() }
    await model.connect(using: mailbox, persist: false)
    try await waitForCacheNavigation { model.approvalBucket == .noise && !model.suggesting }
    await mailbox.holdReads()
    try await mailbox.modifyThread(NavigationMailbox.id, add: ["STARRED"], remove: [])
    model.rowAppeared(NavigationMailbox.id)
    await model.refresh()
    #expect(model.approvalBucket == nil) // Labels/history changed; content not validated yet.
    await mailbox.releaseReads()
    try await waitForCacheNavigation { model.approvalBucket == .noise && !model.suggesting }
    #expect(await provider.calls == 1) // Validation is not another provider call.
    await mailbox.holdReads()
    await mailbox.addReply()
    await model.refresh()
    #expect(model.approvalBucket == nil) // Never approve the old category while a reply is fetching.
    await mailbox.releaseReads()
    try await waitForCacheNavigation { await provider.calls == 2 && model.approvalBucket == .noise && !model.suggesting }
}
