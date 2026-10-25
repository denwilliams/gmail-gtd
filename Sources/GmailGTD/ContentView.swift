import SwiftUI
import GTDCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.signedIn { MailView() } else { SignInView() }
        }
        .sheet(isPresented: Binding(get: { model.showingCategorisationSettings },
                                    set: { model.showingCategorisationSettings = $0 })) {
            CategorisationSettingsView().environment(model)
        }
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 16) {
            Image(systemName: "tray.full").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Gmail GTD").font(.largeTitle.bold())
            Text("Sign in with your Google Workspace account.").foregroundStyle(.secondary)
            Form {
                TextField("OAuth client ID", text: $model.clientID)
                SecureField("Client secret (optional)", text: $model.clientSecret)
            }
            .frame(width: 420)
            HStack {
                Button("Sign In") { Task { await model.signIn() } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Try Demo") { Task { await model.startDemo() } }
                    .controlSize(.large)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding(40)
    }
}

struct MailView: View {
    @Environment(AppModel.self) private var model
    /// The arrow keys always drive the email list; the sidebar is reached with ⌘0-⌘7.
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.folder) {
                sidebarRow("Today", Folder.today.symbol, .yellow, hint: "\u{2318}T").tag(Folder.today)
                Section("Process") {
                    sidebarRow("Inbox", Folder.inbox.symbol, .accentColor, hint: "\u{2318}0").tag(Folder.inbox)
                }
                Section("Local") {
                    sidebarRow("Corrections", Folder.corrections.symbol, .orange, hint: "").tag(Folder.corrections)
                }
                Section("GTD") {
                    ForEach(GTDBucket.allCases, id: \.self) { b in
                        sidebarRow(b.title, Folder.bucket(b).symbol, b.color, hint: "\u{2318}\(b.shortcut)").tag(Folder.bucket(b))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
            .focusable(false)
        } detail: {
            if let batch = model.deNoiseBatch {
                DeNoiseView(batch: batch)
            } else {
                switch model.folder {
                case .today: TodayView()
                case .corrections: CorrectionsView()
                case .bucket(.project): HStack(spacing: 0) { ProjectListView(focus: $listFocused); Divider(); ProjectDetailView() }
                default: HStack(spacing: 0) { ThreadListView(focus: $listFocused); Divider(); ThreadDetailView() }
                }
            }
        }
        .navigationTitle(model.folder.title)
        .navigationSubtitle(model.folder == .today ? "" : model.folder == .corrections ? "\(model.corrections.records.count) local corrections" : model.listSubtitle)
        .background(ApprovalShortcutHandler(model: model))
        .defaultFocus($listFocused, true)
        .onAppear { listFocused = true }
        // Switching folder or filing a thread replaces the focused row, which makes the list drop focus;
        // give it back once the list has settled so the arrow and number keys keep working.
        .onChange(of: model.folder) { _, _ in refocusList() }
        .onChange(of: model.rows) { _, _ in refocusList() }
        .overlay {
            if model.showShortcuts {
                ShortcutHUD().onTapGesture { model.shortcutsPinned = false }
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.showShortcuts)
        .overlay(alignment: .bottom) {
            if let move = model.undoToast {
                UndoToast(move: move)
                    .padding(.bottom, 44)   // clear of the key hint bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.undoToast?.id)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.folder != .today && model.folder != .corrections && model.deNoiseBatch == nil { KeyHintBar() }
                StatusBar()
            }
        }
        .toolbar {
            ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } } }
            ToolbarItem { Button("Categorisation Settings", systemImage: "slider.horizontal.3") { model.showingCategorisationSettings = true } }
            ToolbarItem { Button("Sign Out") { model.signOut() } }
        }
    }
}

