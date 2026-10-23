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
        case .bucket(.noise): "speaker.slash"
        case .bucket(.done): "checkmark.circle"
        }
    }
    static let mail: [Folder] = [.inbox] + GTDBucket.allCases.map(Folder.bucket)
}

enum DetailTab: Hashable { case summary, original }

struct ThreadRow: Identifiable, Hashable {
    let id: String
    let subject: String
    let from: String
    let snippet: String
    let date: Date?
    let unread: Bool
    /// False until the thread's headers have been fetched; the list shows the snippet meanwhile.
    var loaded = true
}

@MainActor @Observable
final class AppModel {
    var clientID = OAuthConfig.load()?.clientID ?? ""
    var clientSecret = OAuthConfig.load()?.clientSecret ?? ""
    var signedIn = TokenStore.load() != nil || AppModel.launchedInDemo
    var demo = false
    var notice: String?
    var folder: Folder = .today { didSet { guard folder != oldValue else { return }; Task { await folderChanged() } } }
    var rows: [ThreadRow] = []
    var selection: String? { didSet { guard selection != oldValue else { return }; Task { await loadDetail() } } }
    var detail: GmailThread?
    /// Summaries, plans and list headers for recent threads (LRU, kept between launches for a real mailbox).
    var store = SummaryStore()
    var detailTab: DetailTab = .original
    private var tabChosenByUser = false
    var aiNote: String?   // Why the on-device model produced nothing, shown inline rather than as an error.
    var suggestion: TriageSuggestion? { selection.flatMap { store.suggestion(for: $0) } }
    var loading = false
    var error: String?

    // Paging: the next page of the open folder, loaded as the user nears the end of the list.
    private(set) var nextPageToken: String?
    private(set) var loadingMore = false
    /// Demo mail is only 20 threads, so it pages in small steps to show how paging behaves.
    private var pageSize: Int { demo ? 8 : 50 }
    var hasMore: Bool { nextPageToken != nil }
    var listSubtitle: String { "\(rows.count)\(hasMore ? "+" : "") thread\(rows.count == 1 && !hasMore ? "" : "s")" }

    // Today
    var nextActions: [ThreadRow] = []
    var waiting: [ThreadRow] = []
    var inboxCount = 0
    var digest: String?
    var digestLoading = false

    // Projects

    // Keyboard shortcut overlay: pinned from the menu, or shown while ⌘ is held.
    var shortcutsPinned = false
    var shortcutsHeld = false
    var showShortcuts: Bool { shortcutsPinned || shortcutsHeld }
    private var holdTask: Task<Void, Never>?
    private var flagsMonitor: Any?


    private var client: (any MailService)?
    private var cache: CachedMailService?
    /// Threads whose fetch or model run failed; skipped so a bad thread can't be retried on every scroll.
    private var failed: Set<String> = []
    private var labels: LabelManager?
    private var labelIDs: [GTDBucket: String] = [:]
    private var email: String?
    private let triager = Triager()
    // On-device AI queue: threads waiting for a suggestion or plan, top of the list first.
    private(set) var pending: [String] = []
    private(set) var inflight: Set<String> = []
    private var visible: Set<String> = []
    private var enqueueTask: Task<Void, Never>?
    private var workers = 0
    /// Measured on-device: two concurrent requests are ~1.3x faster than one, four add little.
    private let maxWorkers = 1   // each suggestion is already two concurrent model requests

    var suggesting: Bool { folder != .bucket(.project) && isQueued(selection) }
    var planning: Bool { folder == .bucket(.project) && isQueued(selection) }
    func isQueued(_ id: String?) -> Bool { id.map { pending.contains($0) || inflight.contains($0) } ?? false }
    func isGenerating(_ id: String) -> Bool { inflight.contains(id) }

    // MARK: - Session

    /// Demo mode runs against in-memory sample mail: `--demo` or GMAIL_GTD_DEMO=1.
    static var launchedInDemo: Bool {
        CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["GMAIL_GTD_DEMO"] == "1"
    }

    func start() async {
        installModifierMonitor()
        if Self.launchedInDemo { await startDemo(); return }
        guard signedIn else { return }
        await connect()
    }

    /// Fresh sample mailbox each time; nothing is persisted, so relaunching resets it.
    func startDemo() async {
        error = nil
        demo = true
        signedIn = true
        await connect(using: DemoMailService(), persist: false)
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
        store.clear(); store = SummaryStore()   // Summaries are private: sign-out deletes them.
        signedIn = false; client = nil; cache = nil; labels = nil; email = nil
        rows = []; detail = nil; selection = nil; nextActions = []; waiting = []; digest = nil
    }

