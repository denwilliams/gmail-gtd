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

enum TodayList { case nextActions, waiting }

/// A move, with what is needed to take it back: the thread's inbox and GTD labels before, and the list row
/// that was taken off the screen (and where it sat), so undo can put it back at once.
struct UndoMove: Identifiable {
    let id = UUID()
    let threadID: String
    let subject: String
    /// Resolves after earlier moves finish, before this move changes any labels. Undo can be clicked meanwhile.
    let before: Task<Set<String>, Error>
    let summary: String
    /// The bucket it moved to, or nil for the inbox. Drives the toast's colour.
    let destination: GTDBucket?
    let origin: Folder
    let row: ThreadRow?
    let index: Int?
    let todayList: TodayList?
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
    var signedIn: Bool
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
    var categorisationSettings: CategorisationSettings
    var showingCategorisationSettings = false
    private var categorisationGeneration = UUID()
    private var localFailures: [String: String] = [:]
    private var jevResults: [String: JevState] = [:]
    /// A model-wide planning failure stays stopped until explicit retry/refresh, not every scroll.
    private var planningUnavailable: String?
    var suggestion: TriageSuggestion? { selection.flatMap { localSuggestion(for: $0) } }
    var jevState: JevState? { selection.flatMap { jevResults[$0] } }
    var approvalBucket: GTDBucket? {
        ApprovalPolicy.bucket(jevEnabled: categorisationSettings.jevEnabled, local: suggestion, jev: jevState)
    }

    /// Filed triage folders need Jev status above both tabs, even when no local summary exists.
    var showsFiledJevStatus: Bool {
        categorisationSettings.jevEnabled && (folder == .bucket(.nextAction) || folder == .bucket(.waitingFor))
    }
    var jevStatus: JevStatusPresentation? {
        categorisationSettings.jevEnabled ? JevStatusPresentation(state: jevState) : nil
    }

    /// Display-only fallback; approval still requires Jev success while Jev is enabled.
    func inboxBucket(for id: String) -> GTDBucket? {
        if categorisationSettings.jevEnabled, case .success(let bucket)? = jevResults[id] {
            return bucket
        }
        return localSuggestion(for: id)?.bucket
    }

    func localSuggestion(for id: String) -> TriageSuggestion? {
        store.suggestion(for: id, prompt: categorisationSettings.localPrompt)
    }

    func saveCategorisationSettings(_ settings: CategorisationSettings, token: String) throws {
        try settings.validate()
        try JevTokenStore.save(token)
        try settings.save()
        categorisationSettings = settings
        invalidateCategorisation()
        scheduleEnqueue()
    }

    private func invalidateCategorisation() {
        categorisationGeneration = UUID()
        jevResults = [:]
        localFailures = [:]
    }
    var loading = false
    var error: String?

    // Undo: the last few moves, newest last, and the one currently offered in the status bar.
    private(set) var undoStack: [UndoMove] = []
    private(set) var undoToast: UndoMove?
    private var toastTask: Task<Void, Never>?
    /// Gmail calls for moves run one after another, in the order the user made them.
    private var moveChain: Task<Void, Never>?
    private var quietRefreshTask: Task<Void, Never>?

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
    private let makePlan: @Sendable (GmailThread) async throws -> ProjectPlan
    private let categoriser: Categoriser
    private let loadJevToken: @Sendable () -> String?

