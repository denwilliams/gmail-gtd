import Testing
import Foundation
@testable import GTDCore

@Test func labelsAreNestedUnderGTD() {
    for bucket in GTDBucket.allCases {
        #expect(bucket.labelName.hasPrefix("GTD/"))
        #expect(GTDBucket(labelName: bucket.labelName) == bucket)
    }
}

@Test func cliNamesParse() {
    #expect(GTDBucket(cliName: "next") == .nextAction)
    #expect(GTDBucket(cliName: "waiting-for") == .waitingFor)
    #expect(GTDBucket(cliName: "noise") == .noise)
    #expect(GTDBucket(cliName: "nope") == nil)
}

@Test func messageDecodesPlainTextBody() throws {
    let json = """
    {"id":"1","threadId":"t","labelIds":["INBOX","UNREAD"],"internalDate":"1700000000000",
     "payload":{"mimeType":"multipart/alternative","headers":[{"name":"Subject","value":"Hi"},{"name":"From","value":"a@b.com"}],
      "parts":[{"mimeType":"text/plain","body":{"data":"SGVsbG8gd29ybGQ_"}}]}}
    """
    let m = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    #expect(m.subject == "Hi")
    #expect(m.isUnread)
    #expect(m.plainText == "Hello world?")
}

@Test func htmlFallbackStripsTags() {
    #expect(GmailMessage.stripHTML("<style>x{}</style><p>Hi&nbsp;<b>there</b></p>") == "Hi there")
}

@Test func gmailLinksTargetThreadAndAccount() {
    #expect(GmailLinks.thread("abc123", account: "me@example.com").absoluteString
        == "https://mail.google.com/mail/?authuser=me@example.com#all/abc123")
    #expect(GmailLinks.inbox(account: nil).absoluteString == "https://mail.google.com/mail/#inbox")
}

// MARK: - Demo backend

@Test func demoMailboxIsSeededAcrossBuckets() async throws {
    let demo = DemoMailService()
    let labels = LabelManager(client: demo)
    let ids = try await labels.ensureLabels()
    #expect(try await demo.threadCount(labelID: "INBOX") == 20)
    for bucket in GTDBucket.allCases {
        #expect(try await demo.threadCount(labelID: ids[bucket]!) >= 3)
    }
}

@Test func filingMovesThreadOutOfInboxIntoBucket() async throws {
    let demo = DemoMailService()
    let labels = LabelManager(client: demo)
    let ids = try await labels.ensureLabels()
    try await labels.file(thread: "in01", into: .nextAction)
    #expect(try await demo.threadCount(labelID: "INBOX") == 19)
    let inNext = try await demo.listThreads(labelIDs: [ids[.nextAction]!], max: 50)
    #expect(inNext.contains { $0.id == "in01" })

    // Re-filing swaps the bucket rather than stacking labels.
    try await labels.file(thread: "in01", into: .someday)
    #expect(!(try await demo.listThreads(labelIDs: [ids[.nextAction]!], max: 50)).contains { $0.id == "in01" })
}

@Test func completeAndUnfile() async throws {
    let demo = DemoMailService()
    let labels = LabelManager(client: demo)
    let ids = try await labels.ensureLabels()
    let before = try await demo.threadCount(labelID: ids[.nextAction]!)
    try await labels.complete(thread: "na01")
    #expect(try await demo.threadCount(labelID: ids[.nextAction]!) == before - 1)
    #expect(try await demo.threadCount(labelID: "INBOX") == 20)   // archived, not returned to the inbox

    try await labels.unfile(thread: "na02")
    #expect(try await demo.threadCount(labelID: "INBOX") == 21)
}

@Test func demoThreadsDecodeLikeGmailThreads() async throws {
    let demo = DemoMailService()
    let thread = try await demo.thread("in07", full: true)
    #expect(thread.messages?.count == 3)
    #expect(thread.messages?.first?.subject == "Contract redlines attached")
    #expect(thread.messages?.last?.plainText.contains("Monday") == true)
    #expect(thread.messages?.first?.date != nil)
}

@Test func demoStateIsPerInstance() async throws {
    let a = DemoMailService(), b = DemoMailService()
    try await LabelManager(client: a).file(thread: "in01", into: .reference)
    #expect(try await a.threadCount(labelID: "INBOX") == 19)
    #expect(try await b.threadCount(labelID: "INBOX") == 20)   // a fresh instance is a reset
}

