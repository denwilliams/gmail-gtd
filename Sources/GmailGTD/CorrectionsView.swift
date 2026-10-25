import SwiftUI
import GTDCore

/// Reviewing history never fetches email or starts a classification/provider request.
struct CorrectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(model.corrections.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.subject).fontWeight(.medium).lineLimit(2)
                        Text(record.from).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("Chose \(record.chosenBucket.title)").font(.caption)
                        Text(record.recordedAt.formatted()).font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(record.id)
                }
            }
            .frame(width: 340)
            .overlay {
                if model.corrections.records.isEmpty {
                    ContentUnavailableView("No Corrections", systemImage: "checkmark.circle",
                                           description: Text("Manual choices that differ from the active approval suggestion appear here after successful filing."))
                }
            }
            Divider()
            if let record = model.corrections.records.first(where: { $0.id == selectedID }) ?? model.corrections.records.first {
                CorrectionDetailView(record: record)
            } else {
                ContentUnavailableView("Local Correction History", systemImage: "arrow.triangle.branch",
                                       description: Text("No extra Gmail labels or external explanation requests."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .top) {
            if let warning = model.corrections.persistenceError {
                Text(warning).font(.callout).foregroundStyle(.orange).padding(8)
            }
        }
    }
}

private struct CorrectionDetailView: View {
    @Environment(AppModel.self) private var model
    let record: CorrectionRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(record.subject).font(.title2.bold())
                Text(record.from).foregroundStyle(.secondary)
                Text(record.recordedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                Text("Thread: \(record.threadID)").font(.caption).textSelection(.enabled)
                GroupBox("At the time of your choice") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Jev suggested: \(record.jevBucket?.title ?? "Unavailable")")
                        Text("AFM (Local model) suggested: \(record.localBucket?.title ?? "Unavailable")")
                        Text("You chose: \(record.chosenBucket.title)").fontWeight(.semibold)
                        Text("Compared against: \(record.activeSource.title) (active approval suggestion)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(record.possibleExplanation).textSelection(.enabled)
                prompt("Jev", record.jevPrompt)
                prompt("AFM (Local model)", record.localPrompt)
                Text("Historical snapshot; later classifications, prompt changes and subsequent moves do not rewrite this event. Stored only on this Mac, separately for each mailbox.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open in Gmail", systemImage: "arrow.up.right.square") { model.openInGmail(record.threadID) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(record.id)
    }

    private func prompt(_ source: String, _ text: String?) -> some View {
        DisclosureGroup("Captured \(source) prompt") {
            Text(text.flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable (no result or prompt captured)")
                .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
