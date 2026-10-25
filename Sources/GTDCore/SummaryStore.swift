import Foundation
import Observation

/// What the list shows for a thread, kept so reopening the app doesn't refetch it.
public struct CachedHeader: Codable, Sendable, Equatable {
    public var from: String
    public var subject: String
    public var date: Date?
    public var unread: Bool

    public init(from: String, subject: String, date: Date?, unread: Bool) {
        self.from = from
        self.subject = subject
        self.date = date
        self.unread = unread
    }
}

/// Summaries, plans and list headers for recently seen threads, with least-recently-used eviction.
///
/// On-device summaries are slow to make and list headers cost Gmail quota, so both are kept between
/// launches. The oldest-used entries are dropped once `capacity` is exceeded. Nothing here is a source of
/// truth: an entry is discarded when its thread changes, and clearing it only costs a refetch.
@MainActor @Observable
public final class SummaryStore {
    struct Entry: Codable {
        /// Changes on any mailbox change to the thread, labels included. Guards the cached header.
        var historyId: String?
        /// Identifies the thread's messages (count and last id). Unlike `historyId` it survives filing, so
        /// a summary is kept when you move a thread between buckets, and dropped when a new reply arrives.
        var contentKey: String?
        var header: CachedHeader?
        var suggestion: TriageSuggestion?
        var categorisationPrompt: String?
        var plan: ProjectPlan?
        var lastUsed: Date
    }

    public static let defaultCapacity = 500

    private(set) var entries: [String: Entry] = [:]
    public let capacity: Int
    private let fileURL: URL?
    private var saveTask: Task<Void, Never>?

    public var count: Int { entries.count }

    /// `fileURL` nil keeps everything in memory (demo mode, tests).
    public init(fileURL: URL? = nil, capacity: Int = SummaryStore.defaultCapacity) {
        self.fileURL = fileURL
        self.capacity = capacity
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
            trim()
        }
    }

    /// Where the real mailbox's cache lives: `~/Library/Application Support/GmailGTD/summaries.json`.
    public static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "GmailGTD").appending(path: "summaries.json")
    }

    // MARK: Reading (safe to call from a view)

    public func suggestion(for id: String, prompt: String? = nil) -> TriageSuggestion? {
        guard let entry = entries[id] else { return nil }
        if let prompt, (entry.categorisationPrompt ?? TriagePrompts.local) != prompt { return nil }
        return entry.suggestion
    }
    public func plan(for id: String) -> ProjectPlan? { entries[id]?.plan }

    /// The cached list header, only if Gmail reports the thread unchanged since it was stored.
    public func header(for id: String, historyId: String?) -> CachedHeader? {
        guard let entry = entries[id], entry.historyId == historyId else { return nil }
        return entry.header
    }

    // MARK: Writing

    /// Marks a thread as just used, so it is the last to be evicted.
    public func touch(_ id: String) {
        guard entries[id] != nil else { return }
        entries[id]?.lastUsed = Date()
        scheduleSave()
    }

    /// Records a freshly fetched thread. A new reply discards the old summary and plan.
    public func note(_ thread: GmailThread, header: CachedHeader?) {
        let key = Self.contentKey(of: thread)
        var entry = entries[thread.id] ?? Entry(lastUsed: Date())
        if entry.contentKey != key { entry.suggestion = nil; entry.plan = nil }
        entry.contentKey = key
        entry.historyId = thread.historyId
        entry.header = header ?? entry.header
        entry.lastUsed = Date()
        entries[thread.id] = entry
        trim()
        scheduleSave()
    }

    public func setSuggestion(_ suggestion: TriageSuggestion?, for thread: GmailThread, prompt: String? = nil) {
        mutate(thread) { $0.suggestion = suggestion; $0.categorisationPrompt = prompt }
    }

    public func setPlan(_ plan: ProjectPlan?, for thread: GmailThread) {
        mutate(thread) { $0.plan = plan }
    }

    public func clearSuggestion(for id: String) { entries[id]?.suggestion = nil; scheduleSave() }
    public func clearPlan(for id: String) { entries[id]?.plan = nil; scheduleSave() }

    /// Forgets everything, including the file on disk. Used on sign-out.
    public func clear() {
        entries = [:]
        saveTask?.cancel()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    public func entriesContentKey(for id: String) -> String? { entries[id]?.contentKey }
    public static func contentKeyForCategorisation(_ thread: GmailThread) -> String { contentKey(of: thread) }

    // MARK: Internals

    static func contentKey(of thread: GmailThread) -> String {
        "\(thread.messages?.count ?? 0):\(thread.messages?.last?.id ?? "")"
    }

    private func mutate(_ thread: GmailThread, _ change: (inout Entry) -> Void) {
        var entry = entries[thread.id] ?? Entry(contentKey: Self.contentKey(of: thread), lastUsed: Date())
        change(&entry)
        entry.lastUsed = Date()
        entries[thread.id] = entry
        trim()
        scheduleSave()
    }

    /// Evicts the least recently used entries until the store fits.
    private func trim() {
        guard entries.count > capacity else { return }
        let oldest = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(entries.count - capacity)
        for (id, _) in oldest { entries[id] = nil }
    }

    /// Writes a moment after the last change, so a burst of results costs one write.
    private func scheduleSave() {
        guard let fileURL else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.writeNow(to: fileURL)
        }
    }

    func writeNow(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)   // summaries are private
    }

    /// Flushes any pending write immediately (tests, and app shutdown).
    public func flush() {
        saveTask?.cancel()
        if let fileURL { writeNow(to: fileURL) }
    }
}
