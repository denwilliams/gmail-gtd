import SwiftUI
import GTDCore

/// One thread: its labels, the suggestion, the summary or original, and a bar of status buttons.
/// Filing moves straight on to the next thread in the list, so the In-tray can be processed in one go.
struct ThreadScreen: View {
    @Environment(AppModel.self) private var model
    let threadID: String
    @Binding var path: [Route]
    @State private var opened = false

    var body: some View {
        Group {
            if let thread = model.detail, thread.id == model.selection {
                content(thread)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Actions", systemImage: "ellipsis") {
                    if let id = model.selection {
                        Button("Regenerate Summary", systemImage: "sparkles") { model.regenerateSelected() }
                            .disabled(model.suggesting || model.planning)
                        Button("Open in Gmail", systemImage: "arrow.up.forward.square") { model.openInGmail(id) }
                        if !model.folder.isTriage && model.folder != .today {
                            Button("Back to In-tray", systemImage: Folder.inTray.symbol) { act { await model.unfileSelected() } }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { filingBar }
        .task {
            guard !opened else { return }
            opened = true
            if model.selection != threadID { model.selection = threadID }
        }
        // The last thread in the list was filed: back to the (now empty) list.
        .onChange(of: model.selection) { _, selection in if selection == nil { pop() } }
    }

    private func content(_ thread: GmailThread) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(thread.messages?.last?.subject ?? "(no subject)").font(.title3.bold())
                PhoneFacetEditor()
                if model.folder.isTriage { suggestionCard }
                else if model.showsFiledJevStatus { ClassificationResultsView().font(.footnote) }
                if model.folder == .bucket(.project) {
                    projectPlan(thread)
                    Divider()
                    PhoneMessages(thread: thread)
                } else {
                    Picker("View", selection: Binding(get: { model.detailTab }, set: { model.chooseTab($0) })) {
                        Text("Summary").tag(DetailTab.summary)
                        Text("Original").tag(DetailTab.original)
                    }
                    .pickerStyle(.segmented)
                    switch model.detailTab {
                    case .summary: PhoneSummary(thread: thread)
                    case .original: PhoneMessages(thread: thread)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// In the In-tray and Backlog: what the models suggest, and one tap to accept it.
    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.suggesting && model.suggestion == nil {
                HStack(spacing: 8) { ProgressView(); Text("Reading thread…").foregroundStyle(.secondary) }
            } else if let note = model.aiNote, model.suggestion == nil {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            ClassificationResultsView().font(.footnote)
            if let s = model.suggestion, !s.nextAction.isEmpty {
                Text("Next: \(s.nextAction)").font(.footnote).foregroundStyle(.secondary)
            }
            if let bucket = model.approvalBucket {
                Button { act { await model.acceptSuggestion() } } label: {
                    Label("Approve: \(bucket.title)", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(bucket.color)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func projectPlan(_ thread: GmailThread) -> some View {
        if let plan = model.store.plan(for: thread.id) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.summary).foregroundStyle(.secondary)
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in Label(step, systemImage: "circle") }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
        } else if model.planning {
            HStack(spacing: 8) { ProgressView(); Text("Planning…").foregroundStyle(.secondary) }
        } else if let note = model.aiNote {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The iPhone's number keys: every status in a two-row grid, with Done first inside a status.
    private var filingBar: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            if model.canFinish || (model.folder == .today && model.selection != nil) {
                Button { act { await done() } } label: { Label("Done", systemImage: "checkmark.circle") }
                    .buttonStyle(PhoneBucketButtonStyle(color: GTDBucket.reference.color, prominent: true))
            }
            // Inside a status, Done is how a thread reaches Reference.
            ForEach(GTDBucket.allCases.filter { $0 != model.currentBucket && !(model.canFinish && $0 == .reference) }, id: \.self) { bucket in
                Button { act { await model.fileSelected(into: bucket) } } label: {
                    Label(bucket.shortTitle, systemImage: Folder.bucket(bucket).symbol)
                }
                .buttonStyle(PhoneBucketButtonStyle(color: bucket.color))
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .disabled(model.detail?.id != model.selection)
    }

    private func done() async {
        if model.folder == .today, let id = model.selection {
            if let row = (model.nextActions + model.waiting).first(where: { $0.id == id }) { await model.finish(row) }
            else { await model.file(id, into: .reference) }
        } else {
            await model.finishSelected()
        }
    }

    /// Today's lists don't move on to another thread, so filing from there goes back to Today.
    private func act(_ work: @escaping @MainActor () async -> Void) {
        Task {
            await work()
            if model.folder == .today { pop() }
        }
    }

    private func pop() {
        if case .thread = path.last { path.removeLast() }
    }
}

struct PhoneBucketButtonStyle: ButtonStyle {
    let color: Color
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.verticalCompact)
            .foregroundStyle(prominent ? Color.white : color)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(prominent ? color.opacity(configuration.isPressed ? 0.7 : 1) : color.opacity(configuration.isPressed ? 0.3 : 0.15),
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// An icon over a short caption, like a tab bar item.
struct VerticalCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon.font(.body)
            configuration.title.font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

extension LabelStyle where Self == VerticalCompactLabelStyle {
    static var verticalCompact: VerticalCompactLabelStyle { .init() }
}

/// Classification and Source (one each), Tags and Projects (any number). Changing them never moves the thread.
struct PhoneFacetEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            single(.classification)
            single(.source)
            multiple(.tag)
            multiple(.project)
        }
    }

    private func single(_ facet: LabelFacet) -> some View {
        Menu {
            Picker(facet.title, selection: Binding(get: { model.values(facet).first?.id },
                                                  set: { model.setSingle(facet, to: $0) })) {
                Text("No \(facet.title)").tag(String?.none)
                ForEach(model.catalog.options(facet)) { option in Text(option.name).tag(Optional(option.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            chip(facet, model.values(facet).first?.name)
        }
        .tint(.primary)
    }

    private func multiple(_ facet: LabelFacet) -> some View {
        let current = model.values(facet)
        return Menu {
            ForEach(model.catalog.options(facet)) { option in
                Toggle(option.name, isOn: Binding(get: { current.contains(option) },
                                                  set: { _ in model.toggle(option.id, in: facet) }))
            }
            if model.catalog.options(facet).isEmpty {
                Text("Create \(facet.emoji)/… labels in Gmail to use \(facet.title.lowercased())")
            }
        } label: {
            chip(facet, current.isEmpty ? nil : current.map(\.name).joined(separator: ", "))
        }
        .menuActionDismissBehavior(.disabled)
        .tint(.primary)   // tick several without reopening
    }

    private func chip(_ facet: LabelFacet, _ value: String?) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: facet.emoji)
            Text(value ?? facet.title).foregroundStyle(value == nil ? .secondary : .primary).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("\(facet.title): \(value ?? "none")")
    }
}

struct PhoneSummary: View {
    @Environment(AppModel.self) private var model
    let thread: GmailThread

    var body: some View {
        if let s = model.suggestion {
            VStack(alignment: .leading, spacing: 12) {
                Text(s.headline).font(.headline)
                if !s.details.isEmpty { Text(s.details).lineSpacing(3) }
                if !s.nextAction.isEmpty { Label("Next: \(s.nextAction)", systemImage: "arrow.right.circle") }
                if let w = s.waitingOn { Label("Waiting on \(w)", systemImage: "hourglass") }
                Text(participants).font(.caption).foregroundStyle(.secondary)
            }
        } else if model.suggesting {
            HStack(spacing: 8) { ProgressView(); Text("Summarising…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
            ContentUnavailableView {
                Label("No Summary Yet", systemImage: "sparkles")
            } description: {
                Text(model.aiNote ?? "Summaries are made on this iPhone with Apple Intelligence.")
            } actions: {
                Button("Summarise") { model.regenerateSelected() }
            }
        }
    }

    private var participants: String {
        let messages = thread.messages ?? []
        let names = messages.map(\.senderName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return "\(messages.count) message\(messages.count == 1 ? "" : "s") · \(names.joined(separator: ", "))"
    }
}

struct PhoneMessages: View {
    let thread: GmailThread

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(thread.messages ?? []) { m in
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.senderName).font(.headline)
                    if let d = m.date { Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Text(m.plainText.linkified).font(.callout).textSelection(.enabled).padding(.top, 4)
                }
                if m.id != thread.messages?.last?.id { Divider() }
            }
        }
    }
}

// MARK: - Today

struct TodayScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Digest") {
                if model.digestLoading { ProgressView() }
                else if let digest = model.digest { Text(digest).font(.callout) }
                else { Text("Nothing to summarise yet.").foregroundStyle(.secondary) }
            }
            Section {
                if model.nextActions.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(model.nextActions) { row in
                    HStack(spacing: 12) {
                        Button { Task { await model.finish(row) } } label: {
                            Image(systemName: "circle").font(.title3).foregroundStyle(GTDBucket.nextAction.color)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Done: file as Reference")
                        NavigationLink(value: Route.thread(row.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.subject).lineLimit(1)
                                Text(model.nextActionSummary(for: row.id) ?? row.from.displayName)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
                NavigationLink("All Next Actions", value: Route.folder(.bucket(.nextAction))).foregroundStyle(.tint)
            } header: {
                Label("Next Actions", systemImage: Folder.bucket(.nextAction).symbol)
            }
            Section {
                if model.waiting.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(model.waiting) { row in
                    NavigationLink(value: Route.thread(row.id)) {
                        HStack {
                            Text(row.subject).lineLimit(1)
                            Spacer()
                            if let d = row.date { Text(d, style: .relative).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                NavigationLink("All Waiting For", value: Route.folder(.bucket(.waitingFor))).foregroundStyle(.tint)
            } header: {
                Label("Waiting For", systemImage: Folder.bucket(.waitingFor).symbol)
            }
            Section {
                NavigationLink(value: Route.folder(.inTray)) {
                    Label("Process In-tray", systemImage: Folder.inTray.symbol).badge(model.inTrayCount)
                }
            }
        }
        .navigationTitle("Today")
        .refreshable { await model.refresh() }
        .overlay { if model.loading && model.nextActions.isEmpty && model.waiting.isEmpty { ProgressView() } }
        .onAppear { if model.folder != .today { model.folder = .today } }
    }
}