extension MailView {
    fileprivate func refocusList() {
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            listFocused = true
        }
    }

    /// A sidebar row with a coloured icon and its ⌘ shortcut on the right.
    fileprivate func sidebarRow(_ title: String, _ symbol: String, _ color: Color, hint: String) -> some View {
        HStack {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            Spacer()
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A small, quiet confirmation of a move, with Undo. It is part of the window, never a system notification.
struct UndoToast: View {
    @Environment(AppModel.self) private var model
    let move: UndoMove

    var body: some View {
        let tint = move.destination?.color ?? .accentColor
        let symbol = move.destination.map { Folder.bucket($0).symbol } ?? Folder.inbox.symbol
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(move.summary).fontWeight(.medium)
            Text(move.subject).foregroundStyle(.secondary).lineLimit(1)
            Button("Undo") { Task { await model.undoLastMove() } }.buttonStyle(.link)
            Text("\u{2318}Z").font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        // Washed with the destination bucket's colour, so it registers at a glance.
        .background(.regularMaterial, in: Capsule())
        .background(tint.opacity(0.22), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .combine)
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.error {
            HStack(alignment: .top) {
                Text(error).font(.callout).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { model.error = nil }.buttonStyle(.link)
            }
            .padding(8).frame(maxWidth: .infinity).background(.bar)
        } else if let notice = model.notice {
            HStack {
                Text(notice).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { model.notice = nil }.buttonStyle(.link)
            }
            .padding(8).background(.bar)
        } else if model.demo {
            Text("Demo mode: sample mail, resets on relaunch").font(.caption).foregroundStyle(.secondary)
                .padding(6).frame(maxWidth: .infinity).background(.bar)
        }
    }
}

// MARK: - Thread list and detail (A)

struct ThreadListView: View {
    @Environment(AppModel.self) private var model
    var focus: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.folder == .inbox {
                VStack(alignment: .leading, spacing: 6) {
                    Button("De-noise Mode", systemImage: "speaker.slash") { model.startDeNoiseMode() }
                        .disabled(!model.canStartDeNoiseMode)
                    Text("Requires 10 inbox emails with ready Noise suggestions (\(model.deNoiseEligibleRows.count) ready).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            List(selection: $model.selection) {
                ForEach(model.rows) { row in RowView(row: row).tag(row.id) }
                if model.loadingMore {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
            }
            .overlay { if model.loading && model.rows.isEmpty { ProgressView() } }
            .focused(focus)
        }
        .frame(width: 340)
    }
}

struct RowView: View {
    @Environment(AppModel.self) private var model
    let row: ThreadRow

    var body: some View {
        let suggestion = model.localSuggestion(for: row.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.loaded ? row.from.displayName : "Sender name")
                    .fontWeight(row.unread ? .semibold : .regular).lineLimit(1)
                    .redacted(reason: row.loaded ? [] : .placeholder)
                Spacer()
                if model.isGenerating(row.id) { ProgressView().controlSize(.mini) }
                if let date = row.date { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
            }
            Text(row.loaded ? row.subject : "Subject line").lineLimit(1)
                .redacted(reason: row.loaded ? [] : .placeholder)
            // The on-device summary replaces the raw snippet once it is ready.
            Text(suggestion?.headline ?? row.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            rowTag(for: suggestion)
        }
        .padding(.vertical, 2)
        .onAppear { model.rowAppeared(row.id) }
        .onDisappear { model.rowDisappeared(row.id) }
    }
}

extension RowView {
    /// The inbox prefers Jev's category; filed buckets keep their on-device action text.
    @ViewBuilder fileprivate func rowTag(for suggestion: TriageSuggestion?) -> some View {
        switch model.folder {
        case .inbox:
            if let bucket = model.inboxBucket(for: row.id) { BucketChip(bucket: bucket) }
        case .bucket(.nextAction):
            if let nextAction = suggestion?.nextAction, !nextAction.isEmpty {
                Label(nextAction, systemImage: "arrow.right.circle")
                    .font(.caption.weight(.medium)).foregroundStyle(GTDBucket.nextAction.color).lineLimit(1)
            }
        case .bucket(.waitingFor):
            if let who = suggestion?.waitingOn {
                Label("Waiting on \(who)", systemImage: "hourglass")
                    .font(.caption.weight(.medium)).foregroundStyle(GTDBucket.waitingFor.color).lineLimit(1)
            }
        default:
            EmptyView()
        }
    }
}

struct ThreadDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let thread = model.detail {
            VStack(spacing: 0) {
                if model.folder == .inbox { TriageBar(threadID: thread.id) } else { BucketBar(threadID: thread.id) }
                if model.showsFiledJevStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.suggestion == nil, let note = model.aiNote {
                            Text("Local model: \(note)").font(.caption).foregroundStyle(.secondary)
                        }
                        ClassificationResultsView()
                        JevApprovalView()
                    }
                    .padding(.horizontal, 10).padding(.bottom, 8)
                }
                Picker("View", selection: Binding(get: { model.detailTab }, set: { model.chooseTab($0) })) {
                    Text("Summary").tag(DetailTab.summary)
                    Text("Original").tag(DetailTab.original)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                .padding(.vertical, 8)
                Divider()
                switch model.detailTab {
                case .summary: SummaryView(thread: thread)
                case .original: MessagesView(thread: thread)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Thread Selected", systemImage: "envelope").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MessagesView: View {
    let thread: GmailThread

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(thread.messages?.last?.subject ?? "").font(.title2.bold())
                ForEach(thread.messages ?? []) { m in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(m.from).font(.headline)
                        if let d = m.date { Text(d.formatted()).font(.caption).foregroundStyle(.secondary) }
                        Text(m.plainText.linkified).textSelection(.enabled)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The bar above a filed thread. The inbox is for deciding where mail goes; inside a bucket the job is
/// to finish the thing, or move it somewhere else.
struct BucketBar: View {
    @Environment(AppModel.self) private var model
    let threadID: String

    var body: some View {
        HStack {
            // Two ways to be finished with a thread: mark it Done, or keep it as Reference.
            if model.canFinish {
                Button { Task { await model.finishSelected() } } label: {
                    Label("Done", systemImage: Folder.bucket(.done).symbol)
                }
                .buttonStyle(.borderedProminent).tint(GTDBucket.done.color)
            }
            if model.currentBucket != .reference {
                Button { Task { await model.fileSelected(into: .reference) } } label: {
                    Label("Reference", systemImage: Folder.bucket(.reference).symbol)
                }
                .buttonStyle(BucketButtonStyle(color: GTDBucket.reference.color))
            }
            Menu {
                ForEach(GTDBucket.allCases.filter { $0 != model.currentBucket }, id: \.self) { b in
                    Button { Task { await model.fileSelected(into: b) } } label: { Text(verbatim: "\(b.shortcut)  \(b.title)") }
                }
                Divider()
                Button("Back to Inbox") { Task { await model.unfileSelected() } }
            } label: {
                Label("Move to", systemImage: "arrow.turn.up.right")
            }
            .fixedSize()
            Spacer()
            if model.suggesting { ProgressView().controlSize(.small) }
            Button { model.regenerateSelected() } label: { Label("Regenerate", systemImage: "sparkles").labelStyle(.iconOnly) }
                .help("Regenerate the summary (R)")
                .disabled(model.suggesting)
            Button { model.openInGmail(threadID) } label: { Label("Open in Gmail", systemImage: "arrow.up.forward.square").labelStyle(.iconOnly) }
                .help("Open in Gmail (O)")
        }
        .padding(10)
    }
}

/// The seven bucket buttons in whichever form fits: full names, short names, then numbers only.
struct BucketButtons: View {
    @Environment(AppModel.self) private var model

    private enum Form { case full, short, numbers }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.short)
            row(.numbers)
        }
    }

    private func row(_ form: Form) -> some View {
        HStack(spacing: 6) {
            ForEach(GTDBucket.allCases, id: \.self) { b in
                Button { Task { await model.fileSelected(into: b) } } label: {
                    switch form {
                    case .full: Text(verbatim: "\(b.shortcut) \(b.title)")
                    case .short: Text(verbatim: "\(b.shortcut) \(b.shortTitle)")
                    case .numbers: Text(verbatim: String(b.shortcut))
                    }
                }
                .buttonStyle(BucketButtonStyle(color: b.color))
                .help(Text(verbatim: "\(b.title) (\(b.shortcut))"))
            }
        }
    }
}

struct TriageBar: View {
    @Environment(AppModel.self) private var model
    let threadID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BucketButtons()
                Spacer(minLength: 0)
                // Secondary actions are icons, so the bucket buttons get the room.
                Button { model.regenerateSelected() } label: { Label("Regenerate", systemImage: "sparkles").labelStyle(.iconOnly) }
                    .help("Regenerate the summary and suggestion (R)")
                    .disabled(model.suggesting)
                Button { model.openInGmail(threadID) } label: { Label("Open in Gmail", systemImage: "arrow.up.forward.square").labelStyle(.iconOnly) }
                    .help("Open in Gmail (O)")
            }
            if model.suggesting && model.suggestion == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading thread…").foregroundStyle(.secondary) }
            } else if let note = model.aiNote, model.suggestion == nil {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            ClassificationResultsView()
            if let s = model.suggestion, !s.nextAction.isEmpty {
                Text("Next: \(s.nextAction)").foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Text(model.categorisationSettings.jevEnabled ? "Approve uses Jev. Manual filing is always available." : "Approve uses the local model.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Approve") { Task { await model.acceptSuggestion() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.approvalBucket == nil)
            }
        }
        .padding(10)
    }
}

/// The on-device summary of the open thread (Jev returns a category, not generated prose).
struct SummaryView: View {
    @Environment(AppModel.self) private var model
    let thread: GmailThread

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Inbox and active filed folders already show status above the tab picker.
            if model.folder != .inbox && !model.showsFiledJevStatus && model.suggestion == nil { JevStatusView() }
            summaryContent
        }
    }

    @ViewBuilder private var summaryContent: some View {
        if let s = model.suggestion {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(thread.messages?.last?.subject ?? "").font(.title2.bold())
                    Text(s.headline).font(.title3.weight(.semibold))
                    if !s.details.isEmpty { Text(s.details).font(.body).lineSpacing(3) }
                    if !s.nextAction.isEmpty { Label("Next: \(s.nextAction)", systemImage: "arrow.right.circle") }
                    if let w = s.waitingOn { Label("Waiting on \(w)", systemImage: "hourglass") }
                    ClassificationResultsView()
                    Text(participants).font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.suggesting {
            VStack(spacing: 10) {
                ProgressView()
                Text("Summarising…").foregroundStyle(.secondary)
                Text("The original is in the other tab.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Summary Yet", systemImage: "sparkles")
            } description: {
                Text(model.aiNote ?? "Summaries are made on this Mac when you open a thread in the inbox.")
            } actions: {
                Button("Summarise") { model.regenerateSelected() }
            }
        }
    }

    private var participants: String {
        let messages = thread.messages ?? []
        let names = messages.map(\.senderName)
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return "\(messages.count) message\(messages.count == 1 ? "" : "s") · \(unique.joined(separator: ", "))"
    }
}

