import Foundation
import CryptoKit

/// A digest of classification inputs, never credentials or labels. The complete message content is
/// included even when the provider transcript is truncated, so new replies/edits always invalidate it.
public struct JevClassificationKey: Codable, Hashable, Sendable {
    public let threadID: String
    public let fingerprint: String

    public init?(thread: GmailThread, mailbox: String, prompt: String,
                 model: String = JevClient.model, format: String = JevClient.classificationFormat) {
        let mailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !mailbox.isEmpty,
              let request = try? JevClient.request(thread, me: mailbox, prompt: prompt, token: "cache-key"),
              let body = request.httpBody else { return nil }
        struct Message: Encodable {
            let id: String
            let from: String
            let subject: String
            let text: String
        }
        struct Input: Encodable {
            let mailbox: String
            let threadID: String
            let messages: [Message]
            let request: Data
            let model: String
            let format: String
        }
        let messages = (thread.messages ?? []).map {
            Message(id: $0.id, from: $0.from, subject: $0.subject, text: $0.plainText)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Input(mailbox: mailbox, threadID: thread.id, messages: messages,
                                                   request: body, model: model, format: format)) else { return nil }
        self.threadID = thread.id
        self.fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Disposable, private, account-scoped LRU cache. Only successful categories/scores reach disk.
/// Main-actor isolation makes lookup + joining/starting work atomic across concurrent callers.
@MainActor
public final class JevClassificationStore {
    private struct Entry: Codable {
        let key: JevClassificationKey
        let bucket: GTDBucket
        let noiseLikelihood: Double?
        var lastUsed: Date
    }
    private struct File: Codable {
        var version = 1
        let entries: [String: Entry]
    }
    private final class Pending {
        let id = UUID()
        let task: Task<JevClassification, Error>
        var isValid = true
        init(task: Task<JevClassification, Error>) { self.task = task }
    }
    private var entries: [String: Entry] = [:]
    private var inFlight: [JevClassificationKey: Pending] = [:]
    private let fileURL: URL?
    private let capacity: Int

    public init(fileURL: URL? = nil, capacity: Int = 500) {
        self.fileURL = fileURL
        self.capacity = max(0, capacity)
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 {
            entries = file.entries
            trim()
        }
    }

    /// nil for an unidentified account: fail closed to session-only storage.
    public static func fileURL(for mailbox: String, directory: URL? = nil) -> URL? {
        let mailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !mailbox.isEmpty,
              let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "GmailGTD/JevClassifications") else { return nil }
        let hash = SHA256.hash(data: Data(mailbox.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: hash + ".json")
    }

    public func classification(for key: JevClassificationKey) -> JevClassification? {
        guard let entry = entries[key.threadID], entry.key == key else { return nil }
        entries[key.threadID]?.lastUsed = Date()
        return JevClassification(bucket: entry.bucket, noiseLikelihood: entry.noiseLikelihood)
    }

    public func resolve(_ key: JevClassificationKey,
                        operation: @escaping @Sendable () async throws -> JevClassification) async throws -> JevClassification {
        if let cached = classification(for: key) { return cached }
        if let running = inFlight[key] {
            let result = try await running.task.value
            // Eviction after completion must not invalidate joined work; explicit cancellation does.
            guard running.isValid else { throw CancellationError() }
            return result
        }
        let pending = Pending(task: Task { try await operation() })
        inFlight[key] = pending
        defer { if inFlight[key]?.id == pending.id { inFlight[key] = nil } }
        let result = try await pending.task.value
        // Sign-out/removal may happen during a provider call that ignores task cancellation.
        guard pending.isValid else { throw CancellationError() }
        entries[key.threadID] = Entry(key: key, bucket: result.bucket,
                                      noiseLikelihood: result.noiseLikelihood, lastUsed: Date())
        trim()
        save()
        return result
    }

    /// Explicit regeneration bypasses completed entries and cannot be refilled by older work.
    public func remove(for threadID: String) {
        entries[threadID] = nil
        for key in Array(inFlight.keys) where key.threadID == threadID {
            if let pending = inFlight.removeValue(forKey: key) {
                pending.isValid = false; pending.task.cancel()
            }
        }
        save()
    }

    public func cancelPending() {
        for pending in inFlight.values { pending.isValid = false; pending.task.cancel() }
        inFlight = [:]
    }

    /// Sign-out deletes completed results and fences late provider completions from recreating the file.
    public func clear() {
        cancelPending()
        entries = [:]
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func trim() {
        for (id, _) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(max(0, entries.count - capacity)) {
            entries[id] = nil
        }
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(File(entries: entries)) else { return }
        let parent = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { /* A disposable cache must never block triage or expose mail in diagnostics. */ }
    }
}
