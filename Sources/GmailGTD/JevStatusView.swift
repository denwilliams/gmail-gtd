import SwiftUI
import GTDCore

/// The remote provider's presentation never depends on a local summary being available.
struct JevStatusPresentation {
    let text: String
    let bucket: GTDBucket?
    let pending: Bool
    let failed: Bool
    var symbol: String? { bucket.map { Folder.bucket($0).symbol } }

    init(state: JevState?) {
        switch state {
        case .success(let bucket, _):
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
                    Group {
                        if let symbol = status.symbol {
                            Label(status.text, systemImage: symbol)
                        } else {
                            Text(status.text)
                        }
                    }
                    .foregroundStyle(status.bucket?.color ?? (status.failed ? .red : .secondary))
                    if status.failed {
                        Button("Retry categorisation") { model.regenerateSelected() }.disabled(model.suggesting)
                    }
                }
            }
        }
    }
}

/// A successful Jev decision leads; keep local-only/pending/failure presentation unchanged.
struct ClassificationResultsPresentation {
    let jevFirst: Bool
    let localBucket: GTDBucket?

    init(localBucket: GTDBucket?, jev: JevStatusPresentation?) {
        jevFirst = jev?.bucket != nil
        self.localBucket = localBucket == jev?.bucket ? nil : localBucket
    }
}

/// Both sources share a horizontal row; narrow panes may wrap rather than truncate labels.
struct ClassificationResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let presentation = ClassificationResultsPresentation(localBucket: model.suggestion?.bucket, jev: model.jevStatus)
        ClassificationResultsRow {
            if presentation.jevFirst { JevStatusView() }
            if let bucket = presentation.localBucket {
                Label("Local model: \(bucket.title)", systemImage: Folder.bucket(bucket).symbol)
                    .foregroundStyle(bucket.color)
            }
            if !presentation.jevFirst { JevStatusView() }
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
