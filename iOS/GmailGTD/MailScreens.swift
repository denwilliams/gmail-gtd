import SwiftUI
import GTDCore

/// Where the navigation stack can go. A thread screen follows the model's selection, so after filing it
/// shows the next thread in the list, the same as the Mac app.
enum Route: Hashable {
    case folder(Folder)
    case thread(String)
}

struct MailNavigation: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            MailboxesScreen()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .folder(.today): TodayScreen()
                    case .folder(let folder): FolderScreen(folder: folder)
                    case .thread(let id): ThreadScreen(threadID: id, path: $path)
                    }
                }
        }
        .overlay(alignment: .top) { MessageBanner() }
        .overlay(alignment: .bottom) {
            if let move = model.undoToast {
                UndoToast(move: move)
                    .padding(.bottom, path.last.map { if case .thread = $0 { true } else { false } } == true ? 84 : 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.undoToast?.id)
        #if DEBUG
        .task { await openDebugRoute() }
        #endif
    }

    #if DEBUG
    /// Debug builds only: `--route intray` (or `today`, `next`, …) opens that screen, and `--route intray/thread`
    /// also opens its first thread. For screenshots and checks without tapping through.
    private func openDebugRoute() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--route"), args.indices.contains(i + 1) else { return }
        let parts = args[i + 1].split(separator: "/").map(String.init)
        let named: [String: Folder] = ["today": .today, "intray": .inTray, "backlog": .backlog]
        guard let name = parts.first, let folder = named[name] ?? GTDBucket(cliName: name).map(Folder.bucket) else { return }
        try? await Task.sleep(for: .seconds(1))
        path = [.folder(folder)]
        guard parts.dropFirst().first == "thread" else { return }
        for _ in 0..<50 where model.folder != folder || model.rows.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        if let id = model.rows.first?.id { path.append(.thread(id)) }
    }
    #endif
}

// MARK: - Mailboxes

struct MailboxesScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            NavigationLink(value: Route.folder(.today)) {
                Label { Text("Today") } icon: { Image(systemName: Folder.today.symbol).foregroundStyle(.yellow) }
            }
            Section("Process") {
                NavigationLink(value: Route.folder(.inTray)) {
                    Label { Text("In-tray") } icon: { Image(systemName: Folder.inTray.symbol) }
                        .badge(model.inTrayCount)
                }
                NavigationLink(value: Route.folder(.backlog)) {
                    Label { Text("Backlog") } icon: { Image(systemName: Folder.backlog.symbol) }
                }
            }
            Section("Status") {
                ForEach(GTDBucket.allCases, id: \.self) { bucket in
                    NavigationLink(value: Route.folder(.bucket(bucket))) {
                        Label { Text(bucket.title) } icon: {
                            Image(systemName: Folder.bucket(bucket).symbol).foregroundStyle(bucket.color)
                        }
                    }
                }
            }
            if model.demo {
                Section { } footer: { Text("Demo mode: sample mail, resets on relaunch.") }
            }
        }
        .navigationTitle("Mail")
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Open Gmail", systemImage: "arrow.up.forward.square") { model.openGmail() }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { model.signOut() }
                }
            }
        }
    }
}

// MARK: - A folder's mail

struct FolderScreen: View {
    @Environment(AppModel.self) private var model
    let folder: Folder
    @State private var showingFilters = false

    var body: some View {
        List {
            ForEach(model.folder == folder ? model.rows : []) { row in
                NavigationLink(value: Route.thread(row.id)) { PhoneRow(row: row) }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipes(row) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingSwipes(row) }
                    .contextMenu { FileMenuItems(threadID: row.id) }
            }
            if model.loadingMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .navigationTitle(folder.title)
        .navigationSubtitle(model.folder == folder ? model.listSubtitle : "")
        .refreshable { await model.refresh() }
        .overlay { emptyState }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFilters = true
                } label: {
                    Label("Filters", systemImage: model.filter.isEmpty
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .badge(model.filter.isEmpty ? 0 : LabelFacet.allCases.reduce(0) { $0 + model.filter.count($1) })
            }
        }
        .sheet(isPresented: $showingFilters) { FilterSheet().environment(model) }
        .onAppear { if model.folder != folder { model.folder = folder } }
    }

    @ViewBuilder private var emptyState: some View {
        if model.folder != folder || (model.loading && model.rows.isEmpty) {
            ProgressView()
        } else if model.rows.isEmpty && !model.filter.isEmpty {
            ContentUnavailableView {
                Label("No Matching Mail", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing in \(folder.title) matches the filters.")
            } actions: {
                Button("Clear Filters") { model.clearFilters() }
            }
        } else if model.rows.isEmpty && folder == .backlog {
            ContentUnavailableView("No Backlog Mail", systemImage: Folder.backlog.symbol,
                                   description: Text("Apply the \(LabelManager.backlogLabelName) label in Gmail to process old mail here."))
        } else if model.rows.isEmpty {
            ContentUnavailableView("Nothing in \(folder.title)", systemImage: folder.symbol)
        }
    }

    /// Swipe right: the most common decisions. In the In-tray that is Next Action and Waiting For;
    /// inside a status it is Done (filed as Reference).
    @ViewBuilder private func leadingSwipes(_ row: ThreadRow) -> some View {
        if folder.isTriage {
            fileButton(.nextAction, row)
            fileButton(.waitingFor, row)
        } else if folder != .bucket(.reference) {
            Button { Task { await model.file(row.id, into: .reference) } } label: {
                Label("Done", systemImage: "checkmark.circle")
            }
            .tint(GTDBucket.reference.color)
        }
    }

    /// Swipe left: put it away. Noise first; the rest are in the long-press menu.
    @ViewBuilder private func trailingSwipes(_ row: ThreadRow) -> some View {
        if folder != .bucket(.noise) { fileButton(.noise, row) }
        if folder.isTriage {
            fileButton(.reference, row)
        } else {
            Button { Task { await model.unfile(row.id) } } label: { Label("In-tray", systemImage: Folder.inTray.symbol) }
                .tint(.accentColor)
        }
    }

    private func fileButton(_ bucket: GTDBucket, _ row: ThreadRow) -> some View {
        Button { Task { await model.file(row.id, into: bucket) } } label: {
            Label(bucket.shortTitle, systemImage: Folder.bucket(bucket).symbol)
        }
        .tint(bucket.color)
    }
}

