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
        } detail: {
            switch model.folder {
            case .today: TodayView()
            case .bucket(.project): HStack(spacing: 0) { ProjectListView(focus: $focus); Divider(); ProjectDetailView() }
            default: HStack(spacing: 0) { ThreadListView(focus: $focus); Divider(); ThreadDetailView() }
            }
        }
        .navigationTitle(model.folder.title)
        .defaultFocus($focus, .sidebar)
        .onChange(of: focus) { _, pane in model.focusedPane = pane }
        .onChange(of: model.focusRequest) { _, pane in
            guard let pane else { return }
            focus = pane
            model.focusRequest = nil
        }
        .overlay {
            if model.showShortcuts {
                ShortcutHUD().onTapGesture { model.shortcutsPinned = false }
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.showShortcuts)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.folder != .today { KeyHintBar() }
                StatusBar()
            }
        }
        .toolbar {
            ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } } }
            ToolbarItem { Button("Sign Out") { model.signOut() } }
        }
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
    @Environment(AppModel.self) private var model
    let row: ThreadRow

    var body: some View {
        let suggestion = model.suggestions[row.id]
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.from.components(separatedBy: " <").first ?? row.from)
                    .fontWeight(row.unread ? .semibold : .regular).lineLimit(1)
                Spacer()
                if model.isGenerating(row.id) { ProgressView().controlSize(.mini) }
                if let date = row.date { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
            }
            Text(row.subject).lineLimit(1)
            // The on-device summary replaces the raw snippet once it is ready.
            Text(suggestion?.summary ?? row.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let suggestion {
                Text(suggestion.bucket.title)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .onAppear { model.rowAppeared(row.id) }
        .onDisappear { model.rowDisappeared(row.id) }
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
                HStack {
                    Text(row.subject).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    if model.isGenerating(row.id) { ProgressView().controlSize(.mini) }
                }
                if let step = model.plans[row.id]?.steps.first {
                    Text("Next: \(step)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("No next action").font(.caption).foregroundStyle(.orange)
                }
            }
            .onAppear { model.rowAppeared(row.id) }
            .onDisappear { model.rowDisappeared(row.id) }
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
    var body: some View {
        HStack(spacing: 14) {
            hint(["↑", "↓"], "move")
            hint(["←", "→"], "switch pane")
            hint(["1", "–", "5"], "file")
            hint(["A"], "accept")
            hint(["O"], "open in Gmail")
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
                    (["↑", "↓"], "Move through categories or threads"),
                    (["←", "→"], "Switch between categories and threads"),
                ])
                group("File the open thread", GTDBucket.allCases.map { ([String($0.shortcut)], $0.title) } + [
                    (["0"], "Back to Inbox"),
                ])
                group("Thread", [
                    (["A"], "Accept the suggestion"),
                    (["R"], "Regenerate the suggestion"),
                    (["O"], "Open in Gmail"),
                    (["⌘", "/"], "Pin or hide this list"),
                ])
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
        .padding(40)
    }

    private func group(_ title: String, _ rows: [([String], String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    HStack(spacing: 3) { ForEach(Array(row.0.enumerated()), id: \.offset) { _, k in Key(k) } }
                        .frame(width: 56, alignment: .leading)
                    Text(row.1)
                }
            }
        }
    }
}
