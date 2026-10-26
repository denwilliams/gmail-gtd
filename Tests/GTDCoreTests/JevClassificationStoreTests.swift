import Foundation
import Testing
@testable import GTDCore

private func cacheThread(history: String = "1", labels: [String] = ["INBOX"],
                         body: String = "Please reply.", sender: String = "sender@example.test",
                         subject: String = "Question", messageID: String = "m1", reply: Bool = false) -> GmailThread {
    var messages = [GmailMessage(id: messageID, threadId: "t1", labelIds: labels, snippet: body,
                                internalDate: nil, payload: GmailMessage.Part(mimeType: nil, headers: [
                                    GmailMessage.Header(name: "From", value: sender),
                                    GmailMessage.Header(name: "Subject", value: subject)
                                ], body: nil, parts: nil))]
    if reply {
        messages.append(GmailMessage(id: "m2", threadId: "t1", labelIds: labels, snippet: "Thanks!",
                                     internalDate: nil, payload: nil))
    }
    return GmailThread(id: "t1", historyId: history, messages: messages)
}

private func cacheKey(_ thread: GmailThread = cacheThread(), mailbox: String = "me@example.test",
                      prompt: String = TriagePrompts.jev) throws -> JevClassificationKey {
    try #require(JevClassificationKey(thread: thread, mailbox: mailbox, prompt: prompt))
}

private actor CacheProviderProbe {
    private(set) var calls = 0
    private var released = false
    func run() async -> JevClassification {
        calls += 1
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        // Deliberately return success even on cancellation, like an already-sent HTTP request.
        while !released && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            await Task.yield()
        }
        return JevClassification(bucket: .noise, noiseLikelihood: 0.97)
    }
    func release() { released = true }
}

@Test func jevCacheKeyTracksContentAccountAndRequestButNotLabels() throws {
    let key = try cacheKey()
    #expect(try cacheKey(cacheThread(history: "2", labels: ["GTD/Noise", "UNREAD"])) == key)
    #expect(try cacheKey(mailbox: " ME@example.test ") == key)
    #expect(try cacheKey(mailbox: "other@example.test") != key)
    #expect(try cacheKey(prompt: "Different rules.") != key)
    for changed in [cacheThread(body: "Edited."), cacheThread(sender: "other@example.test"),
                    cacheThread(subject: "Changed"), cacheThread(messageID: "replacement"), cacheThread(reply: true)] {
        #expect(try cacheKey(changed) != key)
    }
    #expect(JevClassificationKey(thread: cacheThread(), mailbox: "me@example.test", prompt: TriagePrompts.jev,
                                 model: "next-model") != key)
    #expect(JevClassificationKey(thread: cacheThread(), mailbox: "me@example.test", prompt: TriagePrompts.jev,
                                 format: "old-category-only") != key)
    #expect(JevClassificationKey(thread: cacheThread(), mailbox: " ", prompt: TriagePrompts.jev) == nil)
    #expect(JevClassificationKey(thread: cacheThread(), mailbox: "me@example.test", prompt: "") == nil)
    #expect(JevClassificationKey(thread: GmailThread(id: "t", historyId: nil, messages: []),
                                 mailbox: "me@example.test", prompt: TriagePrompts.jev) == nil)
    // Content outside the bounded provider transcript must still invalidate the cache.
    let long = String(repeating: "x", count: 40_000)
    #expect(try cacheKey(cacheThread(body: long + "a")) != cacheKey(cacheThread(body: long + "b")))
}

