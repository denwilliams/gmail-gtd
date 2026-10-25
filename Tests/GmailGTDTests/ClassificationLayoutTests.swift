import AppKit
import SwiftUI
import Testing
import GTDCore
@testable import GmailGTD

@Test @MainActor func classificationResultsUseOneRowWhenWideAndWrapWhenNarrow() throws {
    func render(width: CGFloat) throws -> NSImage {
        let view = ClassificationResultsRow {
            Label("Jev: Noise", systemImage: Folder.bucket(.noise).symbol)
            Label("Local model: Reference", systemImage: Folder.bucket(.reference).symbol)
        }.frame(width: width)
        return try #require(ImageRenderer(content: view).nsImage)
    }
    let wide = try render(width: 600)
    let narrow = try render(width: 170)
    let single = try #require(ImageRenderer(content: Label("Jev: Noise", systemImage: Folder.bucket(.noise).symbol).frame(width: 600)).nsImage)
    #expect(wide.size.height == single.size.height)  // Different categories share one line.
    #expect(narrow.size.height > wide.size.height)  // No source label is clipped to fit.
}

@Test(arguments: GTDBucket.allCases, GTDBucket.allCases)
func jevDecisionLeadsAndLocalAppearsOnlyOnDisagreement(local: GTDBucket, remote: GTDBucket) {
    let status = JevStatusPresentation(state: .success(remote))
    let presentation = ClassificationResultsPresentation(localBucket: local, jev: status)
    #expect(presentation.jevFirst)
    #expect(presentation.localBucket == (local == remote ? nil : local))
    #expect(status.symbol == Folder.bucket(remote).symbol)
}

@Test func localReferenceVersusJevNoiseUsesNoiseIcon() {
    let status = JevStatusPresentation(state: .success(.noise))
    let presentation = ClassificationResultsPresentation(localBucket: .reference, jev: status)
    #expect(presentation.jevFirst)
    #expect(status.text == "Jev: Noise")
    #expect(status.symbol == "speaker.slash")
    #expect(presentation.localBucket == .reference)
}

@Test(arguments: GTDBucket.allCases)
func jevDecisionDoesNotRequireLocalResult(remote: GTDBucket) {
    let status = JevStatusPresentation(state: .success(remote))
    let presentation = ClassificationResultsPresentation(localBucket: nil, jev: status)
    #expect(presentation.jevFirst)
    #expect(presentation.localBucket == nil)
    #expect(status.symbol == Folder.bucket(remote).symbol)
}

@Test func localPresentationIsPreservedWithoutJevDecision() {
    // Disabled, not yet requested, pending, and failed must not hide the local fallback.
    let statuses: [JevStatusPresentation?] = [nil, JevStatusPresentation(state: nil),
        JevStatusPresentation(state: .pending), JevStatusPresentation(state: .failure("Unavailable"))]
    let localBuckets: [GTDBucket?] = [nil, .reference]
    for status in statuses {
        for local in localBuckets {
            let presentation = ClassificationResultsPresentation(localBucket: local, jev: status)
            #expect(!presentation.jevFirst)
            #expect(presentation.localBucket == local)
            #expect(status?.symbol == nil)
        }
    }
}
