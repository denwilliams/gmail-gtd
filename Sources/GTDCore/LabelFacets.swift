import Foundation

/// The label families beside 🚦 Status. Each is a parent label whose children are the options:
/// `🏢/AWS`, `🗂️/Newsletters`, `🏷️/Hiring`, `🎯/Data Warehouse`. The app never creates these labels;
/// it discovers whatever exists in Gmail, so new options appear on the next refresh.
public enum LabelFacet: String, CaseIterable, Codable, Sendable {
    case classification, source, tag, project

    public var emoji: String {
        switch self {
        case .classification: "🗂️"
        case .source: "🏢"
        case .tag: "🏷️"
        case .project: "🎯"
        }
    }

    public var title: String {
        switch self {
        case .classification: "Classification"
        case .source: "Source"
        case .tag: "Tags"
        case .project: "Projects"
        }
    }

    /// Source and Classification hold one value per thread; Tags and Projects hold any number.
    public var isSingle: Bool { self == .classification || self == .source }

    /// Gmail keeps emoji exactly as typed, with or without the U+FE0F variation selector ("🏷" vs "🏷️").
    /// Compare names with it removed so either spelling matches.
    public static func normalised(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.filter { $0 != "\u{FE0F}" }))
    }

    /// The option name after the parent (`🏢/AWS` → `AWS`), or nil when the label is not in this family.
    public func optionName(of labelName: String) -> String? {
        guard Self.normalised(labelName).hasPrefix(Self.normalised(emoji) + "/"),
              let slash = labelName.firstIndex(of: "/") else { return nil }
        let option = labelName[labelName.index(after: slash)...]
        return option.isEmpty ? nil : String(option)
    }
}

/// One option in a facet: a Gmail label such as `🏢/AWS`.
public struct FacetLabel: Hashable, Sendable, Identifiable {
    public let id: String
    /// The full Gmail label name, used in search queries.
    public let labelName: String
    /// The part after the slash, for display.
    public let name: String
    public let facet: LabelFacet

    public init(id: String, labelName: String, name: String, facet: LabelFacet) {
        self.id = id
        self.labelName = labelName
        self.name = name
        self.facet = facet
    }
}

/// Every facet option found in the mailbox, sorted by name within each facet.
public struct LabelCatalog: Sendable, Equatable {
    public private(set) var options: [LabelFacet: [FacetLabel]] = [:]

    public init(labels: [GmailLabel] = []) {
        for label in labels {
            for facet in LabelFacet.allCases {
                if let name = facet.optionName(of: label.name) {
                    options[facet, default: []].append(FacetLabel(id: label.id, labelName: label.name, name: name, facet: facet))
                }
            }
        }
        for facet in options.keys {
            options[facet]?.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public func options(_ facet: LabelFacet) -> [FacetLabel] { options[facet] ?? [] }

    public func label(id: String) -> FacetLabel? {
        options.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// The thread's options in one facet, in catalog order.
    public func values(_ facet: LabelFacet, in labelIDs: Set<String>) -> [FacetLabel] {
        options(facet).filter { labelIDs.contains($0.id) }
    }

    public var isEmpty: Bool { options.values.allSatisfy(\.isEmpty) }
}

/// The header filters: OR within a facet, AND across facets. For single-value facets, `includesNone` also
/// matches threads with no value in that facet (for example mail no Gmail filter gave a Source).
public struct LabelFilter: Sendable, Equatable, Hashable {
    public var selected: [LabelFacet: Set<String>] = [:]
    public var includesNone: Set<LabelFacet> = []

    public init(selected: [LabelFacet: Set<String>] = [:], includesNone: Set<LabelFacet> = []) {
        self.selected = selected
        self.includesNone = includesNone
    }

    public var isEmpty: Bool { selected.values.allSatisfy(\.isEmpty) && includesNone.isEmpty }

    public func count(_ facet: LabelFacet) -> Int {
        (selected[facet]?.count ?? 0) + (includesNone.contains(facet) ? 1 : 0)
    }

    public func contains(_ id: String, in facet: LabelFacet) -> Bool { selected[facet]?.contains(id) ?? false }

    public mutating func toggle(_ id: String, in facet: LabelFacet) {
        if contains(id, in: facet) { selected[facet]?.remove(id) } else { selected[facet, default: []].insert(id) }
    }

    public mutating func toggleNone(_ facet: LabelFacet) {
        guard facet.isSingle else { return }
        if includesNone.contains(facet) { includesNone.remove(facet) } else { includesNone.insert(facet) }
    }

    /// Drops selections whose labels no longer exist, so a deleted label cannot leave an impossible filter.
    public func pruned(to catalog: LabelCatalog) -> LabelFilter {
        var copy = self
        for (facet, ids) in selected {
            copy.selected[facet] = ids.intersection(catalog.options(facet).map(\.id))
        }
        return copy
    }

    /// The filter as a Gmail search query, or nil when it filters nothing.
    ///
    /// - A facet with options selected: `{label:"🏢/AWS" label:"🏢/Stripe"}` (any of them).
    /// - A single-value facet with None also selected: every *other* option is excluded instead,
    ///   `-{label:"🏢/Apple" …}`. A thread has at most one value there, so "none, AWS or Stripe" is
    ///   exactly "not any of the rest".
    public func gmailQuery(catalog: LabelCatalog) -> String? {
        var clauses: [String] = []
        for facet in LabelFacet.allCases {
            let chosen = selected[facet] ?? []
            let options = catalog.options(facet)
            if facet.isSingle && includesNone.contains(facet) {
                let rest = options.filter { !chosen.contains($0.id) }
                guard !rest.isEmpty else { continue }   // None plus every option: no constraint at all.
                clauses.append("-" + Self.anyOf(rest))
            } else {
                let picked = options.filter { chosen.contains($0.id) }
                guard !picked.isEmpty else { continue }
                clauses.append(Self.anyOf(picked))
            }
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " ")
    }

    private static func anyOf(_ labels: [FacetLabel]) -> String {
        // Quotes inside a label name would end the term early; Gmail ignores them in label matching anyway.
        "{" + labels.map { "label:\"\($0.labelName.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " ") + "}"
    }

    /// Evaluates the filter against a thread's label IDs. Used by the demo mailbox and tests; Gmail runs
    /// the equivalent `gmailQuery` itself.
    public func matches(_ labelIDs: Set<String>, catalog: LabelCatalog) -> Bool {
        for facet in LabelFacet.allCases {
            let chosen = selected[facet] ?? []
            let has = Set(catalog.options(facet).map(\.id)).intersection(labelIDs)
            if facet.isSingle && includesNone.contains(facet) {
                if !has.subtracting(chosen).isEmpty { return false }
            } else if !chosen.isEmpty, has.isDisjoint(with: chosen) {
                return false
            }
        }
        return true
    }
}