@Test(arguments: [nil, 0.97] as [Double?]) @MainActor
func jevCachePersistsCategoriesAndOptionalScoresPrivately(score: Double?) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try #require(JevClassificationStore.fileURL(for: "me@example.test", directory: directory))
    let otherURL = try #require(JevClassificationStore.fileURL(for: "other@example.test", directory: directory))
    #expect(url != otherURL)
    #expect(JevClassificationStore.fileURL(for: " ME@example.test ", directory: directory) == url)
    #expect(JevClassificationStore.fileURL(for: " ", directory: directory) == nil)
    let key = try cacheKey()
    let store = JevClassificationStore(fileURL: url)
    _ = try await store.resolve(key) { JevClassification(bucket: .noise, noiseLikelihood: score) }
    let relaunched = JevClassificationStore(fileURL: url)
    let result = try await relaunched.resolve(key) {
        Issue.record("Persisted cache miss caused redundant provider work")
        return JevClassification(bucket: .done)
    }
    #expect(result.bucket == .noise)
    #expect(result.noiseLikelihood == score)
    #expect(relaunched.classification(for: try cacheKey(mailbox: "other@example.test")) == nil)
    #expect(relaunched.classification(for: try cacheKey(prompt: "New prompt")) == nil)
    #expect(relaunched.classification(for: try cacheKey(cacheThread(reply: true))) == nil)
    #expect(JevClassificationStore(fileURL: otherURL).classification(for: key) == nil)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    let parentPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(parentPermissions?.intValue == 0o700)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("Please reply"))
    #expect(!text.contains("me@example.test"))
    #expect(!text.contains(TriagePrompts.jev))
    relaunched.clear()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(relaunched.classification(for: key) == nil)
}

@Test(arguments: [0, 500]) @MainActor func concurrentJevRequestsJoinOneProviderOperation(capacity: Int) async throws {
    let store = JevClassificationStore(capacity: capacity)
    let probe = CacheProviderProbe()
    let key = try cacheKey()
    let requests = (0..<12).map { _ in Task { try await store.resolve(key) { await probe.run() } } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while await probe.calls == 0 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await probe.calls == 1)
    await probe.release()
    for request in requests {
        let result = try await request.value
        #expect(result.bucket == .noise)
        #expect(result.noiseLikelihood == 0.97)
    }
    #expect(await probe.calls == 1)
}

private enum CacheTestError: Error { case offline }

@Test @MainActor func jevErrorsAreNotPersistedAndExplicitRemovalForcesFreshWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "cache.json")
    let key = try cacheKey()
    let store = JevClassificationStore(fileURL: url)
    do {
        _ = try await store.resolve(key) { throw CacheTestError.offline }
        Issue.record("Expected transient provider error")
    } catch CacheTestError.offline { }
    #expect(store.classification(for: key) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    _ = try await store.resolve(key) { JevClassification(bucket: .noise) }
    store.remove(for: key.threadID)
    #expect(JevClassificationStore(fileURL: url).classification(for: key) == nil)
    let fresh = try await store.resolve(key) { JevClassification(bucket: .reference, noiseLikelihood: 0.01) }
    #expect(fresh.bucket == .reference)
}

@Test @MainActor func signOutFencesLateSuccessAndDoesNotPersistPendingWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "cache.json")
    let key = try cacheKey()
    let store = JevClassificationStore(fileURL: url)
    let probe = CacheProviderProbe()
    let request = Task { try await store.resolve(key) { await probe.run() } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await probe.calls == 0 && ContinuousClock.now < deadline { await Task.yield() }
    #expect(await probe.calls == 1)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    store.clear()
    await probe.release()
    do { _ = try await request.value; Issue.record("A cleared cache must reject late success") }
    catch is CancellationError { }
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(store.classification(for: key) == nil)
}

@Test @MainActor func corruptIncompatibleOrUnavailableJevCacheIsHarmless() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "cache.json")
    let key = try cacheKey()
    for contents in ["not json", #"{"version":999,"entries":{}}"#] {
        try Data(contents.utf8).write(to: url)
        let store = JevClassificationStore(fileURL: url)
        #expect(store.classification(for: key) == nil)
        _ = try await store.resolve(key) { JevClassification(bucket: .noise) }
        #expect(JevClassificationStore(fileURL: url).classification(for: key)?.bucket == .noise)
    }
    // A regular file cannot be a parent directory. In-memory success still works.
    let unavailable = JevClassificationStore(fileURL: url.appending(path: "cache.json"))
    _ = try await unavailable.resolve(key) { JevClassification(bucket: .reference) }
    #expect(unavailable.classification(for: key)?.bucket == .reference)
    let zeroCapacity = JevClassificationStore(capacity: 0)
    _ = try await zeroCapacity.resolve(key) { JevClassification(bucket: .reference) }
    #expect(zeroCapacity.classification(for: key) == nil)
}
