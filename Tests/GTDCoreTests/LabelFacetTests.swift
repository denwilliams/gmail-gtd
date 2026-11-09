import Foundation
import Testing
@testable import GTDCore

private let sample: [GmailLabel] = [
    GmailLabel(id: "c1", name: "🗂️/Newsletters", type: "user"),
    GmailLabel(id: "c2", name: "🗂/Notifications", type: "user"),   // no variation selector
    GmailLabel(id: "s1", name: "🏢/AWS", type: "user"),
    GmailLabel(id: "s2", name: "🏢/Stripe", type: "user"),
    GmailLabel(id: "s3", name: "🏢/Apple", type: "user"),
    GmailLabel(id: "t1", name: "🏷️/Hiring", type: "user"),
    GmailLabel(id: "t2", name: "🏷️/New Infra", type: "user"),
    GmailLabel(id: "p1", name: "🎯/Data Warehouse", type: "user"),
    GmailLabel(id: "parent", name: "🏢", type: "user"),            // the parent itself is not an option
    GmailLabel(id: "old", name: "GTD/Next Action", type: "user"),
    GmailLabel(id: "status", name: "🚦/Next Action", type: "user"),
]

@Test func catalogGroupsOptionsByEmojiPrefixWithOrWithoutVariationSelector() {
    let catalog = LabelCatalog(labels: sample)
    #expect(catalog.options(.classification).map(\.name) == ["Newsletters", "Notifications"])
    #expect(catalog.options(.source).map(\.name) == ["Apple", "AWS", "Stripe"])
    #expect(catalog.options(.tag).map(\.name) == ["Hiring", "New Infra"])
    #expect(catalog.options(.project).map(\.name) == ["Data Warehouse"])
    #expect(catalog.label(id: "parent") == nil && catalog.label(id: "old") == nil && catalog.label(id: "status") == nil)
    #expect(catalog.values(.source, in: ["s2", "t1", "INBOX"]).map(\.name) == ["Stripe"])
}

@Test func filterIsOrWithinAFacetAndAndAcrossFacets() {
    let catalog = LabelCatalog(labels: sample)
    var filter = LabelFilter()
    #expect(filter.gmailQuery(catalog: catalog) == nil)
    filter.toggle("s1", in: .source)
    filter.toggle("s2", in: .source)
    filter.toggle("c1", in: .classification)
    #expect(filter.gmailQuery(catalog: catalog)
        == #"{label:"🗂️/Newsletters"} {label:"🏢/AWS" label:"🏢/Stripe"}"#)
    #expect(filter.matches(["s1", "c1"], catalog: catalog))
    #expect(filter.matches(["s2", "c1", "t1"], catalog: catalog))
    #expect(!filter.matches(["s3", "c1"], catalog: catalog))   // wrong Source
    #expect(!filter.matches(["s1", "c2"], catalog: catalog))   // wrong Classification
    #expect(!filter.matches(["s1"], catalog: catalog))         // no Classification
    #expect(filter.count(.source) == 2)
}

@Test func noneMatchesMissingValuesByExcludingTheOtherOptions() {
    let catalog = LabelCatalog(labels: sample)
    var filter = LabelFilter()
    filter.toggleNone(.source)
    #expect(filter.gmailQuery(catalog: catalog) == #"-{label:"🏢/Apple" label:"🏢/AWS" label:"🏢/Stripe"}"#)
    #expect(filter.matches([], catalog: catalog))
    #expect(!filter.matches(["s1"], catalog: catalog))

    filter.toggle("s1", in: .source)   // None or AWS
    #expect(filter.gmailQuery(catalog: catalog) == #"-{label:"🏢/Apple" label:"🏢/Stripe"}"#)
    #expect(filter.matches([], catalog: catalog) && filter.matches(["s1"], catalog: catalog))
    #expect(!filter.matches(["s2"], catalog: catalog))

    for id in ["s2", "s3"] { filter.toggle(id, in: .source) }   // None or anything: no constraint
    #expect(filter.gmailQuery(catalog: catalog) == nil)

    var tags = LabelFilter()
    tags.toggleNone(.tag)   // multi-value facets have no None
    #expect(tags.isEmpty)
}

@Test func filterDropsLabelsThatNoLongerExist() {
    var filter = LabelFilter()
    filter.toggle("gone", in: .tag)
    filter.toggle("t1", in: .tag)
    #expect(filter.pruned(to: LabelCatalog(labels: sample)).selected[.tag] == ["t1"])
}

@Test func demoMailboxAppliesTheSameQueriesGmailWould() async throws {
    let demo = DemoMailService()
    let labels = LabelManager(client: demo)
    let inTray = try await labels.inTrayLabelID()
    let catalog = try await labels.catalog()
    let staff = try #require(catalog.options(.source).first { $0.name == "Internal" })
    let personal = try #require(catalog.options(.classification).first { $0.name == "Personal" })
    let notifications = try #require(catalog.options(.classification).first { $0.name == "Notifications" })

    func list(_ filter: LabelFilter) async throws -> Set<String> {
        let page = try await demo.listThreadPage(labelIDs: [inTray], query: filter.gmailQuery(catalog: catalog),
                                                 max: 100, pageToken: nil)
        return Set(page.refs.map(\.id))
    }
    func expected(_ filter: LabelFilter) async throws -> Set<String> {
        var ids: Set<String> = []
        for ref in try await demo.listThreads(labelIDs: [inTray], max: 100) {
            let have = Set(try await demo.thread(ref.id).messages?.last?.labelIds ?? [])
            if filter.matches(have, catalog: catalog) { ids.insert(ref.id) }
        }
        return ids
    }

    var filter = LabelFilter()
    filter.toggle(personal.id, in: .classification)
    filter.toggle(notifications.id, in: .classification)
    filter.toggle(staff.id, in: .source)
    let both = try await list(filter)
    #expect(!both.isEmpty && both.count < 20)
    #expect(both == (try await expected(filter)))

    var noSource = LabelFilter()
    noSource.toggleNone(.source)
    let unsourced = try await list(noSource)
    #expect(unsourced.contains("in04") && unsourced.contains("in05") && !unsourced.contains("in01"))
    #expect(unsourced == (try await expected(noSource)))
}

@Test func settingAFacetReplacesOnlyThatFacet() async throws {
    let demo = DemoMailService()
    let labels = LabelManager(client: demo)
    let catalog = try await labels.catalog()
    func labelSet() async throws -> Set<String> { Set(try await demo.thread("in07").messages?.last?.labelIds ?? []) }
    let before = try await labelSet()
    let vendor = try #require(catalog.options(.source).first { $0.name == "Vendor" })
    let staff = try #require(catalog.options(.source).first { $0.name == "Internal" })
    let hiring = try #require(catalog.options(.tag).first { $0.name == "Hiring" })
    let legal = try #require(catalog.options(.tag).first { $0.name == "Legal" })
    #expect(before.contains(vendor.id) && before.contains(legal.id))

    try await labels.setFacet(.source, of: "in07", to: [staff.id], catalog: catalog)
    #expect(try await labelSet() == before.subtracting([vendor.id]).union([staff.id]))

    try await labels.setFacet(.tag, of: "in07", to: [legal.id, hiring.id], catalog: catalog)
    #expect(try await labelSet() == before.subtracting([vendor.id]).union([staff.id, hiring.id]))

    try await labels.setFacet(.source, of: "in07", to: [], catalog: catalog)   // clear
    #expect(try await labelSet() == before.subtracting([vendor.id]).union([hiring.id]))
    #expect(try await labelSet().isSuperset(of: ["INBOX", DemoMailService.inTrayID]))   // status untouched
}
