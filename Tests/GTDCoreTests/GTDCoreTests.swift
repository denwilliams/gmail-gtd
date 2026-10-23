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
}