    init(signedIn: Bool = TokenStore.load() != nil || AppModel.launchedInDemo,
         settings: CategorisationSettings = .load(), folder: Folder = .today,
         makePlan: @escaping @Sendable (GmailThread) async throws -> ProjectPlan = { try await Triager().plan(for: $0) },
         categoriser: Categoriser = Categoriser(),
         loadJevToken: @escaping @Sendable () -> String? = { JevTokenStore.load() }) {
        self.signedIn = signedIn
        self.categorisationSettings = settings
        self.folder = folder
        self.makePlan = makePlan
        self.categoriser = categoriser
        self.loadJevToken = loadJevToken
    }
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
        pending = []
        enqueueTask?.cancel()
        invalidateCategorisation()
        planningUnavailable = nil
        demo = false; notice = nil
        undoStack = []; undoToast = nil; quietRefreshTask?.cancel()
        store.clear(); store = SummaryStore()   // Summaries are private: sign-out deletes them.
        signedIn = false; client = nil; cache = nil; labels = nil; email = nil
        rows = []; detail = nil; selection = nil; nextActions = []; waiting = []; digest = nil
    }

    private func connect() async {
        guard let config = OAuthConfig.load() else {
            // Tokens can't be refreshed without the client ID, so ask for it rather than showing a dead mailbox.
            signedIn = false
            error = "Enter your OAuth client ID to continue."
            return
        }
        do { await connect(using: try GmailClient(auth: GmailAuth(config: config)), persist: true) } catch { self.error = error.localizedDescription }
    }

    // Internal for app-level tests against in-memory mail and injected model/provider implementations.
    func connect(using base: any MailService, persist: Bool) async {
        invalidateCategorisation()
        planningUnavailable = nil
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
        let previous = store.entriesContentKey(for: thread.id)
        store.note(thread, header: Self.header(of: thread))
        if previous != SummaryStore.contentKeyForCategorisation(thread) {
            jevResults[thread.id] = nil
            localFailures[thread.id] = nil
        }
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
        scheduleQuietRefresh()
        aiNote = nil
        guard let client, let id = selection else { detail = nil; return }
        // Show the summary straight away if there is one; otherwise the original until it is ready.
        tabChosenByUser = false
        detailTab = localSuggestion(for: id) != nil ? .summary : .original
        do {
            let thread = try await client.thread(id, full: true)
            guard selection == id else { return }   // The user has already moved on.
            note(thread)
            store.touch(id)
            detail = thread
            apply(thread, id: id)
            if localSuggestion(for: id) != nil, !tabChosenByUser { detailTab = .summary }   // note() may have dropped a stale one
            aiNote = folder == .bucket(.project) ? planningUnavailable : localFailures[id]
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
        guard let bucket = approvalBucket else { return }
        await fileSelected(into: bucket)
    }

    /// Refresh, and retry the connection if it never came up (for example, the Gmail API was off).
    func refresh() async {
        await cache?.invalidateAll()
        failed = []
        planningUnavailable = nil
        aiNote = nil
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
        if folder == .bucket(.project) { return store.plan(for: id) != nil || planningUnavailable != nil }
        let localDone = localSuggestion(for: id) != nil || localFailures[id] != nil
        return localDone && (!categorisationSettings.jevEnabled || jevResults[id]?.isFinished == true)
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
        guard aiFolder, signedIn else { return }
        var ids = rows.map(\.id).filter { visible.contains($0) && !isDone($0) && !inflight.contains($0) && !failed.contains($0) }
        if let selection, !isDone(selection), !inflight.contains(selection), !failed.contains(selection) {
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
            // Settings may have changed while this ID was excluded as in-flight.
            enqueueVisible()
        }
    }

    private func process(_ id: String, using client: any MailService) async {
        let projects = folder == .bucket(.project)
        let generation = categorisationGeneration
        do {
            let thread = try await client.thread(id, full: true)
            guard generation == categorisationGeneration, signedIn else { return }
            note(thread)
            if projects {
                let plan = try await makePlan(thread)
                guard generation == categorisationGeneration, signedIn else { return }
                store.setPlan(plan, for: thread)
            } else {
                let settings = categorisationSettings
                let key = SummaryStore.contentKeyForCategorisation(thread)
                if settings.jevEnabled { jevResults[id] = .pending }
                await categoriser.run(thread, me: email, settings: settings,
                                      token: settings.jevEnabled ? loadJevToken() : nil) { [weak self] event in
                    await self?.receive(event, for: thread, settings: settings, generation: generation, key: key)
                }
                if generation != categorisationGeneration { scheduleEnqueue() }
            }
        } catch let unavailable as TriageError {
            guard generation == categorisationGeneration, signedIn else { return }
            // Clearing pending alone isn't enough: drain re-enqueues visible/selected threads.
            if projects { planningUnavailable = unavailable.localizedDescription }
            pending.removeAll()
            aiNote = unavailable.localizedDescription
        } catch {
            failed.insert(id)   // Skip this thread from now on; carry on with the rest.
            if id == selection { aiNote = error.localizedDescription }
        }
    }

    private func receive(_ event: CategorisationEvent, for thread: GmailThread,
                         settings: CategorisationSettings, generation: UUID, key: String) {
        // Sign-out, settings edits, or a newer reply invalidate an in-flight result.
        guard generation == categorisationGeneration,
              store.entriesContentKey(for: thread.id) == key else { return }
        switch event {
        case .local(let suggestion):
            store.setSuggestion(suggestion, for: thread, prompt: settings.localPrompt)
            localFailures[thread.id] = nil
            if thread.id == selection && !tabChosenByUser { detailTab = .summary }
        case .localFailure(let message):
            localFailures[thread.id] = message
            if thread.id == selection { aiNote = message }
        case .jev(let bucket): jevResults[thread.id] = .success(bucket)
        case .jevFailure(let message): jevResults[thread.id] = .failure(message)
        }
    }

    /// Re-runs the model for the open thread, ignoring any cached result.
    func regenerateSelected() {
        guard let id = selection, !isQueued(id) else { return }
        if folder == .bucket(.project) {
            planningUnavailable = nil
            store.clearPlan(for: id)
        } else { store.clearSuggestion(for: id) }
        jevResults[id] = nil
        localFailures[id] = nil
        aiNote = nil
        tabChosenByUser = false
        detailTab = .original   // Back to the original while the new summary is made.
        failed.remove(id)
        prioritize(id)
    }

    func fileSelected(into bucket: GTDBucket) async {
        guard let id = selection, bucket != currentBucket else { return }   // already there
        move(id, to: .bucket(bucket), summary: "Moved to \(bucket.title)")
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
        guard canFinish else { return }
        await fileSelected(into: .done)
    }

    func unfileSelected() async {
        guard let id = selection else { return }
        move(id, to: .inbox, summary: "Moved back to Inbox")
    }

    // MARK: - Moving threads
    //
    // A move happens on screen at once: the row goes, the next thread is selected and a small toast appears.
    // The Gmail call follows in the background. If Gmail refuses, the row comes back with an error. A quiet
    // refresh after a pause confirms the list matches Gmail.

    private enum Destination { case bucket(GTDBucket), inbox }

    private func move(_ id: String, to destination: Destination, summary: String) {
        guard let labels, let client else { return }
        let previous = moveChain
        let before = Task {
            await previous?.value
            let thread = try await client.thread(id, full: false)
            return try await labels.managedLabels(in: thread.messages?.flatMap { $0.labelIds ?? [] } ?? [])
        }
        let subject = [detail?.id == id ? detail?.messages?.last?.subject : nil,
                       rows.first { $0.id == id }?.subject,
                       nextActions.first { $0.id == id }?.subject,
                       waiting.first { $0.id == id }?.subject]
            .compactMap { $0 }.first { !$0.isEmpty } ?? "(no subject)"
        let removed = removeLocally(id)
        let target: GTDBucket? = if case .bucket(let b) = destination { b } else { nil }
        let move = UndoMove(threadID: id, subject: subject, before: before, summary: summary, destination: target,
                            origin: folder, row: removed.row, index: removed.index, todayList: removed.list)
        remember(move)
        enqueueRemote { [weak self] in
            do {
                _ = try await before.value   // Never move mail without an undo snapshot.
                switch destination {
                case .bucket(let bucket): try await labels.file(thread: id, into: bucket)
                case .inbox: try await labels.unfile(thread: id)
                }
            } catch { self?.moveFailed(move, error) }
        }
        scheduleQuietRefresh()
    }

    private func enqueueRemote(_ work: @escaping @MainActor () async -> Void) {
        let previous = moveChain
        moveChain = Task { await previous?.value; await work() }
    }

    /// Takes a thread off the screen now, and selects the next one.
    private func removeLocally(_ id: String) -> (row: ThreadRow?, index: Int?, list: TodayList?) {
        pending.removeAll { $0 == id }   // No point summarising a thread that has just been filed.
        var result: (row: ThreadRow?, index: Int?, list: TodayList?) = (nil, nil, nil)
        if let i = nextActions.firstIndex(where: { $0.id == id }) {
            let row = nextActions.remove(at: i)
            if folder == .today { result = (row, i, .nextActions) }
        }
        if let i = waiting.firstIndex(where: { $0.id == id }) {
            let row = waiting.remove(at: i)
            if folder == .today { result = (row, i, .waiting) }
        }
        if folder != .today, let i = rows.firstIndex(where: { $0.id == id }) {
            result = (rows.remove(at: i), i, nil)
            selection = rows.indices.contains(i) ? rows[i].id : rows.last?.id
            // Filing shrinks the list. If it is now short, no new row will scroll into view to trigger the next page.
            if hasMore, rows.count < pageSize / 2 { Task { await loadMore() } }
        }
        return result
    }

    /// Puts a removed row back where it was, if we are still looking at the list it came from.
    private func reinsertLocally(_ move: UndoMove) {
        guard let row = move.row, let index = move.index else { return }
        if folder == .today, let list = move.todayList {
            switch list {
            case .nextActions where !nextActions.contains { $0.id == row.id }: nextActions.insert(row, at: min(index, nextActions.count))
            case .waiting where !waiting.contains { $0.id == row.id }: waiting.insert(row, at: min(index, waiting.count))
            default: break
            }
        } else if folder != .today, folder == move.origin, !rows.contains(where: { $0.id == row.id }) {
            rows.insert(row, at: min(index, rows.count))
            selection = row.id
        }
    }

    private func remember(_ move: UndoMove) {
        undoStack.append(move)
        if undoStack.count > 20 { undoStack.removeFirst() }
        undoToast = move
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.undoToast?.id == move.id else { return }
            self.undoToast = nil   // the toast goes; ⌘Z still works
        }
    }

    /// Gmail refused the move: bring the thread back and say so.
    private func moveFailed(_ move: UndoMove, _ error: Error) {
        undoStack.removeAll { $0.id == move.id }
        if undoToast?.id == move.id { undoToast = nil }
        reinsertLocally(move)
        self.error = "Couldn\u{2019}t move \u{201C}\(move.subject)\u{201D}: \(error.localizedDescription)"
    }

    /// Puts the most recently moved thread back, on screen at once and on Gmail in the background.
    func undoLastMove() async {
        guard let move = undoStack.popLast(), let labels else { return }
        toastTask?.cancel()
        undoToast = nil
        reinsertLocally(move)
        let backOnScreen = folder == .today ? move.todayList != nil : folder == move.origin
        if !backOnScreen { notice = "Put \u{201C}\(move.subject)\u{201D} back where it was" }
        enqueueRemote { [weak self] in
            do {
                let before = try await move.before.value
                try await labels.restore(thread: move.threadID, to: before)
            } catch {
                self?.error = "Couldn\u{2019}t undo the move of \u{201C}\(move.subject)\u{201D}: \(error.localizedDescription)"
                await self?.refreshQuietly()
            }
        }
        scheduleQuietRefresh()
    }

    /// After a pause with no moves or browsing, make sure the list really matches Gmail.
    private func scheduleQuietRefresh() {
        quietRefreshTask?.cancel()
        quietRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await self?.refreshQuietly()
        }
    }

    func refreshQuietly() async {
        await moveChain?.value   // let our own changes reach Gmail first
        guard client != nil, !loading, !loadingMore else { return }
        if folder == .today { await loadToday(); return }
        // If the user has scrolled through several pages, replacing them would jerk the list; leave it alone.
        guard rows.count <= pageSize + 10 else { return }
        let openFolder = folder
        do {
            let page = try await fetchPage(labelID: labelID(for: openFolder), max: pageSize, hydrate: false, pageToken: nil)
            guard folder == openFolder else { return }
            let old = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Keep rows we already have headers for, so nothing flashes back to a placeholder.
            rows = page.rows.map { new in old[new.id].flatMap { $0.loaded ? $0 : nil } ?? new }
            nextPageToken = page.next
            selectFirstIfNeeded()
            scheduleEnqueue()
        } catch {
            // A failed background refresh isn't worth interrupting anyone for; the next one will try again.
        }
    }

    // MARK: - Today

    /// Cached text only: hovering must not fetch mail or start a model request.
    func nextActionSummary(for id: String) -> String? {
        guard let summary = localSuggestion(for: id)?.summary
            .trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        return summary
    }

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
        move(row.id, to: .bucket(.done), summary: "Marked done")
    }

    // MARK: - Projects


    // MARK: - Gmail links

    func openInGmail(_ threadID: String) { open(GmailLinks.thread(threadID, account: email)) }

    func openGmail() { open(GmailLinks.inbox(account: email)) }

    private func open(_ url: URL) {
        if demo { notice = "Demo mode: this would open \(url.absoluteString)" } else { NSWorkspace.shared.open(url) }
    }
}
