import AppKit
import SwiftUI
import Testing
@testable import GmailGTD

@Test @MainActor func classificationResultsUseOneRowWhenWideAndWrapWhenNarrow() throws {
    func render(width: CGFloat) throws -> NSImage {
        let view = ClassificationResultsRow {
            Text("Local model: Reference")
            Text("Jev: Noise")
        }.frame(width: width)
        return try #require(ImageRenderer(content: view).nsImage)
    }
    let wide = try render(width: 600)
    let narrow = try render(width: 170)
    let single = try #require(ImageRenderer(content: Text("Local model: Reference").frame(width: 600)).nsImage)
    #expect(wide.size.height == single.size.height)  // Different categories share one line.
    #expect(narrow.size.height > wide.size.height)  // No source label is clipped to fit.
}
