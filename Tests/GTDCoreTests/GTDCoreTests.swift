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
