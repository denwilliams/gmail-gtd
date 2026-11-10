import SwiftUI
import GTDCore

// Source, Classification, Tags and Projects: the label families beside 🚦 Status. Status is driven by the
// sidebar and number keys; these are edited per thread in `FacetBar` and filtered in the toolbar.

/// The toolbar filters: one menu per facet, any number of options in each. OR within a menu, AND across menus.
struct FilterMenus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LabelFacet.allCases, id: \.self) { facet in menu(facet) }
            if !model.filter.isEmpty {
                Button("Clear Filters", systemImage: "xmark.circle.fill") { model.clearFilters() }
                    .labelStyle(.iconOnly)
                    .help("Clear all filters")
            }
        }
    }

    private func menu(_ facet: LabelFacet) -> some View {
        let options = model.catalog.options(facet)
        let count = model.filter.count(facet)
        return Menu {
            if facet.isSingle {
                Toggle("None", isOn: Binding(get: { model.filter.includesNone.contains(facet) },
                                             set: { _ in model.toggleNoneFilter(facet) }))
                Divider()
            }
            ForEach(options) { option in
                Toggle(option.name, isOn: Binding(get: { model.filter.contains(option.id, in: facet) },
                                                  set: { _ in model.toggleFilter(option.id, in: facet) }))
            }
            if options.isEmpty {
                Text("No \(facet.emoji) labels in Gmail")
            }
            if count > 0 {
                Divider()
                Button("Clear \(facet.title)") { model.clearFilter(facet) }
            }
        } label: {
            Text(verbatim: count > 0 ? "\(facet.emoji) \(facet.title) (\(count))" : "\(facet.emoji) \(facet.title)")
        }
        .fixedSize()
        .help("Show only mail with any of the chosen \(facet.title.lowercased())")
    }
}

/// Above the open thread: its Classification and Source (one each) and its Tags and Projects (any number).
/// Changing one never moves the thread.
struct FacetBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            single(.classification)
            single(.source)
            multiple(.tag)
            multiple(.project)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func single(_ facet: LabelFacet) -> some View {
        Picker(selection: Binding(get: { model.values(facet).first?.id },
                                  set: { model.setSingle(facet, to: $0) })) {
            Text("No \(facet.title)").tag(String?.none)
            Divider()
            ForEach(model.catalog.options(facet)) { option in
                Text(option.name).tag(Optional(option.id))
            }
        } label: {
            Text(verbatim: facet.emoji)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(facet.title)
    }

    private func multiple(_ facet: LabelFacet) -> some View {
        let current = model.values(facet)
        return Menu {
            ForEach(model.catalog.options(facet)) { option in
                Toggle(option.name, isOn: Binding(get: { current.contains(option) },
                                                  set: { _ in model.toggle(option.id, in: facet) }))
            }
            if model.catalog.options(facet).isEmpty {
                Text("Create \(facet.emoji)/… labels in Gmail to use \(facet.title.lowercased())")
            }
        } label: {
            Text(verbatim: current.isEmpty ? "\(facet.emoji) Add" : "\(facet.emoji) " + current.map(\.name).joined(separator: ", "))
                .lineLimit(1)
        }
        .fixedSize()
        .help(facet.title)
    }
}

/// One quiet line under a list row: the thread's Classification, Source, Tags and Projects, where known.
struct FacetSummary: View {
    @Environment(AppModel.self) private var model
    let labelIDs: Set<String>

    var body: some View {
        let parts = LabelFacet.allCases.compactMap { facet -> String? in
            let names = model.catalog.values(facet, in: labelIDs).map(\.name)
            return names.isEmpty ? nil : "\(facet.emoji) \(names.joined(separator: ", "))"
        }
        if !parts.isEmpty {
            Text(verbatim: parts.joined(separator: "   "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
