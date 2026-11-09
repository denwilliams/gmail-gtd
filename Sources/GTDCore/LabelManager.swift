import Foundation

/// Maps 🚦 statuses to Gmail label IDs, creating them on first use, and files threads between them.
/// Also reads the 🏢 Source, 🗂️ Classification, 🏷️ Tag and 🎯 Project labels, which it never creates.
public actor LabelManager {
    private let client: any MailService
    private var ids: [GTDBucket: String] = [:]
    private var inTrayID: String?

    public init(client: any MailService) { self.client = client }

    /// The processing queue (the app's In-tray view). Named so it is not confused with Gmail's own Inbox.
    public static let inTrayLabelName = "\(GTDBucket.labelPrefix)/In-tray"

    /// The Gmail label for the Backlog queue. It sits with the statuses under `🚦/`, but is not a destination.
    public static let backlogLabelName = "\(GTDBucket.labelPrefix)/Backlog"

    /// Creates any missing status labels (and In-tray), and returns the status label IDs.
    public func ensureLabels() async throws -> [GTDBucket: String] {
        if ids.count == GTDBucket.allCases.count, inTrayID != nil { return ids }
        let existing = try await client.labels()
        func find(_ name: String) -> GmailLabel? {
            existing.first { LabelFacet.normalised($0.name) == LabelFacet.normalised(name) }
        }
        func resolve(_ name: String) async throws -> String {
            if let hit = find(name) { return hit.id }
            return try await client.createLabel(name).id
        }
        for bucket in GTDBucket.allCases where ids[bucket] == nil {
            ids[bucket] = try await resolve(bucket.labelName)
        }
        if inTrayID == nil { inTrayID = try await resolve(Self.inTrayLabelName) }
        return ids
    }

    public func inTrayLabelID() async throws -> String {
        _ = try await ensureLabels()
        return inTrayID!
    }

    /// Backlog is a user-managed processing queue, not a final status. Never create it on read.
    /// Resolve on demand so a label created in Gmail after launch appears on the next refresh.
    public func backlogLabelID() async throws -> String? {
        try await client.labels().first {
            LabelFacet.normalised($0.name) == LabelFacet.normalised(Self.backlogLabelName)
        }?.id
    }

    /// Every Source, Classification, Tag and Project label currently in Gmail.
    public func catalog() async throws -> LabelCatalog {
        LabelCatalog(labels: try await client.labels())
    }

    /// Files a thread under a status, clearing In-tray, Backlog and any other status. Next Action, Waiting For
    /// and Someday belong in the Gmail Inbox (even if previously archived); the rest are archived, never deleted.
    public func file(thread id: String, into bucket: GTDBucket) async throws {
        let all = try await ensureLabels()
        let queues = try await queueLabelIDs()
        let others = all.filter { $0.key != bucket }.map(\.value) + queues
        let keepInInbox = bucket.keepsInInbox
        try await client.modifyThread(id,
                                      add: [all[bucket]!] + (keepInInbox ? ["INBOX"] : []),
                                      remove: others + (keepInInbox ? [] : ["INBOX"]))
    }

    /// Puts a thread back in the In-tray (and the Gmail Inbox), clearing its status and Backlog.
    public func unfile(thread id: String) async throws {
        let all = try await ensureLabels()
        let inTray = try await inTrayLabelID()
        let backlog = try await backlogLabelID().map { [$0] } ?? []
        try await client.modifyThread(id, add: [inTray, "INBOX"], remove: Array(all.values) + backlog)
    }

    /// Sets one facet's labels on a thread: adds `values` and removes the facet's other options. Labels outside
    /// the facet are left alone. A single-value facet takes at most one value.
    public func setFacet(_ facet: LabelFacet, of thread: String, to values: Set<String>, catalog: LabelCatalog) async throws {
        let options = Set(catalog.options(facet).map(\.id))
        let valid = values.intersection(options)
        let add = facet.isSingle ? Set(valid.sorted().prefix(1)) : valid
        try await client.modifyThread(thread, add: Array(add), remove: Array(options.subtracting(add)))
    }

    /// The labels this app manages when filing (Inbox, In-tray, Backlog and every status) among a thread's
    /// label IDs. Recorded before a move so the move can be undone exactly.
    public func managedLabels(in labelIDs: [String]) async throws -> Set<String> {
        Set(labelIDs).intersection(try await managedLabelIDs())
    }

    /// Sets a thread's managed labels back to a recorded set. Other labels (UNREAD, STARRED, Source, Tags…)
    /// are left alone.
    public func restore(thread id: String, to previous: Set<String>) async throws {
        let managed = try await managedLabelIDs()
        try await client.modifyThread(id, add: Array(previous), remove: Array(managed.subtracting(previous)))
    }

    private func queueLabelIDs() async throws -> [String] {
        try await [inTrayLabelID()] + (backlogLabelID().map { [$0] } ?? [])
    }

    private func managedLabelIDs() async throws -> Set<String> {
        let buckets = try await ensureLabels()
        return Set(buckets.values).union(["INBOX"]).union(try await queueLabelIDs())
    }

    public func bucket(for labelIDs: [String]) -> GTDBucket? {
        ids.first { labelIDs.contains($0.value) }?.key
    }
}
