import Foundation

/// Wraps a mail service so each thread is fetched at most once, however many places ask for it.
///
/// Gmail bills every request against a per-user quota. The list row, the open thread and the on-device
/// model all want the same thread, so one full fetch is cached and shared, and simultaneous requests for
/// the same thread join a single call. A cached thread is reused until Gmail reports a newer `historyId`.
public actor CachedMailService: MailService {
    private let base: any MailService
    private var threads: [String: GmailThread] = [:]
    private var inFlight: [String: Task<GmailThread, Error>] = [:]
    private var latestHistory: [String: String] = [:]
    private var lists: [String: (at: Date, page: ThreadPage)] = [:]
    private let listTTL: TimeInterval
    private var recency: [String] = []   // thread ids, least recently used first
    private let capacity: Int

    public init(_ base: any MailService, listTTL: TimeInterval = 20, capacity: Int = 150) {
        self.base = base
        self.listTTL = listTTL
        self.capacity = capacity
    }

    /// Forget everything, so the next read goes to Gmail. Used by Refresh.
    public func invalidateAll() {
        threads = [:]
        recency = []
        lists = [:]
        latestHistory = [:]
    }

    public func listThreadPage(labelIDs: [String], query: String?, max: Int, pageToken: String?) async throws -> ThreadPage {
        let key = "\(labelIDs.sorted())|\(query ?? "")|\(max)|\(pageToken ?? "")"
        if let hit = lists[key], Date().timeIntervalSince(hit.at) < listTTL { return hit.page }
        let page = try await base.listThreadPage(labelIDs: labelIDs, query: query, max: max, pageToken: pageToken)
        lists[key] = (Date(), page)
        for ref in page.refs { if let h = ref.historyId { latestHistory[ref.id] = h } }
        return page
    }

    /// Always fetches the full thread: it costs the same quota as metadata and serves every caller.
    public func thread(_ id: String, full: Bool) async throws -> GmailThread {
        if let cached = threads[id], isFresh(cached) { touch(id); return cached }
        if let running = inFlight[id] { return try await running.value }
        let task = Task { [base] in try await base.thread(id, full: true) }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        let thread = try await task.value
        threads[id] = thread
        touch(id)
        return thread
    }

    /// Bodies are the big part of the cache, so only the most recently used are kept in memory.
    private func touch(_ id: String) {
        recency.removeAll { $0 == id }
        recency.append(id)
        while recency.count > capacity { threads[recency.removeFirst()] = nil }
    }

    private func isFresh(_ thread: GmailThread) -> Bool {
        guard let known = latestHistory[thread.id], let have = thread.historyId else { return true }
        return known == have
    }

    public func labels() async throws -> [GmailLabel] { try await base.labels() }
    public func createLabel(_ name: String) async throws -> GmailLabel { try await base.createLabel(name) }
    public func threadCount(labelID: String) async throws -> Int { try await base.threadCount(labelID: labelID) }
    public func emailAddress() async throws -> String { try await base.emailAddress() }

    public func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        try await base.modifyThread(id, add: add, remove: remove)
        threads[id] = nil   // Its labels changed; any list that included it is stale too.
        recency.removeAll { $0 == id }
        lists = [:]
    }
}
