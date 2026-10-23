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

    /// Files a thread into a bucket: archives it from the inbox and clears any other GTD label.
    public func file(thread id: String, into bucket: GTDBucket) async throws {
        let all = try await ensureLabels()
        let others = all.filter { $0.key != bucket }.map(\.value)
        try await client.modifyThread(id, add: [all[bucket]!], remove: ["INBOX"] + others)
    }

    /// Takes a thread out of the GTD system: clears its GTD labels and leaves it archived, so it is
    /// out of every view but still found by Gmail search. (To keep it visible, file it as Reference.)
    public func archive(thread id: String) async throws {
        let all = try await ensureLabels()
        try await client.modifyThread(id, remove: Array(all.values))
    }

    /// Returns a thread to the inbox, clearing its GTD labels.
    public func unfile(thread id: String) async throws {
        let all = try await ensureLabels()
        try await client.modifyThread(id, add: ["INBOX"], remove: Array(all.values))
    }

    public func bucket(for labelIDs: [String]) -> GTDBucket? {
        ids.first { labelIDs.contains($0.value) }?.key
    }
}
