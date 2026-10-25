import Foundation

/// Maps GTD buckets to Gmail label IDs, creating the labels on first use, and files threads between them.
public actor LabelManager {
    private let client: any MailService
    private var ids: [GTDBucket: String] = [:]

    public init(client: any MailService) { self.client = client }

    public func ensureLabels() async throws -> [GTDBucket: String] {
        if ids.count == GTDBucket.allCases.count { return ids }
        let existing = try await client.labels()
        for bucket in GTDBucket.allCases {
            if let hit = existing.first(where: { $0.name == bucket.labelName }) {
                ids[bucket] = hit.id
            } else {
                ids[bucket] = try await client.createLabel(bucket.labelName).id
            }
        }
        return ids
    }

    /// Files a thread into a bucket, clearing other GTD labels. Next Action, Waiting For and Someday
    /// belong in the inbox (even if previously archived); the remaining buckets are archived, never deleted.
    public func file(thread id: String, into bucket: GTDBucket) async throws {
        let all = try await ensureLabels()
        let others = all.filter { $0.key != bucket }.map(\.value)
        let keepInInbox = switch bucket {
        case .nextAction, .waitingFor, .someday: true
        case .reference, .noise, .project, .done: false
        }
        try await client.modifyThread(id,
                                      add: [all[bucket]!] + (keepInInbox ? ["INBOX"] : []),
                                      remove: others + (keepInInbox ? [] : ["INBOX"]))
    }

    /// Returns a thread to the inbox, clearing its GTD labels.
    public func unfile(thread id: String) async throws {
        let all = try await ensureLabels()
        try await client.modifyThread(id, add: ["INBOX"], remove: Array(all.values))
    }

    /// The labels this app manages (the inbox and every GTD bucket) among a thread's label IDs. Recorded before
    /// a move so the move can be undone exactly.
    public func managedLabels(in labelIDs: [String]) async throws -> Set<String> {
        let managed = Set(try await ensureLabels().values).union(["INBOX"])
        return Set(labelIDs).intersection(managed)
    }

    /// Sets a thread's managed labels back to a recorded set. Other labels (UNREAD, STARRED, yours) are left alone.
    public func restore(thread id: String, to previous: Set<String>) async throws {
        let managed = Set(try await ensureLabels().values).union(["INBOX"])
        try await client.modifyThread(id, add: Array(previous), remove: Array(managed.subtracting(previous)))
    }

    public func bucket(for labelIDs: [String]) -> GTDBucket? {
        ids.first { labelIDs.contains($0.value) }?.key
    }
}