@Test func triageRulesChooseBucketFromAnswers() {
    #expect(TriageRules.bucket(whoActs: "user", kind: "singleTask") == .nextAction)
    #expect(TriageRules.bucket(whoActs: "someoneElse", kind: "singleTask") == .waitingFor)
    #expect(TriageRules.bucket(whoActs: "nobody", kind: "singleTask") == .reference)
    #expect(TriageRules.bucket(whoActs: "user", kind: "multiStepProject") == .project)
    #expect(TriageRules.bucket(whoActs: "nobody", kind: "informationOnly") == .reference)
    #expect(TriageRules.bucket(whoActs: "nobody", kind: "optionalIdea") == .someday)
    #expect(TriageRules.bucket(whoActs: "nobody", kind: "noise") == .noise)
    #expect(TriageRules.bucket(whoActs: "user", kind: "noise") == .noise)   // junk stays junk even if it nags
    #expect(TriageRules.bucket(whoActs: "user", kind: "singleTask", asksUser: false) == .reference)   // an announcement is not a task
}

@Test func googleErrorBodiesAreSummarised() {
    let body = #"{"error":{"code":403,"message":"Gmail API has not been used in project 1 before or it is disabled.","errors":[{"reason":"accessNotConfigured"}]}}"#
    let text = GmailError.http(403, body).errorDescription
    #expect(text == "Gmail API 403: Gmail API has not been used in project 1 before or it is disabled.")
    #expect(GmailError.http(500, "oops").errorDescription == "Gmail API 500: oops")
}

@Test func htmlEntitiesAreDecoded() throws {
    #expect("they&#39;ll & it&#x27;s &amp; &quot;ok&quot; &lt;b&gt; &nbsp;x".htmlUnescaped == "they'll & it's & \"ok\" <b>  x")
    #expect("AT&T and &unknown; and a&b".htmlUnescaped == "AT&T and &unknown; and a&b")
    #expect("plain".htmlUnescaped == "plain")
    let ref = try JSONDecoder().decode(ThreadRef.self, from: Data(#"{"id":"1","snippet":"Don&#39;t miss it"}"#.utf8))
    #expect(ref.snippet == "Don't miss it")
}

// MARK: - Caching

/// Counts how many requests reach the "server", and lets a test change what the list reports.
actor CountingService: MailService {
    let inner = DemoMailService()
    var threadCalls = 0, listCalls = 0
    var historyID = "1"

    func listThreads(labelIDs: [String], query: String?, max: Int) async throws -> [ThreadRef] {
        listCalls += 1
        let refs = try await inner.listThreads(labelIDs: labelIDs, query: query, max: max)
        return refs.map { ThreadRef(id: $0.id, snippet: $0.snippet, historyId: historyID) }
    }
    func thread(_ id: String, full: Bool) async throws -> GmailThread {
        threadCalls += 1
        try await Task.sleep(for: .milliseconds(20))   // long enough for concurrent callers to overlap
        let t = try await inner.thread(id, full: full)
        return GmailThread(id: t.id, historyId: historyID, messages: t.messages)
    }
    func labels() async throws -> [GmailLabel] { try await inner.labels() }
    func createLabel(_ name: String) async throws -> GmailLabel { try await inner.createLabel(name) }
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws { try await inner.modifyThread(id, add: add, remove: remove) }
    func threadCount(labelID: String) async throws -> Int { try await inner.threadCount(labelID: labelID) }
    func emailAddress() async throws -> String { try await inner.emailAddress() }
    func bump() { historyID = "2" }
}

@Test func cacheFetchesEachThreadOnce() async throws {
    let server = CountingService()
    let cache = CachedMailService(server)
    // The row, the open thread and the model all ask at once, then again later.
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<5 { group.addTask { _ = try? await cache.thread("in01", full: true) } }
    }
    _ = try await cache.thread("in01", full: false)
    _ = try await cache.thread("in01", full: true)
    #expect(await server.threadCalls == 1)
}

@Test func cacheReusesListsBriefly() async throws {
    let server = CountingService()
    let cache = CachedMailService(server, listTTL: 60)
    _ = try await cache.listThreads(labelIDs: ["INBOX"], max: 10)
    _ = try await cache.listThreads(labelIDs: ["INBOX"], max: 10)
    #expect(await server.listCalls == 1)
    await cache.invalidateAll()   // Refresh
    _ = try await cache.listThreads(labelIDs: ["INBOX"], max: 10)
    #expect(await server.listCalls == 2)
}

@Test func cacheRefetchesWhenGmailReportsANewerHistoryID() async throws {
    let server = CountingService()
    let cache = CachedMailService(server, listTTL: 0)
    _ = try await cache.listThreads(labelIDs: ["INBOX"], max: 10)
    _ = try await cache.thread("in01", full: true)
    await server.bump()                                    // the thread changed on Gmail
    _ = try await cache.listThreads(labelIDs: ["INBOX"], max: 10)
    _ = try await cache.thread("in01", full: true)
    #expect(await server.threadCalls == 2)
}

@Test func modifyingAThreadDropsItsCachedCopy() async throws {
    let server = CountingService()
    let cache = CachedMailService(server)
    _ = try await cache.thread("in01", full: true)
    try await cache.modifyThread("in01", add: [], remove: ["INBOX"])
    _ = try await cache.thread("in01", full: true)
    #expect(await server.threadCalls == 2)
}
