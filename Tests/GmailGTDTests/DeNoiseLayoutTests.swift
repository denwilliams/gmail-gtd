import AppKit
import SwiftUI
import Testing
@testable import GmailGTD

private func layoutRow(sender: String = "Sender", subject: String = "Subject",
                       summary: String = "A brief summary.", dated: Bool = true) -> ThreadRow {
    ThreadRow(id: "layout", subject: subject, from: sender, snippet: summary,
              date: dated ? Date(timeIntervalSince1970: 1_700_000_000) : nil, unread: false)
}

@MainActor private func cardSize(_ row: ThreadRow, width: CGFloat) throws -> CGSize {
    let image = try #require(ImageRenderer(content: DeNoiseCard(row: row, notNoise: {})
        .frame(width: width)).nsImage)
    return image.size
}

@Test(arguments: [CGFloat(320), 480, 800]) @MainActor
func deNoiseLongTextStaysAtTwoLinesAndWithinTheProposedWidth(width: CGFloat) throws {
    let long = String(repeating: "Long email text with no room to spare. ", count: 40)
    for dated in [true, false] {
        let short = try cardSize(layoutRow(dated: dated), width: width)
        let rows = [
            layoutRow(sender: long, dated: dated),
            layoutRow(subject: long, dated: dated),
            layoutRow(summary: long, dated: dated),
            layoutRow(sender: long, subject: long, summary: long, dated: dated),
            layoutRow(subject: "First line\nSecond line", summary: "First line\nSecond line", dated: dated)
        ]
        for row in rows {
            let size = try cardSize(row, width: width)
            #expect(size.width == width)
            #expect(abs(size.height - short.height) <= 1)
        }
    }
}

@Test @MainActor func deNoiseCompactCardsFitMoreEmailsInTheSameViewport() throws {
    let row = layoutRow()
    // Original presentation is the comparison baseline, including its default padding.
    let original = VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.from).font(.headline)
                Text(row.subject).fontWeight(.medium).textSelection(.enabled)
            }
            Spacer()
            if let date = row.date { Text(date, style: .date).foregroundStyle(.secondary) }
            Button("Not Noise") {}
        }
        Text(row.snippet).foregroundStyle(.secondary).textSelection(.enabled)
    }
    .padding().frame(width: 600)
    let oldSize = try #require(ImageRenderer(content: original).nsImage).size
    let compact = try cardSize(row, width: 600)
    #expect(compact.height < oldSize.height)
    // Account for both old (12pt) and new (6pt) inter-card spacing.
    let viewport: CGFloat = 400
    #expect(Int((viewport + 6) / (compact.height + 6)) > Int((viewport + 12) / (oldSize.height + 12)))
}
