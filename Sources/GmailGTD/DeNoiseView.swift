import SwiftUI
import GTDCore

/// Review only the snapshot, never the changing inbox or the selected thread.
struct DeNoiseView: View {
    @Environment(AppModel.self) private var model
    let batch: AppModel.DeNoiseBatch

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("De-noise Mode").font(.title2.bold())
                    Text("\(batch.rows.count) of 10 emails remaining. Corrections shrink this batch; no replacements are added.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Exit De-noise Mode") { model.endDeNoiseMode() }
                Button("LGTM") { model.approveDeNoiseBatch(batch.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canApproveDeNoiseBatch)
                    .help("Move only the remaining reviewed emails to Noise and out of the inbox.")
            }
            .padding()
            Divider()
            if batch.rows.isEmpty {
                ContentUnavailableView("No Emails Left", systemImage: "checkmark.circle",
                                       description: Text("All 10 emails were corrected. Exit to return to the inbox."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(batch.rows) { row in
                            DeNoiseCard(row: row) { model.beginDeNoiseCorrection(for: row.id) }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: Binding(get: { model.deNoiseCorrection }, set: { value in
            if value == nil { model.cancelDeNoiseCorrection() }
        })) { correction in
            DeNoiseCorrectionView(correction: correction).environment(model)
        }
    }
}

/// Text yields space to the date and action, even for long mail headers in narrow panes.
struct DeNoiseCard: View {
    let row: ThreadRow
    let notNoise: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(row.from.displayName).font(.headline)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: 160, alignment: .leading)
                    Text(row.subject).fontWeight(.medium).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if let date = row.date {
                    Text(date, style: .date).foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Button("Not Noise", action: notNoise)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(row.snippet).foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DeNoiseCorrectionView: View {
    @Environment(AppModel.self) private var model
    let correction: AppModel.DeNoiseCorrection
    @State private var bucket: GTDBucket = .nextAction

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Not Noise").font(.title2.bold())
            Text(correction.row.subject).font(.headline)
            Picker("Category", selection: $bucket) {
                ForEach(GTDBucket.allCases.filter { $0 != .noise }, id: \.self) { category in
                    Text(category.title).tag(category)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelDeNoiseCorrection() }.keyboardShortcut(.cancelAction)
                Button("Apply Category") { model.confirmDeNoiseCorrection(bucket, correctionID: correction.id) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440)
    }
}