/// Every status, for a long press on a row or the thread screen's Move menu.
struct FileMenuItems: View {
    @Environment(AppModel.self) private var model
    let threadID: String

    var body: some View {
        ForEach(GTDBucket.allCases.filter { $0 != model.currentBucket }, id: \.self) { bucket in
            Button { Task { await model.file(threadID, into: bucket) } } label: {
                Label(bucket.title, systemImage: Folder.bucket(bucket).symbol)
            }
        }
        if !model.folder.isTriage {
            Divider()
            Button("Back to In-tray", systemImage: Folder.inTray.symbol) { Task { await model.unfile(threadID) } }
        }
        Divider()
        Button("Open in Gmail", systemImage: "arrow.up.forward.square") { model.openInGmail(threadID) }
    }
}

struct PhoneRow: View {
    @Environment(AppModel.self) private var model
    let row: ThreadRow

    var body: some View {
        let suggestion = model.localSuggestion(for: row.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                if row.unread { Circle().fill(.tint).frame(width: 8, height: 8) }
                Text(row.loaded ? row.from.displayName : "Sender name")
                    .fontWeight(row.unread ? .semibold : .regular).lineLimit(1)
                    .redacted(reason: row.loaded ? [] : .placeholder)
                Spacer()
                if model.isGenerating(row.id) { ProgressView().controlSize(.mini) }
                if let date = row.date { Text(date, format: .relative(presentation: .numeric)).font(.caption).foregroundStyle(.secondary) }
            }
            Text(row.loaded ? row.subject : "Subject line").font(.subheadline).lineLimit(1)
                .redacted(reason: row.loaded ? [] : .placeholder)
            Text(suggestion?.headline ?? row.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            FacetSummary(labelIDs: row.labelIDs)
            tag(suggestion)
        }
        .padding(.vertical, 2)
        .onAppear { model.rowAppeared(row.id) }
        .onDisappear { model.rowDisappeared(row.id) }
    }

    @ViewBuilder private func tag(_ suggestion: TriageSuggestion?) -> some View {
        switch model.folder {
        case .inTray, .backlog:
            if let bucket = model.inboxBucket(for: row.id) { BucketChip(bucket: bucket) }
        case .bucket(.nextAction):
            if let next = suggestion?.nextAction, !next.isEmpty {
                Label(next, systemImage: "arrow.right.circle")
                    .font(.caption.weight(.medium)).foregroundStyle(GTDBucket.nextAction.color).lineLimit(1)
            }
        case .bucket(.waitingFor):
            if let who = suggestion?.waitingOn {
                Label("Waiting on \(who)", systemImage: "hourglass")
                    .font(.caption.weight(.medium)).foregroundStyle(GTDBucket.waitingFor.color).lineLimit(1)
            }
        case .bucket(.project):
            if let step = model.store.plan(for: row.id)?.steps.first {
                Label(step, systemImage: "arrow.right.circle")
                    .font(.caption.weight(.medium)).foregroundStyle(GTDBucket.project.color).lineLimit(1)
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Filters

/// The header filters as a sheet: OR within a family, AND across families.
struct FilterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(LabelFacet.allCases, id: \.self) { facet in
                    Section {
                        if facet.isSingle {
                            check("None", on: model.filter.includesNone.contains(facet)) { model.toggleNoneFilter(facet) }
                        }
                        ForEach(model.catalog.options(facet)) { option in
                            check(option.name, on: model.filter.contains(option.id, in: facet)) {
                                model.toggleFilter(option.id, in: facet)
                            }
                        }
                        if model.catalog.options(facet).isEmpty {
                            Text("No \(facet.emoji) labels in Gmail").foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            Text(verbatim: "\(facet.emoji) \(facet.title)")
                            Spacer()
                            if model.filter.count(facet) > 0 {
                                Button("Clear") { model.clearFilter(facet) }.font(.caption).textCase(nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear All") { model.clearFilters() }.disabled(model.filter.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func check(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }
}

// MARK: - Banners

struct MessageBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.error ?? model.notice {
            HStack(alignment: .top) {
                Text(text).font(.footnote).foregroundStyle(model.error != nil ? .red : .secondary).lineLimit(4)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { model.error = nil; model.notice = nil }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
        }
    }
}

struct UndoToast: View {
    @Environment(AppModel.self) private var model
    let move: UndoMove

    var body: some View {
        let tint = move.destination?.color ?? .accentColor
        let symbol = move.destination.map { Folder.bucket($0).symbol } ?? Folder.inTray.symbol
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(move.summary).fontWeight(.medium)
                Text(move.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Undo") { Task { await model.undoLastMove() } }.fontWeight(.semibold)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .background(tint.opacity(0.22), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 16)
    }
}