    private func connect() async {
        guard let config = OAuthConfig.load() else { error = GmailError.notConfigured.localizedDescription; return }
        do { await connect(using: try GmailClient(auth: GmailAuth(config: config)), persist: true) } catch { self.error = error.localizedDescription }
    }

    private func connect(using base: any MailService, persist: Bool) async {
        // Every read goes through the cache, so a thread is fetched once however many views want it.
        let client = CachedMailService(base)
        // Demo mail stays in memory so it resets on relaunch; a real mailbox keeps its summaries on disk.
        store = persist ? SummaryStore(fileURL: SummaryStore.defaultFileURL) : SummaryStore()
        do {
            let labels = LabelManager(client: client)
            labelIDs = try await labels.ensureLabels()
            self.client = client; self.cache = client; self.labels = labels
            email = try? await client.emailAddress()
            await folderChanged()
        } catch { self.error = error.localizedDescription }
    }

    private func folderChanged() async {
        selection = nil
        rows = []
        pending = []
        visible = []
        nextPageToken = nil
        if folder == .today { await loadToday() } else { await reload() }
    }

    // MARK: - Mail folders

    func reload() async {
        guard client != nil else { return }
        loading = true; defer { loading = false }
        do {
            let page = try await fetchPage(labelID: labelID(for: folder), max: pageSize, hydrate: false, pageToken: nil)
            rows = page.rows
            nextPageToken = page.next
            selectFirstIfNeeded()
            scheduleEnqueue()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Always have a thread open so the detail pane never sits empty while the list has mail.
    private func selectFirstIfNeeded() {
        if let selection, rows.contains(where: { $0.id == selection }) { return }
        selection = rows.first?.id
    }

    private func labelID(for folder: Folder) -> String {
        switch folder {
        case .today, .inbox: "INBOX"
        case .bucket(let b): labelIDs[b] ?? ""
        }
    }

    /// Lists threads as placeholder rows (the list call already carries each snippet). Headers are fetched
    /// later, only for rows on screen, unless `hydrate` asks for them now.
    private func fetchRows(labelID: String, max: Int, hydrate: Bool) async throws -> [ThreadRow] {
        try await fetchPage(labelID: labelID, max: max, hydrate: hydrate, pageToken: nil).rows
    }

    private func fetchPage(labelID: String, max: Int, hydrate: Bool, pageToken: String?) async throws -> (rows: [ThreadRow], next: String?) {
        guard let client else { return ([], nil) }
        let page = try await client.listThreadPage(labelIDs: [labelID], query: nil, max: max, pageToken: pageToken)
        let refs = page.refs
        // A header cached against the same historyId needs no request at all.
        var result = refs.map { ref -> ThreadRow in
            if let h = store.header(for: ref.id, historyId: ref.historyId) {
                return ThreadRow(id: ref.id, subject: h.subject, from: h.from, snippet: ref.snippet ?? "", date: h.date, unread: h.unread)
            }
            return ThreadRow(id: ref.id, subject: "", from: "", snippet: ref.snippet ?? "", date: nil, unread: false, loaded: false)
        }
        if hydrate {
            let threads = await fetchThreads(result.filter { !$0.loaded }.map(\.id))
            result = result.map { $0.loaded ? $0 : Self.row(for: threads[$0.id], placeholder: $0) }
        }
        return (result, page.nextPageToken)
    }

    /// Fetches a few threads at a time. Gmail bills per request, and the cache makes repeats free.
    private func fetchThreads(_ ids: [String]) async -> [String: GmailThread] {
        guard let client else { return [:] }
        var result: [String: GmailThread] = [:]
        for start in stride(from: 0, to: ids.count, by: 4) {
            let chunk = ids[start..<min(start + 4, ids.count)]
            await withTaskGroup(of: (String, GmailThread?).self) { group in
                for id in chunk { group.addTask { (id, try? await client.thread(id)) } }
                for await (id, thread) in group {
                    if let thread { result[id] = thread; note(thread) } else { failed.insert(id) }
                }
            }
        }
        return result
    }

    /// Remembers a fetched thread's list header and checks any cached summary against its messages.
    private func note(_ thread: GmailThread) {
        store.note(thread, header: Self.header(of: thread))
    }

    private static func header(of thread: GmailThread) -> CachedHeader? {
        guard let last = thread.messages?.last else { return nil }
        return CachedHeader(from: last.from, subject: last.subject, date: last.date,
                            unread: thread.messages?.contains { $0.isUnread } ?? false)
    }

    private static func row(for thread: GmailThread?, placeholder: ThreadRow) -> ThreadRow {
        guard let thread, let last = thread.messages?.last else { return placeholder }
        return ThreadRow(id: thread.id, subject: last.subject, from: last.from, snippet: placeholder.snippet,
                         date: last.date, unread: thread.messages?.contains { $0.isUnread } ?? false)
    }

    /// Fills in headers for the rows on screen that don't have them yet.
    private func hydrateVisible() async {
        let ids = rows.filter { !$0.loaded && visible.contains($0.id) && !failed.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        for (id, thread) in await fetchThreads(ids) { apply(thread, id: id) }
    }

    private func apply(_ thread: GmailThread, id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i] = Self.row(for: thread, placeholder: rows[i])
    }

    private func loadDetail() async {
        aiNote = nil
        guard let client, let id = selection else { detail = nil; return }
        // Show the summary straight away if there is one; otherwise the original until it is ready.
        tabChosenByUser = false
        detailTab = store.suggestion(for: id) != nil ? .summary : .original
        do {
            let thread = try await client.thread(id, full: true)
            guard selection == id else { return }   // The user has already moved on.
            note(thread)
            store.touch(id)
            detail = thread
            apply(thread, id: id)
            if store.suggestion(for: id) != nil, !tabChosenByUser { detailTab = .summary }   // note() may have dropped a stale one
            if aiFolder && !isDone(id) { prioritize(id) }
        } catch { if selection == id { self.error = error.localizedDescription } }
    }

    // MARK: - Shortcut overlay

    /// Watches the modifier keys so holding ⌘ for half a second reveals the shortcut cheat-sheet.
    private func installModifierMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let onlyCommand = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            MainActor.assumeIsolated { self?.commandHeld(onlyCommand) }
            return event
        }
    }

