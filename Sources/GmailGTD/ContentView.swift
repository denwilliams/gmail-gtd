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
            Button("Sign In") { Task { await model.signIn() } }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding(40)
    }
}

struct MailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Folder.all, selection: $model.folder) { folder in
                Label(folder.title, systemImage: folder.symbol).tag(folder)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } content: {
            List(model.rows, selection: $model.selection) { row in
                RowView(row: row).tag(row.id)
            }
            .navigationTitle(model.folder.title)
            .overlay { if model.loading && model.rows.isEmpty { ProgressView() } }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.reload() } }
            }
        } detail: {
            DetailView()
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).padding(8).frame(maxWidth: .infinity).background(.bar)
            }
        }
        .toolbar {
            ToolbarItem { Button("Sign Out") { model.signOut() } }
        }
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

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let thread = model.detail {
            VStack(spacing: 0) {
                TriageBar()
                Divider()
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
        } else {
            ContentUnavailableView("No Thread Selected", systemImage: "envelope")
        }
    }
}

struct TriageBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(GTDBucket.allCases, id: \.self) { b in
                    Button(verbatim: "\(b.shortcut) \(b.title)") { Task { await model.fileSelected(into: b) } }
                }
                Spacer()
                Button(model.suggesting ? "Thinking…" : "Suggest", systemImage: "sparkles") {
                    Task { await model.suggestForSelected() }
                }
                .disabled(model.suggesting)
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
