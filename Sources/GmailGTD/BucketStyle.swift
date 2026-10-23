import SwiftUI
import GTDCore

/// One system colour per bucket, used wherever a bucket appears (sidebar, list chips, action buttons).
/// Plain system colours, and always alongside the bucket's name, so colour is never the only cue.
extension GTDBucket {
    /// A shorter name for tight spaces.
    var shortTitle: String {
        switch self {
        case .nextAction: "Next"
        case .waitingFor: "Waiting"
        case .someday: "Someday"
        default: title
        }
    }

    var color: Color {
        switch self {
        case .nextAction: .blue
        case .waitingFor: .orange
        case .someday: .purple
        case .reference: .teal
        case .project: .indigo
        case .noise: .gray
        case .done: .green
        }
    }
}

/// A small tinted capsule naming a bucket.
struct BucketChip: View {
    let bucket: GTDBucket

    var body: some View {
        Text(bucket.title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(bucket.color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(bucket.color.opacity(0.15), in: Capsule())
    }
}

/// A bordered button washed with its bucket's colour.
struct BucketButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1).fixedSize()   // a button's label never wraps; the bar chooses a shorter form instead
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(configuration.isPressed ? 0.35 : 0.18), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.5)))
    }
}