// MARK: - Today (E)

private struct NextActionSummaryHelp: ViewModifier {
    let summary: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let summary {
            content.help(Text(verbatim: summary))
        } else {
            content
        }
    }
}

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Today").font(.largeTitle.bold())
                    Spacer()
                    Button("Open Gmail", systemImage: "arrow.up.forward.square") { model.openGmail() }
                    Button("Process Inbox") { model.folder = .inbox }.buttonStyle(.borderedProminent)
                }

                GroupBox("Digest") {
                    Group {
                        if model.digestLoading { ProgressView().controlSize(.small) }
                        else if let d = model.digest { Text(d) }
                        else { Text("Nothing to summarise yet.").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Next Actions") {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.nextActions.isEmpty { Text("None").foregroundStyle(.secondary) }
                            ForEach(model.nextActions) { row in
                                HStack {
                                    Button { Task { await model.finish(row) } } label: { Image(systemName: "circle") }
                                        .buttonStyle(.plain).help("Done: moves the thread to GTD/Done")
                                    Text(row.subject).lineLimit(1)
                                    Spacer()
                                    Text(row.from.displayName)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Button { model.openInGmail(row.id) } label: { Image(systemName: "arrow.up.forward.square") }
                                        .buttonStyle(.plain).help("Open in Gmail")
                                }
                                .contentShape(Rectangle())
                                .modifier(NextActionSummaryHelp(summary: model.nextActionSummary(for: row.id)))
                            }
                            Button("View all Next Actions  \u{2318}1") { model.folder = .bucket(.nextAction) }
                                .buttonStyle(.link).padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }

                    VStack(spacing: 16) {
                        GroupBox("Waiting For") {
                            VStack(alignment: .leading, spacing: 8) {
                                if model.waiting.isEmpty { Text("None").foregroundStyle(.secondary) }
                                ForEach(model.waiting) { row in
                                    HStack {
                                        Text(row.subject).lineLimit(1)
                                        Spacer()
                                        if let d = row.date { Text(d, style: .relative).font(.caption).foregroundStyle(.secondary) }
                                        Button { model.openInGmail(row.id) } label: { Image(systemName: "arrow.up.forward.square") }
                                            .buttonStyle(.plain).help("Open in Gmail")
                                    }
                                }
                                Button("View all Waiting For  \u{2318}2") { model.folder = .bucket(.waitingFor) }
                                    .buttonStyle(.link).padding(.top, 4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                        }
                        GroupBox("Inbox") {
                            Text("\(model.inboxCount) threads").frame(maxWidth: .infinity, alignment: .leading).padding(4)
                        }
                    }
                    .frame(width: 300)
                }
            }
            .padding(24)
        }
        .overlay { if model.loading && model.nextActions.isEmpty && model.waiting.isEmpty { ProgressView() } }
    }
}