    private func commandHeld(_ held: Bool) {
        holdTask?.cancel()
        if held {
            holdTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { shortcutsHeld = true }
            }
        } else {
            shortcutsHeld = false
        }
    }

    func acceptSuggestion() async {
        guard let s = suggestion else { return }
        await fileSelected(into: s.bucket)
    }

    /// Refresh, and retry the connection if it never came up (for example, the Gmail API was off).
    func refresh() async {
        await cache?.invalidateAll()
        failed = []
        if client == nil && signedIn {
            error = nil
            if demo { await startDemo() } else { await connect() }
            return
        }
        if folder == .today { await loadToday() } else { await reload() }
    }

    func chooseTab(_ tab: DetailTab) {
        tabChosenByUser = true
        detailTab = tab
    }

    func openSelectedInGmail() {
        if let selection { openInGmail(selection) }
    }

    // MARK: - On-device AI

    /// Folders where the model works through the list on its own: triage in the inbox, plans in projects.
    private var aiFolder: Bool {
        switch folder {
        case .inbox, .bucket(.project), .bucket(.nextAction), .bucket(.waitingFor): true
        default: false
        }
    }

    private func isDone(_ id: String) -> Bool {
        folder == .bucket(.project) ? store.plan(for: id) != nil : store.suggestion(for: id) != nil
    }

    /// Rows currently on screen, reported by the list as they scroll in and out.
    func rowAppeared(_ id: String) {
        visible.insert(id)
        scheduleEnqueue()
        // Near the end of the list: fetch the next page before the user hits the bottom.
        if hasMore, rows.suffix(10).contains(where: { $0.id == id }) { Task { await loadMore() } }
    }

    /// Appends the next page of the open folder.
    func loadMore() async {
        guard let token = nextPageToken, !loadingMore, client != nil, folder != .today else { return }
        loadingMore = true; defer { loadingMore = false }
        let openFolder = folder
        do {
            let page = try await fetchPage(labelID: labelID(for: openFolder), max: pageSize, hydrate: false, pageToken: token)
            guard folder == openFolder else { return }   // the user has moved to another folder
            let known = Set(rows.map(\.id))
            rows += page.rows.filter { !known.contains($0.id) }
            nextPageToken = page.next
        } catch { self.error = error.localizedDescription }
    }
    func rowDisappeared(_ id: String) { visible.remove(id); scheduleEnqueue() }

    /// Waits for scrolling to settle, so rows flying past never start a model run.
    private func scheduleEnqueue() {
        enqueueTask?.cancel()
        enqueueTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.hydrateVisible()
            self.enqueueVisible()
        }
    }

    /// Queues the on-screen threads that have no result yet, top to bottom, with the open thread first.
    /// Anything that scrolled out of view before its turn is dropped from the queue.
    private func enqueueVisible() {
        guard aiFolder else { return }
        var ids = rows.map(\.id).filter { visible.contains($0) && !isDone($0) && !inflight.contains($0) && !failed.contains($0) }
        if let selection, !isDone(selection), !inflight.contains(selection) {
            ids.removeAll { $0 == selection }
            ids.insert(selection, at: 0)
        }
        pending = ids
        startWorkers()
    }

    /// Moves a thread to the front of the queue (the one the user is looking at).
    private func prioritize(_ id: String) {
        pending.removeAll { $0 == id }
        if !inflight.contains(id) { pending.insert(id, at: 0) }
        startWorkers()
    }

    private func startWorkers() {
        while workers < maxWorkers && !pending.isEmpty {
            workers += 1
            Task { await drain() }
        }
    }

    private func drain() async {
        defer { workers -= 1 }
        while !pending.isEmpty {
            guard let client else { pending.removeAll(); return }
            let id = pending.removeFirst()
            inflight.insert(id)
            await process(id, using: client)
            inflight.remove(id)
        }
    }

    private func process(_ id: String, using client: any MailService) async {
        let projects = folder == .bucket(.project)
        do {
            let thread = try await client.thread(id, full: true)
            note(thread)
            if projects { store.setPlan(try await triager.plan(for: thread), for: thread) }
            else {
                store.setSuggestion(try await triager.suggest(for: thread, me: email), for: thread)
                // The summary is ready: switch to it, unless the user chose a tab themselves.
                if id == selection && !tabChosenByUser { detailTab = .summary }
            }
        } catch let unavailable as TriageError {
            pending.removeAll()   // The model isn't there; don't retry it for every row.
            aiNote = unavailable.localizedDescription
        } catch {
            failed.insert(id)   // Skip this thread from now on; carry on with the rest.
            if id == selection { aiNote = error.localizedDescription }
        }
    }

    /// Re-runs the model for the open thread, ignoring any cached result.
    func regenerateSelected() {
        guard let id = selection else { return }
        if folder == .bucket(.project) { store.clearPlan(for: id) } else { store.clearSuggestion(for: id) }
        aiNote = nil
        tabChosenByUser = false
        detailTab = .original   // Back to the original while the new summary is made.
        failed.remove(id)
        prioritize(id)
    }

    func fileSelected(into bucket: GTDBucket) async {
        guard let labels, let id = selection, bucket != currentBucket else { return }   // already there
        do {
            try await labels.file(thread: id, into: bucket)
            removeRow(id)
        } catch { self.error = error.localizedDescription }
    }

    /// Any filed thread can be marked Done, except one that already is. (Reference is the other way to be
    /// finished with a thread: it keeps it where you can browse it.)
    var canFinish: Bool { currentBucket != nil && currentBucket != .done }

    /// The bucket being viewed, if any.
    var currentBucket: GTDBucket? {
        if case .bucket(let b) = folder { return b }
        return nil
    }

    /// Marks the open thread Done (the same as ticking it on Today): it moves to `GTD/Done`.
    func finishSelected() async {
        guard canFinish, let id = selection else { return }
        await fileSelected(into: .done)
        nextActions.removeAll { $0.id == id }
        waiting.removeAll { $0.id == id }
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
        pending.removeAll { $0 == id }   // No point summarising a thread that has just been filed.
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows.remove(at: i)
        selection = rows.indices.contains(i) ? rows[i].id : rows.last?.id
        // Filing shrinks the list. If it is now short, no new row will scroll into view to trigger the next page.
        if hasMore, rows.count < pageSize / 2 { Task { await loadMore() } }
    }

    // MARK: - Today

    func loadToday() async {
        guard let client else { return }
        loading = true; defer { loading = false }
        do {
            async let next = fetchRows(labelID: labelIDs[.nextAction] ?? "", max: 12, hydrate: true)
            async let wait = fetchRows(labelID: labelIDs[.waitingFor] ?? "", max: 12, hydrate: true)
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
    func finish(_ row: ThreadRow) async {
        guard let labels else { return }
        do {
            try await labels.file(thread: row.id, into: .done)
            nextActions.removeAll { $0.id == row.id }
            waiting.removeAll { $0.id == row.id }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: - Projects


    // MARK: - Gmail links

    func openInGmail(_ threadID: String) { open(GmailLinks.thread(threadID, account: email)) }

    func openGmail() { open(GmailLinks.inbox(account: email)) }

    private func open(_ url: URL) {
        if demo { notice = "Demo mode: this would open \(url.absoluteString)" } else { NSWorkspace.shared.open(url) }
    }
}
