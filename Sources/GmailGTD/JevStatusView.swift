import SwiftUI
import GTDCore

/// The remote provider's presentation never depends on a local summary being available.
struct JevStatusPresentation {
    let text: String
    let bucket: GTDBucket?
    let pending: Bool
    let failed: Bool

    init(state: JevState?) {
        switch state {
        case .success(let bucket):
            text = "Jev: \(bucket.title)"; self.bucket = bucket; pending = false; failed = false
        case .failure(let message):
            text = "Jev: \(message)"; bucket = nil; pending = false; failed = true
        case .pending, nil:
            text = "Jev: awaiting categorisation…"; bucket = nil; pending = true; failed = false
        }
    }
}

/// Shared by inbox and filed-thread detail; outside both the summary-success branch and tab selection.
struct JevStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let status = model.jevStatus {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if status.pending { ProgressView().controlSize(.small) }
                    Text(status.text).foregroundStyle(status.bucket?.color ?? (status.failed ? .red : .secondary))
                    if status.failed {
                        Button("Retry categorisation") { model.regenerateSelected() }.disabled(model.suggesting)
                    }
                }
            }
        }
    }
}

/// Both sources share a horizontal row; narrow panes may wrap rather than truncate labels.
struct ClassificationResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ClassificationResultsRow {
            if let suggestion = model.suggestion {
                Label("Local model: \(suggestion.bucket.title)", systemImage: Folder.bucket(suggestion.bucket).symbol)
                    .foregroundStyle(suggestion.bucket.color)
            }
            JevStatusView()
        }
    }
}

struct ClassificationResultsRow<Results: View>: View {
    @ViewBuilder var results: Results

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) { results }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) { results }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JevApprovalView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text("Approve uses Jev. Manual filing is always available.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Approve") { Task { await model.acceptSuggestion() } }
                .buttonStyle(.borderedProminent).disabled(model.approvalBucket == nil)
        }
    }
}