// MARK: - Projects (H)

struct ProjectListView: View {
    @Environment(AppModel.self) private var model
    var focus: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.rows) { row in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.loaded ? row.subject : "Project subject").fontWeight(.semibold).lineLimit(1)
                        .redacted(reason: row.loaded ? [] : .placeholder)
                    Spacer()
                    if model.isGenerating(row.id) { ProgressView().controlSize(.mini) }
                }
                if let step = model.store.plan(for: row.id)?.steps.first {
                    Text("Next: \(step)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("No next action").font(.caption).foregroundStyle(.orange)
                }
            }
            .onAppear { model.rowAppeared(row.id) }
            .onDisappear { model.rowDisappeared(row.id) }
            .tag(row.id)
            }
            if model.loadingMore {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
        }
        .overlay { if model.loading && model.rows.isEmpty { ProgressView() } }
        .frame(width: 300)
        .focused(focus)
    }
}

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let thread = model.detail {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(thread.messages?.last?.subject ?? "").font(.title2.bold()).lineLimit(1)
                    Spacer()
                    Button { Task { await model.finishSelected() } } label: { Label("Done", systemImage: Folder.bucket(.done).symbol) }
                        .buttonStyle(.borderedProminent).tint(GTDBucket.done.color)
                    Button { Task { await model.fileSelected(into: .reference) } } label: {
                        Label("Reference", systemImage: Folder.bucket(.reference).symbol)
                    }
                    .buttonStyle(BucketButtonStyle(color: GTDBucket.reference.color))
                    if model.planning { ProgressView().controlSize(.small) }
                    Button("Regenerate", systemImage: "sparkles") { model.regenerateSelected() }
                        .disabled(model.planning)
                    Button("Open in Gmail", systemImage: "arrow.up.forward.square") { model.openInGmail(thread.id) }
                }
                .padding(10)
                if let note = model.aiNote, model.store.plan(for: thread.id) == nil {
                    Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                }
                if let plan = model.store.plan(for: thread.id) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan.summary).foregroundStyle(.secondary)
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                                Label(step, systemImage: "circle")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    .padding(.horizontal, 10)
                }
                Divider().padding(.top, 10)
                MessagesView(thread: thread)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Project Selected", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


