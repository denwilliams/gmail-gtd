import Foundation

/// In-memory stand-in for Gmail. Supports every action the app performs, and resets on relaunch.
public actor DemoMailService: MailService {
    struct Stored {
        let id: String
        var labels: Set<String>
        var messages: [DemoMessage]
    }

    private var threads: [String: Stored] = [:]
    private var labelList: [GmailLabel] = []
    private var nextLabel = 100

    public static let account = "alex@example.com"

    public init(now: Date = Date()) {
        labelList = [
            GmailLabel(id: "INBOX", name: "INBOX", type: "system"),
            GmailLabel(id: "UNREAD", name: "UNREAD", type: "system"),
        ]
        // Pre-create the GTD labels so seed threads can be filed under them.
        for bucket in GTDBucket.allCases {
            labelList.append(GmailLabel(id: Self.labelID(bucket), name: bucket.labelName, type: "user"))
        }
        for seed in DemoData.threads {
            var labels: Set<String> = []
            if seed.inbox { labels.insert("INBOX") }
            if let bucket = seed.bucket { labels.insert(Self.labelID(bucket)) }
            if seed.unread { labels.insert("UNREAD") }
            threads[seed.id] = Stored(id: seed.id, labels: labels, messages: seed.messages)
        }
        self.now = now
    }

    private let now: Date

    static func labelID(_ bucket: GTDBucket) -> String { "Label_\(bucket.rawValue)" }

    // MARK: - MailService

    /// Pages by offset: the token is the index of the next thread.
    public func listThreadPage(labelIDs: [String], query: String?, max: Int, pageToken: String?) async throws -> ThreadPage {
        let all = threads.values
            .filter { t in labelIDs.allSatisfy(t.labels.contains) }
            .sorted { $0.messages.last!.hoursAgo < $1.messages.last!.hoursAgo }
        let start = pageToken.flatMap(Int.init) ?? 0
        let slice = all.dropFirst(start).prefix(max)
        let next = start + slice.count < all.count ? String(start + slice.count) : nil
        return ThreadPage(refs: slice.map { ThreadRef(id: $0.id, snippet: Self.snippet($0.messages.last!.body)) }, nextPageToken: next)
    }

    public func thread(_ id: String, full: Bool) async throws -> GmailThread {
        guard let t = threads[id] else { throw GmailError.http(404, "Thread not found") }
        return build(t)
    }

    public func labels() async throws -> [GmailLabel] { labelList }

    public func createLabel(_ name: String) async throws -> GmailLabel {
        nextLabel += 1
        let label = GmailLabel(id: "Label_\(nextLabel)", name: name, type: "user")
        labelList.append(label)
        return label
    }

    public func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        guard var t = threads[id] else { throw GmailError.http(404, "Thread not found") }
        t.labels.subtract(remove)
        t.labels.formUnion(add)
        threads[id] = t
    }

    public func threadCount(labelID: String) async throws -> Int {
        threads.values.filter { $0.labels.contains(labelID) }.count
    }

    public func emailAddress() async throws -> String { Self.account }

    // MARK: - Helpers

    private func build(_ t: Stored) -> GmailThread {
        let messages = t.messages.enumerated().map { i, m in
            GmailMessage(
                id: "\(t.id)-\(i)", threadId: t.id, labelIds: Array(t.labels), snippet: Self.snippet(m.body),
                internalDate: String(Int(now.addingTimeInterval(-m.hoursAgo * 3600).timeIntervalSince1970 * 1000)),
                payload: .init(mimeType: "text/plain",
                               headers: [.init(name: "Subject", value: m.subject ?? t.messages[0].subject ?? ""),
                                         .init(name: "From", value: m.from)]
                                   + (m.bulk ? [.init(name: "List-Unsubscribe", value: "<mailto:unsubscribe@example.com>")] : []),
                               body: .init(data: Data(m.body.utf8).base64URL), parts: nil))
        }
        return GmailThread(id: t.id, historyId: nil, messages: messages)
    }

    private static func snippet(_ body: String) -> String {
        String(body.replacingOccurrences(of: "\n", with: " ").prefix(110))
    }
}

struct DemoMessage {
    let from: String
    let hoursAgo: Double
    let body: String
    var subject: String? = nil
    var bulk = false
}

struct DemoThreadSeed {
    let id: String
    let inbox: Bool
    let bucket: GTDBucket?
    let unread: Bool
    let messages: [DemoMessage]
}
