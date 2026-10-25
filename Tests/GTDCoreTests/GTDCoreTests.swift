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
    #expect(GTDBucket(cliName: "done") == .done)
    #expect(GTDBucket.done.labelName == "GTD/Done")
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

@Test(arguments: GTDBucket.allCases, [true, false])
func filingSetsInboxMembershipAndPreservesMail(bucket: GTDBucket, initiallyInInbox: Bool) async throws {
    let demo = DemoMailService()
    let labels = LabelManager(client: demo)
    let ids = try await labels.ensureLabels()
    let custom = try await demo.createLabel("Keep me")
    let unrelated: Set<String> = ["UNREAD", "STARRED", custom.id]
    let previous: GTDBucket = bucket == .reference ? .noise : .reference
    try await demo.modifyThread("in07", add: Array(unrelated) + [ids[previous]!],
                                remove: initiallyInInbox ? [] : ["INBOX"])
    let before = try await demo.thread("in07", full: true)

    try await labels.file(thread: "in07", into: bucket)
    // Applying the same category again must also be safe.
    try await labels.file(thread: "in07", into: bucket)

    var expected = unrelated.union([ids[bucket]!])
    if [GTDBucket.nextAction, .waitingFor, .someday].contains(bucket) { expected.insert("INBOX") }
    let after = try await demo.thread("in07", full: true)
    let messages = try #require(after.messages)
    #expect(messages.map(\.id) == before.messages?.map(\.id))
    #expect(messages.map(\.plainText) == before.messages?.map(\.plainText))
    for message in messages {
        // Exact equality also guards against stale GTD labels, TRASH or lost unrelated labels.
        #expect(Set(message.labelIds ?? []) == expected)
    }
    let filed = try await demo.listThreads(labelIDs: [ids[bucket]!], max: 50)
    #expect(filed.contains { $0.id == "in07" })
}

@Test(arguments: [GTDBucket.nextAction, .waitingFor, .someday], [GTDBucket.reference, .noise])
func changingBetweenActionableAndSearchOnlyUpdatesInbox(actionable: GTDBucket, searchOnly: GTDBucket) async throws {
    let demo = DemoMailService()
    let labels = LabelManager(client: demo)
    let ids = try await labels.ensureLabels()

    try await labels.file(thread: "in01", into: searchOnly)
    let archived = try await labels.managedLabels(in: try await demo.thread("in01").messages!.last!.labelIds ?? [])
    #expect(archived == [ids[searchOnly]!])

    // A previously archived message must return to the inbox when it becomes actionable.
    try await labels.file(thread: "in01", into: actionable)
    let active = try await labels.managedLabels(in: try await demo.thread("in01").messages!.last!.labelIds ?? [])
    #expect(active == ["INBOX", ids[actionable]!])

    try await labels.file(thread: "in01", into: searchOnly)
    let rearchived = try await labels.managedLabels(in: try await demo.thread("in01").messages!.last!.labelIds ?? [])
    #expect(rearchived == archived)

    try await labels.restore(thread: "in01", to: active)
    #expect(try await labels.managedLabels(in: try await demo.thread("in01").messages!.last!.labelIds ?? []) == active)
    try await labels.restore(thread: "in01", to: archived)
    #expect(try await labels.managedLabels(in: try await demo.thread("in01").messages!.last!.labelIds ?? []) == archived)
}

