import SwiftUI
import GTDCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.signedIn { MailView() } else { SignInView() }
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

/// Keyboard focus targets, so left/right arrows can hop between the sidebar and the thread list.
enum Pane: Hashable { case sidebar, list }

struct MailView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focus: Pane?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.folder) {
                Label("Today", systemImage: Folder.today.symbol).tag(Folder.today)
                Section("Process") {
                    Label("Inbox", systemImage: Folder.inbox.symbol).tag(Folder.inbox)
                }
                Section("GTD") {
                    ForEach(GTDBucket.allCases, id: \.self) { b in
                        Label(b.title, systemImage: Folder.bucket(b).symbol).tag(Folder.bucket(b))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
            .focused($focus, equals: .sidebar)
            .onKeyPress(.rightArrow) {
                // Today has no list to move into.
                guard model.folder != .today, !model.rows.isEmpty else { return .ignored }
                focus = .list
                return .handled
            }
        } detail: {
            switch model.folder {
            case .today: TodayView()
            case .bucket(.project): HStack(spacing: 0) { ProjectListView(focus: $focus); Divider(); ProjectDetailView() }
            default: HStack(spacing: 0) { ThreadListView(focus: $focus); Divider(); ThreadDetailView() }
            }
        }
        .navigationTitle(model.folder.title)
        .defaultFocus($focus, .sidebar)
        .safeAreaInset(edge: .bottom) {
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).padding(8).frame(maxWidth: .infinity).background(.bar)
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
        .toolbar {
            ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.folderRefresh() } } }
            ToolbarItem { Button("Sign Out") { model.signOut() } }
        }
    }
}

extension AppModel {
    func folderRefresh() async {
        if folder == .today { await loadToday() } else { await reload() }
    }
}

// MARK: - Thread list and detail (A)

struct ThreadListView: View {
    @Environment(AppModel.self) private var model
    var focus: FocusState<Pane?>.Binding

    var body: some View {
        @Bindable var model = model
        List(model.rows, selection: $model.selection) { row in
            RowView(row: row).tag(row.id)
        }
        .overlay { if model.loading && model.rows.isEmpty { ProgressView() } }
        .frame(width: 340)
        .focused(focus, equals: .list)
        .onKeyPress(.leftArrow) { focus.wrappedValue = .sidebar; return .handled }
    }
}

struct RowView: View {
    let row: ThreadRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.from.components(separatedBy: " <").first ?? row.from)
                    .fontWeight(row.unread ? .semibold : .regular).lineLimit(1)
                Spacer()
                if let date = row.date { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
            }
            Text(row.subject).lineLimit(1)
            Text(row.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

struct ThreadDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let thread = model.detail {
            VStack(spacing: 0) {
                TriageBar(threadID: thread.id)
                Divider()
                MessagesView(thread: thread)
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
                        Text(m.plainText).textSelection(.enabled)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TriageBar: View {
    @Environment(AppModel.self) private var model
    let threadID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(GTDBucket.allCases, id: \.self) { b in
                    Button { Task { await model.fileSelected(into: b) } } label: { Text(verbatim: "\(b.shortcut) \(b.title)") }
                }
                Spacer()
                Button("Regenerate", systemImage: "sparkles") { model.regenerateSelected() }
                    .disabled(model.suggesting)
                Button("Open in Gmail", systemImage: "arrow.up.forward.square") { model.openInGmail(threadID) }
            }
            if model.suggesting && model.suggestion == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading thread…").foregroundStyle(.secondary) }
            } else if let note = model.aiNote, model.suggestion == nil {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let s = model.suggestion {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested: \(s.bucket.title)").font(.headline)
                        if !s.nextAction.isEmpty { Text("Next: \(s.nextAction)") }
                        if let w = s.waitingOn { Text("Waiting on: \(w)") }
                        Text(s.summary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Accept") { Task { await model.fileSelected(into: s.bucket) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
    }
}

// MARK: - Today (E)

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
                                    Button { Task { await model.complete(row) } } label: { Image(systemName: "circle") }
                                        .buttonStyle(.plain).help("Mark done")
                                    Text(row.subject).lineLimit(1)
                                    Spacer()
                                    Text(row.from.components(separatedBy: " <").first ?? row.from)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Button { model.openInGmail(row.id) } label: { Image(systemName: "arrow.up.forward.square") }
                                        .buttonStyle(.plain).help("Open in Gmail")
                                }
                            }
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
    var focus: FocusState<Pane?>.Binding

    var body: some View {
        @Bindable var model = model
        List(model.rows, selection: $model.selection) { row in
            VStack(alignment: .leading, spacing: 4) {
                Text(row.subject).fontWeight(.semibold).lineLimit(1)
                if let step = model.plans[row.id]?.steps.first {
                    Text("Next: \(step)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("No next action").font(.caption).foregroundStyle(.orange)
                }
            }
            .tag(row.id)
        }
        .overlay { if model.loading && model.rows.isEmpty { ProgressView() } }
        .frame(width: 300)
        .focused(focus, equals: .list)
        .onKeyPress(.leftArrow) { focus.wrappedValue = .sidebar; return .handled }
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
                    if model.planning { ProgressView().controlSize(.small) }
                    Button("Regenerate", systemImage: "sparkles") { model.regenerateSelected() }
                        .disabled(model.planning)
                    Button("Open in Gmail", systemImage: "arrow.up.forward.square") { model.openInGmail(thread.id) }
                }
                .padding(10)
                if let note = model.aiNote, model.plans[thread.id] == nil {
                    Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                }
                if let plan = model.plans[thread.id] {
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
