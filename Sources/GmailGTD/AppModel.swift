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
    var suggestions: [String: TriageSuggestion] = [:]
    var aiNote: String?   // Why the on-device model produced nothing, shown inline rather than as an error.
    var suggestion: TriageSuggestion? { selection.flatMap { suggestions[$0] } }
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

    // Keyboard shortcut overlay: pinned from the menu, or shown while ⌘ is held.
    var shortcutsPinned = false
    var shortcutsHeld = false
    var showShortcuts: Bool { shortcutsPinned || shortcutsHeld }
    private var holdTask: Task<Void, Never>?
    private var flagsMonitor: Any?
    private var keyMonitor: Any?

    // Which pane has keyboard focus (mirrored from the view), and a request for the view to move it.
    var focusedPane: Pane?
    var lastFocusedPane: Pane = .sidebar
    var focusRequest: Pane?

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
    private let maxWorkers = 2

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
        signedIn = false; client = nil; cache = nil; labels = nil; email = nil
        rows = []; detail = nil; selection = nil; nextActions = []; waiting = []; digest = nil
    }

    private func connect() async {
        guard let config = OAuthConfig.load() else { error = GmailError.notConfigured.localizedDescription; return }
        do { await connect(using: try GmailClient(auth: GmailAuth(config: config))) } catch { self.error = error.localizedDescription }
    }

    private func connect(using base: any MailService) async {
        // Every read goes through the cache, so a thread is fetched once however many views want it.
        let client = CachedMailService(base)
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
        if folder == .today { await loadToday() } else { await reload() }
    }

    // MARK: - Mail folders

    func reload() async {
        guard client != nil else { return }
        loading = true; defer { loading = false }
        do {
            rows = try await fetchRows(labelID: labelID(for: folder), max: 40, hydrate: false)
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
        guard let client else { return [] }
        let refs = try await client.listThreads(labelIDs: [labelID], max: max)
        var result = refs.map {
            ThreadRow(id: $0.id, subject: "", from: "", snippet: $0.snippet ?? "", date: nil, unread: false, loaded: false)
        }
        if hydrate {
            let threads = await fetchThreads(result.map(\.id))
            result = result.map { Self.row(for: threads[$0.id], placeholder: $0) }
        }
        return result
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
                    if let thread { result[id] = thread } else { failed.insert(id) }
                }
            }
        }
        return result
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
        do {
            let thread = try await client.thread(id, full: true)
            guard selection == id else { return }   // The user has already moved on.
            detail = thread
            apply(thread, id: id)
            if aiFolder && !isDone(id) { prioritize(id) }
        } catch { if selection == id { self.error = error.localizedDescription } }
    }

    // MARK: - Shortcut overlay

    /// Watches the modifier keys so holding ⌘ for half a second reveals the shortcut cheat-sheet.
    private func installModifierMonitor() {
        installKeyMonitor()
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let onlyCommand = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            MainActor.assumeIsolated { self?.commandHeld(onlyCommand) }
            return event
        }
    }

    /// The sidebar is an AppKit outline view that consumes the right arrow (its "expand" key) before
    /// SwiftUI sees it, so catch that one key early and hand focus to the thread list ourselves.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let rightArrow: UInt16 = 124
            let typingModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            guard event.keyCode == rightArrow, event.modifierFlags.intersection(typingModifiers).isEmpty else { return event }
            let handled = MainActor.assumeIsolated { self?.moveFocusToList() ?? false }
            return handled ? nil : event
        }
    }

    private func moveFocusToList() -> Bool {
        // Today has no list to move into.
        guard focusedPane == .sidebar, folder != .today, !rows.isEmpty else { return false }
        focusRequest = .list
        return true
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

    func openSelectedInGmail() {
        if let selection { openInGmail(selection) }
    }

    // MARK: - On-device AI

    /// Folders where the model works through the list on its own: triage in the inbox, plans in projects.
    private var aiFolder: Bool { folder == .inbox || folder == .bucket(.project) }

    private func isDone(_ id: String) -> Bool {
        folder == .bucket(.project) ? plans[id] != nil : suggestions[id] != nil
    }

    /// Rows currently on screen, reported by the list as they scroll in and out.
    func rowAppeared(_ id: String) { visible.insert(id); scheduleEnqueue() }
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
            if projects { plans[id] = try await triager.plan(for: thread) }
            else { suggestions[id] = try await triager.suggest(for: thread, me: email) }
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
        if folder == .bucket(.project) { plans[id] = nil } else { suggestions[id] = nil }
        aiNote = nil
        failed.remove(id)
        prioritize(id)
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
        pending.removeAll { $0 == id }   // No point summarising a thread that has just been filed.
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows.remove(at: i)
        selection = rows.indices.contains(i) ? rows[i].id : rows.last?.id
        keepListFocus()
    }

    /// Removing the focused row makes the list drop keyboard focus. If the user was working in the list,
    /// give it back after the list has settled, so they can keep filing with the number keys.
    private func keepListFocus() {
        guard lastFocusedPane == .list else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            focusRequest = .list
        }
    }

    // MARK: - Today

    func loadToday() async {
        guard let client else { return }
        loading = true; defer { loading = false }
        do {
            async let next = fetchRows(labelID: labelIDs[.nextAction] ?? "", max: 8, hydrate: true)
            async let wait = fetchRows(labelID: labelIDs[.waitingFor] ?? "", max: 8, hydrate: true)
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


    // MARK: - Gmail links

    func openInGmail(_ threadID: String) { open(GmailLinks.thread(threadID, account: email)) }

    func openGmail() { open(GmailLinks.inbox(account: email)) }

    private func open(_ url: URL) {
        if demo { notice = "Demo mode: this would open \(url.absoluteString)" } else { NSWorkspace.shared.open(url) }
    }
}
