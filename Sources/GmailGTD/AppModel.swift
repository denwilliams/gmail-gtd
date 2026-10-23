import SwiftUI
import AppKit
import GTDCore

enum Folder: Hashable, Identifiable {
    case inbox
    case bucket(GTDBucket)

    var id: Self { self }
    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .bucket(let b): b.title
        }
    }
    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .bucket(.nextAction): "bolt"
        case .bucket(.waitingFor): "hourglass"
        case .bucket(.someday): "moon.zzz"
        case .bucket(.reference): "books.vertical"
        case .bucket(.project): "square.stack.3d.up"
        }
    }
    static let all: [Folder] = [.inbox] + GTDBucket.allCases.map(Folder.bucket)
}

struct ThreadRow: Identifiable, Hashable {
    let id: String
    let subject: String
    let from: String
    let snippet: String
    let date: Date?
    let unread: Bool
}

@MainActor @Observable
final class AppModel {
    var clientID = OAuthConfig.load()?.clientID ?? ""
    var clientSecret = OAuthConfig.load()?.clientSecret ?? ""
    var signedIn = TokenStore.load() != nil
    var folder: Folder = .inbox { didSet { Task { await reload() } } }
    var rows: [ThreadRow] = []
    var selection: String? { didSet { Task { await loadDetail() } } }
    var detail: GmailThread?
    var suggestion: TriageSuggestion?
    var suggesting = false
    var loading = false
    var error: String?

    private var client: GmailClient?
    private var labels: LabelManager?
    private var labelIDs: [GTDBucket: String] = [:]
    private let triager = Triager()

    func start() async {
        guard signedIn else { return }
        await connect()
    }

    func signIn() async {
        error = nil
        guard !clientID.isEmpty else { error = GmailError.notConfigured.localizedDescription; return }
        let config = OAuthConfig(clientID: clientID, clientSecret: clientSecret.isEmpty ? nil : clientSecret)
        config.save()
        do {
            _ = try await GmailAuth(config: config).signIn { NSWorkspace.shared.open($0) }
            signedIn = true
            await connect()
        } catch { self.error = error.localizedDescription }
    }

    func signOut() {
        TokenStore.clear()
        signedIn = false; client = nil; labels = nil; rows = []; detail = nil; selection = nil
    }

    private func connect() async {
        guard let config = OAuthConfig.load() else { error = GmailError.notConfigured.localizedDescription; return }
        do {
            let client = try GmailClient(auth: GmailAuth(config: config))
            let labels = LabelManager(client: client)
            labelIDs = try await labels.ensureLabels()
            self.client = client; self.labels = labels
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func reload() async {
        guard let client else { return }
        loading = true; defer { loading = false }
        do {
            let labelID: String = switch folder {
            case .inbox: "INBOX"
            case .bucket(let b): labelIDs[b] ?? ""
            }
            let refs = try await client.listThreads(labelIDs: [labelID], max: 40)
            // Fetch metadata concurrently, keeping the server's order.
            var fetched: [String: GmailThread] = [:]
            try await withThrowingTaskGroup(of: GmailThread.self) { group in
                for ref in refs { group.addTask { try await client.thread(ref.id) } }
                for try await t in group { fetched[t.id] = t }
            }
            rows = refs.compactMap { ref in
                guard let t = fetched[ref.id], let last = t.messages?.last else { return nil }
                return ThreadRow(id: t.id, subject: last.subject, from: last.from,
                                 snippet: ref.snippet ?? "", date: last.date,
                                 unread: t.messages?.contains { $0.isUnread } ?? false)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func loadDetail() async {
        suggestion = nil
        guard let client, let id = selection else { detail = nil; return }
        do { detail = try await client.thread(id, full: true) } catch { self.error = error.localizedDescription }
    }

    func suggestForSelected() async {
        guard let detail else { return }
        suggesting = true; defer { suggesting = false }
        do { suggestion = try await triager.suggest(for: detail) } catch { self.error = error.localizedDescription }
    }

    func fileSelected(into bucket: GTDBucket) async {
        guard let labels, let id = selection else { return }
        do {
            try await labels.file(thread: id, into: bucket)
            removeRow(id)
        } catch { self.error = error.localizedDescription }
    }

    func unfileSelected() async {
        guard let labels, let id = selection else { return }
        do {
            try await labels.unfile(thread: id)
            removeRow(id)
        } catch { self.error = error.localizedDescription }
    }

    /// Drops a processed row and moves the selection to the next one, as in an inbox-zero flow.
    private func removeRow(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows.remove(at: i)
        selection = rows.indices.contains(i) ? rows[i].id : rows.last?.id
    }
}
