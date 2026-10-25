import Foundation
import Observation
import CryptoKit

public enum CorrectionSource: String, Codable, Sendable {
    case afm, jev
    public var title: String { self == .jev ? "Jev" : "AFM (Local model)" }
}

/// An immutable event, not a live classification. No message bodies or credentials are retained.
public struct CorrectionRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let threadID: String
    public let subject: String
    public let from: String
    public let recordedAt: Date
    public let chosenBucket: GTDBucket
    public let activeSource: CorrectionSource
    public let localBucket: GTDBucket?
    public let jevBucket: GTDBucket?
    public let localPrompt: String?
    public let jevPrompt: String?

    /// No active result means no known mismatch, even if the display has a fallback badge.
    public static func capture(id: UUID = UUID(), threadID: String, subject: String, from: String,
                               chosenBucket: GTDBucket, jevEnabled: Bool,
                               localBucket: GTDBucket?, jevBucket: GTDBucket?,
                               localPrompt: String?, jevPrompt: String?, recordedAt: Date = Date()) -> Self? {
        guard let active = jevEnabled ? jevBucket : localBucket, active != chosenBucket else { return nil }
        return Self(id: id, threadID: threadID, subject: subject, from: from, recordedAt: recordedAt,
                    chosenBucket: chosenBucket, activeSource: jevEnabled ? .jev : .afm,
                    localBucket: localBucket, jevBucket: jevBucket,
                    localPrompt: localBucket == nil ? nil : localPrompt,
                    jevPrompt: jevBucket == nil ? nil : jevPrompt)
    }

    /// A deterministic, local hypothesis grounded only in the captured instruction, never model reasoning.
    public var possibleExplanation: String {
        let prompt = activeSource == .jev ? jevPrompt : localPrompt
        let bucket = activeSource == .jev ? jevBucket : localBucket
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let bucket else {
            return "Possible explanation unavailable: the active model's prompt or result was unavailable. No prompt-related cause can be inferred."
        }
        let excerpt = String(prompt.prefix(240)) + (prompt.count > 240 ? "…" : "")
        return "Possible explanation: \(activeSource.title)'s instruction “\(excerpt)” may have been applied too broadly, or lacked the context behind choosing \(chosenBucket.title) instead of \(bucket.title). This is a hypothesis, not a verified cause or the model's reasoning."
    }
}

/// Durable, mailbox-isolated local history. Writes are immediate and atomic, not a disposable cache.
@MainActor @Observable
public final class CorrectionStore {
    public private(set) var records: [CorrectionRecord] = []
    public private(set) var persistenceError: String?
    private let fileURL: URL?
    private var loadFailed = false

    /// nil is memory-only, for demo or when the mailbox cannot be identified safely.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            records = try JSONDecoder().decode([CorrectionRecord].self, from: Data(contentsOf: fileURL))
                .sorted { $0.recordedAt > $1.recordedAt }
        } catch {
            loadFailed = true // Never overwrite an unreadable history with an empty one.
            persistenceError = "Local correction history could not be read. Existing history has not been overwritten."
        }
    }

    public static func fileURL(for mailbox: String, directory: URL? = nil) -> URL? {
        let mailbox = mailbox.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !mailbox.isEmpty,
              let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "GmailGTD/Corrections") else { return nil }
        let key = SHA256.hash(data: Data(mailbox.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: key + ".json")
    }

    public func append(_ record: CorrectionRecord) {
        guard !records.contains(where: { $0.id == record.id }) else { return }
        update(([record] + records).sorted { $0.recordedAt > $1.recordedAt })
    }

    public func remove(id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        update(records.filter { $0.id != id })
    }

    private func update(_ updated: [CorrectionRecord]) {
        // Keep useful in-session history even if the disk is unavailable; never block Gmail moves.
        records = updated
        guard let fileURL else { return }
        guard !loadFailed else { return }
        do {
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(updated)
            // The private directory also protects the temporary file during atomic replacement.
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            persistenceError = nil
        } catch {
            persistenceError = "Corrections are available for this session, but local history could not be saved."
        }
    }
}
