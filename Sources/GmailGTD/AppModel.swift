import SwiftUI
import AppKit
import GTDCore

enum Folder: Hashable, Identifiable {
    case today
    case inbox
    case bucket(GTDBucket)

    var id: Self { self }
    var title: String {
        switch self {
        case .today: "Today"
        case .inbox: "Inbox"
        case .bucket(let b): b.title
        }
    }
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .inbox: "tray"
        case .bucket(.nextAction): "bolt"
        case .bucket(.waitingFor): "hourglass"
        case .bucket(.someday): "moon.zzz"
        case .bucket(.reference): "books.vertical"
        case .bucket(.project): "square.stack.3d.up"
        }
    }
    static let mail: [Folder] = [.inbox] + GTDBucket.allCases.map(Folder.bucket)
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
    var signedIn = TokenStore.load() != nil || AppModel.launchedInDemo
    var demo = false
    var notice: String?
    var folder: Folder = .today { didSet { Task { await folderChanged() } } }
    var rows: [ThreadRow] = []
    var selection: String? { didSet { Task { await loadDetail() } } }
    var detail: GmailThread?
    var suggestion: TriageSuggestion?
    var suggesting = false
    var loading = false
    var error: String?

    // Today
    var nextActions: [ThreadRow] = []
    var waiting: [ThreadRow] = []
    var inboxCount = 0
    var digest: String?
    var digestLoading = false

    // Projects
    var plans: [String: ProjectPlan] = [:]
    var planning = false

    private var client: (any MailService)?
    private var labels: LabelManager?
    private var labelIDs: [GTDBucket: String] = [:]
    private var email: String?
    private let triager = Triager()

    // MARK: - Session

    /// Demo mode runs against in-memory sample mail: `--demo` or GMAIL_GTD_DEMO=1.
    static var launchedInDemo: Bool {
        CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["GMAIL_GTD_DEMO"] == "1"
    }

    func start() async {
        if Self.launchedInDemo { await startDemo(); return }
        guard signedIn else { return }
        await connect()
    }

    /// Fresh sample mailbox each time; nothing is persisted, so relaunching resets it.
    func startDemo() async {
        error = nil
        demo = true
        signedIn = true
        await connect(using: DemoMailService())
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
        if !demo { TokenStore.clear() }
        demo = false; notice = nil
        signedIn = false; client = nil; labels = nil; email = nil
        rows = []; detail = nil; selection = nil; nextActions = []; waiting = []; digest = nil
    }

    private func connect() async {
        guard let config = OAuthConfig.load() else { error = GmailError.notConfigured.localizedDescription; return }
        do { await connect(using: try GmailClient(auth: GmailAuth(config: config))) } catch { self.error = error.localizedDescription }
    }

    private func connect(using client: any MailService) async {
        do {
            let labels = LabelManager(client: client)
            labelIDs = try await labels.ensureLabels()
            self.client = client; self.labels = labels
            email = try? await client.emailAddress()
            await folderChanged()
        } catch { self.error = error.localizedDescription }
    }

    private func folderChanged() async {
        selection = nil
        if folder == .today { await loadToday() } else { await reload() }
    }

    // MARK: - Mail folders

    func reload() async {
        guard client != nil else { return }
        loading = true; defer { loading = false }
        do {
            rows = try await fetchRows(labelID: labelID(for: folder), max: 40)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func labelID(for folder: Folder) -> String {
        switch folder {
        case .today, .inbox: "INBOX"
        case .bucket(let b): labelIDs[b] ?? ""
        }
    }

    /// Lists threads then fetches their metadata concurrently, keeping the server's order.
    private func fetchRows(labelID: String, max: Int) async throws -> [ThreadRow] {
        guard let client else { return [] }
        let refs = try await client.listThreads(labelIDs: [labelID], max: max)
        var fetched: [String: GmailThread] = [:]
        try await withThrowingTaskGroup(of: GmailThread.self) { group in
            for ref in refs { group.addTask { try await client.thread(ref.id) } }
            for try await t in group { fetched[t.id] = t }
        }
        return refs.compactMap { ref in
            guard let t = fetched[ref.id], let last = t.messages?.last else { return nil }
            return ThreadRow(id: t.id, subject: last.subject, from: last.from,
                             snippet: ref.snippet ?? "", date: last.date,
                             unread: t.messages?.contains { $0.isUnread } ?? false)
        }
    }

    private func loadDetail() async {
        suggestion = nil
        guard let client, let id = selection else { detail = nil; return }
        do { detail = try await client.thread(id, full: true) } catch { self.error = error.localizedDescription }
    }

    func suggestForSelected() async {
        guard let detail else { return }
        suggesting = true; defer { suggesting = false }
        do { suggestion = try await triager.suggest(for: detail, me: email) } catch { self.error = error.localizedDescription }
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

    // MARK: - Today

    func loadToday() async {
        guard let client else { return }
        loading = true; defer { loading = false }
        do {
            async let next = fetchRows(labelID: labelIDs[.nextAction] ?? "", max: 12)
            async let wait = fetchRows(labelID: labelIDs[.waitingFor] ?? "", max: 12)
            async let count = client.threadCount(labelID: "INBOX")
            (nextActions, waiting, inboxCount) = try await (next, wait, count)
            error = nil
        } catch { self.error = error.localizedDescription; return }
        await refreshDigest()
    }

    func refreshDigest() async {
        guard !nextActions.isEmpty || !waiting.isEmpty else { digest = nil; return }
        digestLoading = true; defer { digestLoading = false }
        do {
            digest = try await triager.digest(nextActions: nextActions.map(\.subject), waitingFor: waiting.map(\.subject))
        } catch { digest = nil }   // The digest is a nicety; the lists stand on their own.
    }

    /// Ticks off a Next Action: clears its GTD label and leaves it archived.
    func complete(_ row: ThreadRow) async {
        guard let labels else { return }
        do {
            try await labels.complete(thread: row.id)
            nextActions.removeAll { $0.id == row.id }
            waiting.removeAll { $0.id == row.id }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: - Projects

    func planSelected() async {
        guard let detail, let id = selection else { return }
        planning = true; defer { planning = false }
        do { plans[id] = try await triager.plan(for: detail) } catch { self.error = error.localizedDescription }
    }

    // MARK: - Gmail links

    func openInGmail(_ threadID: String) { open(GmailLinks.thread(threadID, account: email)) }

    func openGmail() { open(GmailLinks.inbox(account: email)) }

    private func open(_ url: URL) {
        if demo { notice = "Demo mode: this would open \(url.absoluteString)" } else { NSWorkspace.shared.open(url) }
    }
}
