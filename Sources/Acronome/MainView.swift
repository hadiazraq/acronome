import AppKit
import SwiftUI
import UniformTypeIdentifiers

func copyToPasteboard(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
}

@MainActor
struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.section }, set: { if let v = $0 { model.section = v } })) {
                ForEach(AppSection.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch model.section {
            case .lookup: LookupView()
            case .reverse: ReverseView()
            case .expand: ExpandView()
            case .cards: CardsView()
            case .mine: MineView()
            case .nomenclature: NomenclatureView()
            case .sources: SourcesView()
            }
        }
    }
}

// MARK: - Shared pieces

@MainActor
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.7), in: Capsule())
        .onAppear { focused = true }
    }
}

/// Full description of one meaning; used in the quick panel and the main list.
@MainActor
struct EntryDetail: View {
    let entry: Entry
    var compact = false
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var store: UserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if compact {
                Text(entry.abbr)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text(entry.long)
                .font(compact ? .title3.weight(.semibold) : .headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let g = entry.geneSummary {
                Text(g).foregroundStyle(.secondary)
                Text("Gene \(Text(entry.abbr).italic()) · protein \(entry.abbr) · mouse \(Text(mouseCase(entry.abbr)).italic())")
                    .font(.callout).foregroundStyle(.secondary)
                if !entry.alts.isEmpty {
                    Text("Aliases: \(entry.alts.joined(separator: ", "))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !entry.definition.isEmpty {
                Text(entry.definition).fixedSize(horizontal: false, vertical: true)
            }
            if !entry.german.isEmpty {
                Text("German  ").foregroundStyle(.secondary) + Text(entry.german)
            }
            if !entry.note.isEmpty {
                Text("Source: \(entry.note)").font(.callout).foregroundStyle(.secondary)
            }
            let variants = entry.alts.filter { $0.lowercased() != entry.abbr.lowercased() }
            if entry.source == .adam, !variants.isEmpty {
                Text("Also written \(variants.joined(separator: ", "))").font(.callout).foregroundStyle(.secondary)
            }
            MetaLine(entry: entry)
            if compact {
                HStack {
                    Button("Copy Full Form") { copyToPasteboard(entry.long) }
                    Button(store.hasCard(entry.id) ? "Remove from Flashcards" : "Add to Flashcards") {
                        store.toggleCard(entry)
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }
}

func mouseCase(_ s: String) -> String {
    guard let f = s.first, s.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "-" }) else { return s }
    return String(f) + s.dropFirst().lowercased()
}

@MainActor
struct MetaLine: View {
    let entry: Entry
    @EnvironmentObject private var library: Library

    private var summary: String {
        var parts: [String] = [entry.aiGenerated ? "Claude · not verified" : entry.source.label]
        parts += entry.fields.filter { $0 != "gen_bio" }.map(fieldName)
        if entry.count > 0 {
            let pct = Int((library.share(entry) * 100).rounded())
            parts.append("\(entry.count.formatted())× in MEDLINE (\(pct) %)")
        }
        return parts.joined(separator: " · ")
    }

    private var links: some View {
        HStack(spacing: 10) {
            if let u = Links.hgnc(entry) { Link("HGNC", destination: u) }
            if let u = Links.ncbiGene(entry) { Link("NCBI Gene", destination: u) }
            if entry.gene == nil, let u = Links.mesh(entry) { Link("MeSH", destination: u) }
            if let u = Links.pubmed(entry) { Link("PubMed", destination: u) }
        }
        .fixedSize()
    }

    var body: some View {
        // One line when it fits; otherwise the links move under the details instead of truncating them.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(summary).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                links
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(summary).fixedSize(horizontal: false, vertical: true)
                links
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(entry.count > 0 ? "MEDLINE count: how often this meaning was defined in abstracts, and its share of all meanings of \(entry.abbr)" : "")
    }
}

@MainActor
struct EntryRow: View {
    let entry: Entry
    @EnvironmentObject private var store: UserStore
    @EnvironmentObject private var claude: ClaudeService
    @State private var explaining = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(entry.abbr)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tint)
                .frame(minWidth: 80, alignment: .leading)
                .textSelection(.enabled)
            EntryDetail(entry: entry)
            Button { explaining = true } label: {
                Image(systemName: store.aiNotes[entry.id] == nil ? "sparkles" : "sparkles.rectangle.stack")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(store.aiNotes[entry.id] == nil ? "Explain with Claude" : "Show Claude’s explanation")
            .accessibilityLabel("Explain with Claude")
            Button { store.toggleCard(entry) } label: {
                Image(systemName: store.hasCard(entry.id) ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(store.hasCard(entry.id) ? Color.yellow : Color.secondary)
            .help(store.hasCard(entry.id) ? "Remove from Flashcards" : "Add to Flashcards")
            .accessibilityLabel(store.hasCard(entry.id) ? "Remove from Flashcards" : "Add to Flashcards")
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $explaining) {
            ExplainSheet(entry: entry)
                .environmentObject(store)
                .environmentObject(claude)
                .onAppear { if store.aiNotes[entry.id] == nil { claude.explain(entry) } }
        }
        .contextMenu {
            Button("Explain with Claude…") { explaining = true }
            Divider()
            Button("Copy Full Form") { copyToPasteboard(entry.long) }
            Button("Copy “\(entry.long) (\(entry.abbr))”") { copyToPasteboard("\(entry.long) (\(entry.abbr))") }
            Divider()
            Button(store.hasCard(entry.id) ? "Remove from Flashcards" : "Add to Flashcards") { store.toggleCard(entry) }
            if let u = Links.pubmed(entry) { Link("Search PubMed", destination: u) }
        }
    }
}

/// Wrapping row of suggestion buttons.
@MainActor
struct SuggestionGrid: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { s in
                Button(s) { action(s) }
                    .font(.system(.callout, design: .monospaced))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

// MARK: - Look Up

@MainActor
struct LookupView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var store: UserStore
    @State private var sources = Set(Source.allCases)
    @State private var fields = Set<String>()

    private var query: String { model.lookupQuery.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SearchField(text: $model.lookupQuery, prompt: "Abbreviation — e.g. LTP, TNF-α, CA1, RQA") {
                    if !library.search(query).isEmpty { store.pushRecent(query) }
                }
                filterMenu
            }
            .padding(16)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Look Up")
    }

    private var filterMenu: some View {
        Menu {
            Section("Sources") {
                ForEach(Source.allCases) { s in
                    Toggle(s.longLabel, isOn: Binding(
                        get: { sources.contains(s) },
                        set: { if $0 { sources.insert(s) } else { sources.remove(s) } }))
                }
            }
            Section("Fields") {
                Button("All Fields") { fields = [] }
                ForEach(fieldNames, id: \.key) { f in
                    Toggle(f.name, isOn: Binding(
                        get: { fields.contains(f.key) },
                        set: { if $0 { fields.insert(f.key) } else { fields.remove(f.key) } }))
                }
            }
        } label: {
            Image(systemName: fields.isEmpty && sources.count == Source.allCases.count
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by source and field")
    }

    @ViewBuilder private var content: some View {
        if !library.isLoaded {
            ProgressView("Loading abbreviations…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.isEmpty {
            ContentUnavailableView {
                Label("Look Up an Abbreviation", systemImage: "magnifyingglass")
            } description: {
                Text("Case, hyphens and Greek letters are ignored: tnfa, TNF-α and TNF alpha all find the same entry.")
            } actions: {
                if !store.recent.isEmpty {
                    SuggestionGrid(items: Array(store.recent.prefix(8))) { model.lookupQuery = $0 }
                        .frame(maxWidth: 480)
                }
            }
        } else {
            let hits = library.search(query, sources: sources, fields: fields)
            if hits.isEmpty {
                ContentUnavailableView {
                    Label("No Match for “\(query)”", systemImage: "questionmark.circle")
                } description: {
                    Text(library.fuzzy(query).isEmpty ? "Try the full term instead, or add it to your entries."
                                                       : "Did you mean one of these?")
                } actions: {
                    VStack(spacing: 12) {
                        SuggestionGrid(items: library.fuzzy(query)) { model.lookupQuery = $0 }
                            .frame(maxWidth: 480)
                        AskClaudeView(abbr: query)
                        HStack {
                            Button("Search as a Full Term") {
                                model.reverseQuery = query
                                model.section = .reverse
                            }
                            Button("Add to My Entries…") {
                                model.newEntryAbbr = query
                                model.section = .mine
                            }
                        }
                    }
                }
            } else {
                let meanings = Set(hits.map(\.lowerLong)).count
                let prefix = library.prefixMatches(query, limit: 30)
                List {
                    Section {
                        ForEach(hits.prefix(300)) { EntryRow(entry: $0) }
                    } header: {
                        Text(meanings == 1 ? "1 meaning" : "\(meanings) meanings — the context decides which one")
                    }
                    if !prefix.isEmpty {
                        Section("Starts with “\(query)”") {
                            SuggestionGrid(items: prefix) { model.lookupQuery = $0 }
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Reverse

@MainActor
struct ReverseView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: Library
    @State private var total = 0
    @State private var hits: [Entry] = []

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.reverseQuery, prompt: "Full term, English or German — e.g. long-term potentiation, Blut-Hirn-Schranke")
                .padding(16)
            Divider()
            Group {
            if model.reverseQuery.trimmingCharacters(in: .whitespaces).count < 3 {
                ContentUnavailableView("Find the Abbreviation for a Term", systemImage: "text.magnifyingglass",
                                       description: Text("Every word you type must appear in the term. Exact matches come first, then the hand-checked list, then the most frequent MEDLINE abbreviations."))
            } else if hits.isEmpty {
                ContentUnavailableView.search(text: model.reverseQuery)
            } else {
                List {
                    Section(total > hits.count ? "\(total.formatted()) matches · top \(hits.count) shown" : "\(total) matches") {
                        ForEach(hits) { EntryRow(entry: $0) }
                    }
                }
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Find Abbreviation")
        .task(id: "\(model.reverseQuery)|\(library.revision)") {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let r = library.reverse(model.reverseQuery)
            total = r.total
            hits = r.hits
        }
    }
}

// MARK: - Expand text

@MainActor
struct ExpandView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var store: UserStore
    @State private var input = ""
    @State private var result = ExpansionResult()
    @State private var note: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste an abstract, methods section or lecture notes").font(.headline)
                TextEditor(text: $input)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
                    .frame(minHeight: 140, maxHeight: 220)
                HStack {
                    Button("Expand Abbreviations") { result = Expander.run(input, library: library) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !library.isLoaded)
                    Button("Load Example") {
                        input = Expander.example
                        result = Expander.run(input, library: library)
                    }
                    Spacer()
                }
                Divider()
                if result.tokens.isEmpty {
                    Text(result.text.isEmpty ? "Highlighted text appears here." : "No abbreviations found.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    legend
                    ScrollView {
                        Text(highlighted)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 380)

            glossary.frame(minWidth: 300, idealWidth: 360)
        }
        .navigationTitle("Expand Text")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            LegendDot(color: .green, label: "Defined in your text")
            LegendDot(color: .accentColor, label: "Checked list, your entries, genes")
            LegendDot(color: .orange, label: "MEDLINE guess — check it")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func color(for t: ExpandToken) -> Color {
        if t.local { return .green }
        return result.chosen(t.key).entry?.source == .adam ? .orange : .accentColor
    }

    private var highlighted: AttributedString {
        let ns = result.text as NSString
        var out = AttributedString()
        var pos = 0
        for t in result.tokens {
            if t.range.location > pos {
                out += AttributedString(ns.substring(with: NSRange(location: pos, length: t.range.location - pos)))
            }
            var seg = AttributedString(ns.substring(with: t.range))
            let bg: Color = color(for: t).opacity(0.2)
            seg.backgroundColor = bg
            out += seg
            pos = t.range.location + t.range.length
        }
        if pos < ns.length { out += AttributedString(ns.substring(from: pos)) }
        return out
    }

    private var glossary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Glossary").font(.headline)
                if !result.keys.isEmpty { Text("\(result.keys.count)").foregroundStyle(.secondary) }
                Spacer()
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(16)
            List {
                ForEach(result.keys, id: \.self) { k in glossaryRow(k) }
            }
            .overlay {
                if result.keys.isEmpty {
                    Text("Abbreviations from your text are listed here, with a meaning you can change.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            Divider()
            HStack {
                Button("Copy Glossary") { copyToPasteboard(result.glossaryText()); flash("Copied") }
                Button("Copy with First-Use Expansions") { copyToPasteboard(result.expandedText()); flash("Copied") }
                    .help("Spells each abbreviation out at its first use, APA style")
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            Button("Add All to Flashcards") { addAll() }
                .controlSize(.small)
                .padding([.horizontal, .bottom], 16)
                .padding(.top, 6)
        }
        .disabled(result.keys.isEmpty)
    }

    @ViewBuilder private func glossaryRow(_ k: String) -> some View {
        let c = result.chosen(k)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(k).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(.tint)
                Spacer()
                Text(c.entry?.source.label ?? "In your text").font(.caption).foregroundStyle(.secondary)
            }
            if let senses = result.senses[k], senses.count > 1, result.defs[k] == nil {
                Picker("Meaning", selection: Binding(
                    get: { result.choice[k] ?? 0 },
                    set: { result.choice[k] = $0 })) {
                    ForEach(Array(senses.prefix(40).indices), id: \.self) { i in
                        Text(senses[i].long).tag(i)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            } else {
                Text(c.long)
            }
        }
        .padding(.vertical, 3)
    }

    private func addAll() {
        var n = 0
        for k in result.keys {
            let c = result.chosen(k)
            if let e = c.entry {
                n += store.addCards([e])
            } else if store.addLocalCard(abbr: k, long: c.long) {
                n += 1
            }
        }
        flash(n == 1 ? "1 card added" : "\(n) cards added")
    }

    private func flash(_ s: String) {
        note = s
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            note = nil
        }
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.35)).frame(width: 10, height: 10)
            Text(label)
        }
    }
}