@Test func doneIsABucketSoEveryThreadKeepsAGTDLabel() async throws {
    let demo = DemoMailService()
    let labels = LabelManager(client: demo)
    let ids = try await labels.ensureLabels()
    let nextBefore = try await demo.threadCount(labelID: ids[.nextAction]!)
    let doneBefore = try await demo.threadCount(labelID: ids[.done]!)
    try await labels.file(thread: "na01", into: .done)
    #expect(try await demo.threadCount(labelID: ids[.nextAction]!) == nextBefore - 1)
    #expect(try await demo.threadCount(labelID: ids[.done]!) == doneBefore + 1)   // labelled Done, not stripped
    #expect(try await demo.threadCount(labelID: "INBOX") == 20)                   // and not returned to the inbox

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

    func listThreadPage(labelIDs: [String], query: String?, max: Int, pageToken: String?) async throws -> ThreadPage {
        listCalls += 1
        let page = try await inner.listThreadPage(labelIDs: labelIDs, query: query, max: max, pageToken: pageToken)
        return ThreadPage(refs: page.refs.map { ThreadRef(id: $0.id, snippet: $0.snippet, historyId: historyID) },
                          nextPageToken: page.nextPageToken)
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

// MARK: - Readable mail

@Test func invisiblePaddingIsRemoved() {
    let padded = "&zwnj; &zwj; &#8204; \u{200B}Hello\u{FEFF}  world &shy;\n\n\n\n   \nNext   "
    let clean = padded.htmlUnescaped.tidied
    #expect(clean == "Hello  world\n\nNext")
}

@Test func longLinksAreShortenedButStayClickable() {
    let long = "https://click.ccg.nintendo.com/?qs=ABl7ImQiOjUwMzgsInQiOjY2MzIsInMiOjd9AAcAAAAACD8BEA7XdMRczpTEtqcG8UvgQ6hQWkNsH0NZ7ROEk"
    let text = "Visit \(long) now. Also https://example.com/a."
    let linked = text.linkified
    #expect(String(linked.characters) == "Visit click.ccg.nintendo.com \u{2197} now. Also https://example.com/a.")
    let links = linked.runs.compactMap(\.link)
    #expect(links.count == 2)
    #expect(links.first?.absoluteString == long)
    #expect(links.last?.absoluteString == "https://example.com/a")   // trailing full stop is not part of the link
}

@Test func modelPromptsDropTrackingLinks() {
    #expect("See https://click.example.com/?qs=abcdef and https://x.test/y ok".modelFriendly == "See [link] and [link] ok")
}

// MARK: - Summary cache (LRU)

private func sampleThread(_ id: String, history: String? = "1", messages: Int = 1) -> GmailThread {
    let msgs = (0..<messages).map {
        GmailMessage(id: "\(id)-\($0)", threadId: id, labelIds: nil, snippet: nil, internalDate: nil, payload: nil)
    }
    return GmailThread(id: id, historyId: history, messages: msgs)
}

private let sampleSuggestion = TriageSuggestion(bucket: .nextAction, nextAction: "Do it", summary: "Summary", waitingOn: nil)

@MainActor @Test func storeEvictsLeastRecentlyUsed() async throws {
    let store = SummaryStore(capacity: 3)
    for id in ["a", "b", "c"] {
        store.setSuggestion(sampleSuggestion, for: sampleThread(id))
        try await Task.sleep(for: .milliseconds(5))
    }
    store.touch("a")                                   // a is now the most recently used
    try await Task.sleep(for: .milliseconds(5))
    store.setSuggestion(sampleSuggestion, for: sampleThread("d"))
    #expect(store.count == 3)
    #expect(store.suggestion(for: "b") == nil)         // b was the oldest, so it went
    #expect(store.suggestion(for: "a") != nil)
    #expect(store.suggestion(for: "c") != nil)
    #expect(store.suggestion(for: "d") != nil)
}

@MainActor @Test func storeHoldsFiveHundredByDefault() async throws {
    let store = SummaryStore()
    for i in 0..<520 { store.setSuggestion(sampleSuggestion, for: sampleThread("t\(i)")) }
    #expect(store.count == 500)
}

@MainActor @Test func storeSurvivesARestart() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "gtd-store-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let first = SummaryStore(fileURL: file)
    let thread = sampleThread("x", history: "9")
    first.note(thread, header: CachedHeader(from: "Ann", subject: "Hi", date: nil, unread: true))
    first.setSuggestion(sampleSuggestion, for: thread)
    first.flush()

    let second = SummaryStore(fileURL: file)
    #expect(second.suggestion(for: "x")?.summary == "Summary")
    #expect(second.header(for: "x", historyId: "9")?.subject == "Hi")
    let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
}

@MainActor @Test func storeKeepsSummaryWhenOnlyLabelsChange() async throws {
    let store = SummaryStore()
    store.note(sampleThread("t", history: "1"), header: nil)
    store.setSuggestion(sampleSuggestion, for: sampleThread("t", history: "1"))
    store.note(sampleThread("t", history: "2"), header: nil)   // filed: Gmail's historyId moved, messages didn't
    #expect(store.suggestion(for: "t") != nil)
}

@MainActor @Test func storeDropsSummaryWhenANewReplyArrives() async throws {
    let store = SummaryStore()
    store.note(sampleThread("t", history: "1", messages: 1), header: nil)
    store.setSuggestion(sampleSuggestion, for: sampleThread("t", history: "1", messages: 1))
    store.note(sampleThread("t", history: "2", messages: 2), header: nil)
    #expect(store.suggestion(for: "t") == nil)
}

@MainActor @Test func cachedHeadersAreOnlyTrustedWhileGmailReportsTheSameHistory() async throws {
    let store = SummaryStore()
    store.note(sampleThread("t", history: "5"), header: CachedHeader(from: "Ann", subject: "Hi", date: nil, unread: false))
    #expect(store.header(for: "t", historyId: "5")?.from == "Ann")
    #expect(store.header(for: "t", historyId: "6") == nil)
}

@Test func threadCacheKeepsOnlyTheMostRecentBodies() async throws {
    let server = CountingService()
    let cache = CachedMailService(server, capacity: 2)
    for id in ["in01", "in02", "in03"] { _ = try await cache.thread(id, full: true) }   // in01 is evicted
    _ = try await cache.thread("in03", full: true)
    _ = try await cache.thread("in02", full: true)
    #expect(await server.threadCalls == 3)                    // both still cached
    _ = try await cache.thread("in01", full: true)
    #expect(await server.threadCalls == 4)                    // the evicted one is fetched again
}

@Test func entitiesInPlainTextPartsAreDecodedToo() async throws {
    let t = try await DemoMailService().thread("in04", full: true)
    let text = t.messages!.last!.plainText
    #expect(!text.contains("&zwnj;"))
    #expect(text.hasPrefix("View this email online"))   // the padding is gone, not just hidden
}

// MARK: - Summaries and names

@Test func summaryHeadlineIsTheFirstSentence() {
    let s = TriageSuggestion(bucket: .reference, nextAction: "",
        summary: "PayPal explains a new trusted device feature. It allows passwordless sign-in costing $2.50 a month. Dr. Lee approved it on 3 May.", waitingOn: nil)
    #expect(s.headline == "PayPal explains a new trusted device feature.")
    #expect(s.details == "It allows passwordless sign-in costing $2.50 a month. Dr. Lee approved it on 3 May.")
    let one = TriageSuggestion(bucket: .reference, nextAction: "", summary: "Just one sentence", waitingOn: nil)
    #expect(one.headline == "Just one sentence")
    #expect(one.details == "")
}

@Test func senderNamesLoseTheirQuotes() {
    #expect("\"Ann Lee\" <ann@x.com>".displayName == "Ann Lee")
    #expect("\"service@bank.example\" <service@bank.example>".displayName == "service@bank.example")
    #expect("ann@x.com".displayName == "ann@x.com")
    #expect("Ann Lee <ann@x.com>".displayName == "Ann Lee")
}

// MARK: - Paging

@Test func demoPagesCoverTheWholeListInOrderWithoutRepeats() async throws {
    let demo = DemoMailService()
    var ids: [String] = []
    var token: String?
    var pages = 0
    repeat {
        let page = try await demo.listThreadPage(labelIDs: ["INBOX"], query: nil, max: 6, pageToken: token)
        ids += page.refs.map(\.id)
        token = page.nextPageToken
        pages += 1
    } while token != nil
    #expect(ids.count == 20)
    #expect(Set(ids).count == 20)
    #expect(pages == 4)   // 6 + 6 + 6 + 2
    let firstPage = try await demo.listThreadPage(labelIDs: ["INBOX"], query: nil, max: 20, pageToken: nil)
    #expect(firstPage.nextPageToken == nil)   // an exact fit has no next page
    #expect(firstPage.refs.map(\.id) == ids)
}

@Test func eachPageIsCachedSeparately() async throws {
    let server = CountingService()
    let cache = CachedMailService(server, listTTL: 60)
    let first = try await cache.listThreadPage(labelIDs: ["INBOX"], query: nil, max: 5, pageToken: nil)
    let second = try await cache.listThreadPage(labelIDs: ["INBOX"], query: nil, max: 5, pageToken: first.nextPageToken)
    #expect(first.refs.map(\.id) != second.refs.map(\.id))
    _ = try await cache.listThreadPage(labelIDs: ["INBOX"], query: nil, max: 5, pageToken: nil)
    _ = try await cache.listThreadPage(labelIDs: ["INBOX"], query: nil, max: 5, pageToken: first.nextPageToken)
    #expect(await server.listCalls == 2)   // both pages served from the cache the second time
}

@Test func gmailListResponsesCarryTheNextPageToken() throws {
    let json = #"{"threads":[{"id":"a","snippet":"x","historyId":"7"}],"nextPageToken":"tok123","resultSizeEstimate":300}"#
    let list = try JSONDecoder().decode(ThreadList.self, from: Data(json.utf8))
    #expect(list.nextPageToken == "tok123")
    #expect(list.threads?.first?.historyId == "7")
}

// MARK: - Undo

@Test func restoreUndoesAMoveExactly() async throws {
    let demo = DemoMailService()
    let labels = LabelManager(client: demo)
    let ids = try await labels.ensureLabels()

    // From the inbox into an actionable bucket, and back (inbox membership is preserved).
    let before = try await labels.managedLabels(in: try await demo.thread("in01", full: true).messages!.last!.labelIds ?? [])
    #expect(before == ["INBOX"])                               // UNREAD is not ours to touch
    try await labels.file(thread: "in01", into: .someday)
    #expect(try await demo.threadCount(labelID: "INBOX") == 20)
    try await labels.restore(thread: "in01", to: before)
    #expect(try await demo.threadCount(labelID: "INBOX") == 20)
    #expect(try await demo.threadCount(labelID: ids[.someday]!) == 3)
    let unread = try await demo.thread("in01", full: true).messages!.last!.labelIds ?? []
    #expect(unread.contains("UNREAD"))                         // still unread: undo didn't disturb it

    // From one bucket to another, and back.
    let nextBefore = try await demo.threadCount(labelID: ids[.nextAction]!)
    let was = try await labels.managedLabels(in: try await demo.thread("na01", full: true).messages!.last!.labelIds ?? [])
    #expect(was == [ids[.nextAction]!])
    try await labels.file(thread: "na01", into: .done)
    try await labels.restore(thread: "na01", to: was)
    #expect(try await demo.threadCount(labelID: ids[.nextAction]!) == nextBefore)
    #expect(try await demo.threadCount(labelID: ids[.done]!) == 3)
}

// MARK: - Saved client ID

@Test func appWithTheSuiteNameAsItsBundleIDUsesStandardDefaults() {
    // The built app's bundle ID equals the suite name; UserDefaults(suiteName:) is nil for that, so use .standard.
    #expect(OAuthConfig.store(suite: "dev.denw.gmail-gtd", bundleID: "dev.denw.gmail-gtd") === UserDefaults.standard)
    // A bare executable (swift run, the CLI) has no bundle ID and uses the named suite.
    #expect(OAuthConfig.store(suite: "gmail-gtd-test-suite", bundleID: nil) !== UserDefaults.standard)
}

@Test func savedConfigRoundTrips() throws {
    let suite = "gmail-gtd-test-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = OAuthConfig.store(suite: suite, bundleID: nil)
    store.set(try JSONEncoder().encode(OAuthConfig(clientID: "id-123", clientSecret: "s3cret")), forKey: "oauthConfig")
    let loaded = try JSONDecoder().decode(OAuthConfig.self, from: #require(store.data(forKey: "oauthConfig")))
    #expect(loaded.clientID == "id-123")
    #expect(loaded.clientSecret == "s3cret")
}
