import Foundation
import Testing
@testable import GmailGTD
@testable import GTDCore

@MainActor private func facetModel(_ service: DemoMailService, folder: Folder = .inTray) async -> AppModel {
    var settings = CategorisationSettings(); settings.jevEnabled = false
    let model = AppModel(signedIn: true, settings: settings, folder: folder,
                         categoriser: Categoriser(local: { _, _, _ in
                             TriageSuggestion(bucket: .reference, nextAction: "", summary: "Saved information.")
                         }), loadJevToken: { nil })
    model.demo = true   // Never touch real credentials on cleanup.
    await model.connect(using: service, persist: false)
    return model
}

@MainActor private func facetEventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await condition()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(await condition(), "Timed out")
}

@Test @MainActor func inTrayListsOnlyTheInTrayLabelNotGmailInbox() async throws {
    let service = DemoMailService()
    let model = await facetModel(service)
    defer { model.signOut() }
    // Next Action mail is in Gmail's Inbox too, but is not In-tray mail.
    #expect(model.rows.allSatisfy { $0.id.hasPrefix("in") })
    #expect(model.folder.title == "In-tray")
    #expect(!model.catalog.isEmpty)
}

@Test @MainActor func headerFiltersNarrowTheListAndPersistAcrossFolders() async throws {
    let service = DemoMailService()
    let model = await facetModel(service)
    defer { model.signOut() }
    let staff = try #require(model.catalog.options(.source).first { $0.name == "Internal" })
    let notifications = try #require(model.catalog.options(.classification).first { $0.name == "Notifications" })
    let personal = try #require(model.catalog.options(.classification).first { $0.name == "Personal" })

    model.toggleFilter(staff.id, in: .source)
    model.toggleFilter(notifications.id, in: .classification)
    model.toggleFilter(personal.id, in: .classification)
    try await facetEventually { !model.loading && !model.rows.isEmpty }
    try await facetEventually {
        var threads: [Set<String>] = []
        for row in model.rows {
            threads.append(Set((try? await service.thread(row.id))?.messages?.last?.labelIds ?? []))
        }
        return threads.count == model.rows.count && threads.allSatisfy {
            $0.contains(staff.id) && ($0.contains(notifications.id) || $0.contains(personal.id))
        }
    }

    model.folder = .bucket(.nextAction)
    try await facetEventually { !model.loading && model.folder == .bucket(.nextAction) }
    #expect(model.filter.count(.source) == 1)   // still filtering
    #expect(!model.rows.contains { $0.id == "na02" })   // na02 is from a Vendor

    model.clearFilters()
    try await facetEventually { !model.loading && model.rows.contains { $0.id == "na02" } }
}

@Test @MainActor func noneFilterFindsMailWithoutASource() async throws {
    let model = await facetModel(DemoMailService())
    defer { model.signOut() }
    model.toggleNoneFilter(.source)
    try await facetEventually { !model.loading && model.rows.contains { $0.id == "in04" } }
    #expect(!model.rows.contains { $0.id == "in01" })
}

@Test @MainActor func editingFacetsUpdatesTheScreenAndGmailWithoutMovingTheThread() async throws {
    let service = DemoMailService()
    let model = await facetModel(service)
    defer { model.signOut() }
    model.selection = "in05"
    try await facetEventually { model.detail?.id == "in05" }
    #expect(model.values(.source).isEmpty)
    let vendor = try #require(model.catalog.options(.source).first { $0.name == "Vendor" })
    let hiring = try #require(model.catalog.options(.tag).first { $0.name == "Hiring" })
    let website = try #require(model.catalog.options(.project).first { $0.name == "Website Redesign" })

    model.setSingle(.source, to: vendor.id)
    model.toggle(hiring.id, in: .tag)
    model.toggle(website.id, in: .project)
    #expect(model.values(.source) == [vendor])   // on screen at once
    #expect(model.values(.tag) == [hiring])
    #expect(model.rows.first { $0.id == "in05" }?.labelIDs.contains(vendor.id) == true)
    await model.refreshQuietly()   // waits for the queued Gmail writes

    let labels = Set(try await service.thread("in05").messages?.last?.labelIds ?? [])
    #expect(labels.isSuperset(of: [vendor.id, hiring.id, website.id, "INBOX", DemoMailService.inTrayID]))
    #expect(model.rows.contains { $0.id == "in05" })   // still in the In-tray
    #expect(model.undoStack.isEmpty)                    // facet edits are not moves

    model.setSingle(.source, to: nil)
    model.toggle(hiring.id, in: .tag)
    await model.refreshQuietly()
    let cleared = Set(try await service.thread("in05").messages?.last?.labelIds ?? [])
    #expect(!cleared.contains(vendor.id) && !cleared.contains(hiring.id) && cleared.contains(website.id))
    #expect(model.error == nil)
}

@Test @MainActor func doneFilesAsReferenceAndBackToInTrayRestoresTheQueue() async throws {
    let service = DemoMailService()
    let model = await facetModel(service, folder: .bucket(.nextAction))
    defer { model.signOut() }
    try await facetEventually { model.detail != nil }
    let id = try #require(model.selection)
    #expect(model.canFinish)
    await model.finishSelected()
    #expect(model.undoToast?.destination == .reference)
    await model.refreshQuietly()
    let filed = Set(try await service.thread(id).messages?.last?.labelIds ?? [])
    #expect(filed.contains(DemoMailService.labelID(.reference)))
    #expect(!filed.contains("INBOX") && !filed.contains(DemoMailService.labelID(.nextAction)))

    model.folder = .bucket(.reference)
    try await facetEventually { model.selection != nil && model.detail != nil }
    #expect(!model.canFinish)   // already Reference
    model.selection = id
    try await facetEventually { model.detail?.id == id }
    await model.unfileSelected()
    await model.refreshQuietly()
    let back = Set(try await service.thread(id).messages?.last?.labelIds ?? [])
    #expect(back.isSuperset(of: ["INBOX", DemoMailService.inTrayID]))
    #expect(back.isDisjoint(with: GTDBucket.allCases.map(DemoMailService.labelID)))
}