// MARK: - Keyboard shortcuts

/// A keycap-styled label.
struct Key: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(.caption, design: .rounded).weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Always-visible one-line reminder of the main keys.
struct KeyHintBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            hint(["↑", "↓"], "move")
            if model.folder == .inbox {
                hint(["1", "–", "7"], "file")
                hint(["A"], "accept")
            } else {
                if model.canFinish { hint(["E"], "done") }
                hint(["4"], "reference")
                hint(["1", "–", "7"], "move to")
            }
            hint(["\u{2318}", "1", "–", "7"], "go to")
            hint(["O"], "open in Gmail")
            if !model.undoStack.isEmpty { hint(["\u{2318}", "Z"], "undo") }
            Spacer()
            Text("Hold ⌘ for all shortcuts").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func hint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in Key(k) }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Full cheat-sheet, shown while ⌘ is held or when pinned with ⌘/.
struct ShortcutHUD: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title3.bold())
            HStack(alignment: .top, spacing: 36) {
                group("Navigate", [
                    (["↑", "↓"], "Move through emails", nil),
                    (["\u{2318}", "0"], "Go to Inbox", nil),
                    (["\u{2318}", "T"], "Go to Today", nil),
                ] + GTDBucket.allCases.map { (["\u{2318}", String($0.shortcut)], "Go to \($0.title)", $0.color) })
                group("File the open thread", GTDBucket.allCases.map { ([String($0.shortcut)], $0.title, $0.color) } + [
                    (["0"], "Back to Inbox", nil),
                ])
                group("Thread", [
                    (["A"], "Accept the suggestion (Inbox)", nil),
                    (["E"], "Done: finished with it (same as 7)", nil),
                    (["R"], "Regenerate the suggestion", nil),
                    (["O"], "Open in Gmail", nil),
                    (["\u{2318}", "Z"], "Undo the last move", nil),
                    (["\u{2318}", "/"], "Pin or hide this list", nil),
                ])
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
        .padding(40)
    }

    private func group(_ title: String, _ rows: [([String], String, Color?)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    HStack(spacing: 3) { ForEach(Array(row.0.enumerated()), id: \.offset) { _, k in Key(k) } }
                        .frame(width: 64, alignment: .leading)
                    if let color = row.2 { Circle().fill(color).frame(width: 8, height: 8) }
                    Text(row.1)
                }
            }
        }
    }
}
