import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Flashcards

@MainActor
struct CardsView: View {
    @EnvironmentObject private var store: UserStore
    @EnvironmentObject private var library: Library
    @State private var mode = 0
    @State private var flipped = false
    @State private var termFirst = false
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("", selection: $mode) {
                    Text("Study").tag(0)
                    Text("Deck").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Toggle("Show the term first", isOn: $termFirst)
                Menu("Add Cards") {
                    Button("10 Random from Any Field") { addRandom(nil) }
                    Divider()
                    ForEach(fieldNames.filter { $0.key != "gen_bio" }, id: \.key) { f in
                        Button("10 from \(f.name)") { addRandom(f.key) }
                    }
                }
                .fixedSize()
                .disabled(!library.isLoaded)
            }
            .padding(16)
            Divider()
            if mode == 0 { study } else { deck }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Flashcards")
    }

    private func addRandom(_ field: String?) {
        let picked = library.randomCore(field: field, excluding: Set(store.cards.keys), count: 10)
        store.addCards(picked)
    }

    @ViewBuilder private var study: some View {
        let due = store.dueIDs
        VStack(spacing: 20) {
            HStack(spacing: 28) {
                Stat(value: store.cards.count, label: "Cards")
                Stat(value: due.count, label: "Due now")
                Stat(value: store.cards.values.filter { $0.box >= 4 }.count, label: "Well learned")
            }
            .padding(.top, 20)
            if store.cards.isEmpty {
                ContentUnavailableView("No Flashcards Yet", systemImage: "rectangle.on.rectangle.angled",
                                       description: Text("Star any result, add your own entries, or choose Add Cards."))
                    .frame(maxHeight: .infinity)
            } else if let id = due.first, let c = store.cards[id] {
                card(c)
                    .onTapGesture { flipped.toggle() }
                if flipped {
                    HStack(spacing: 10) {
                        Button("Again") { grade(id, 1) }.keyboardShortcut("1", modifiers: [])
                        Button("Hard") { grade(id, 2) }.keyboardShortcut("2", modifiers: [])
                        Button("Good") { grade(id, 3) }.keyboardShortcut("3", modifiers: [])
                            .buttonStyle(.borderedProminent)
                        Button("Easy") { grade(id, 4) }.keyboardShortcut("4", modifiers: [])
                    }
                    .controlSize(.large)
                    Text("Keys 1–4").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Show Answer") { flipped = true }
                        .controlSize(.large)
                        .keyboardShortcut(.space, modifiers: [])
                }
                Spacer()
            } else {
                let next = store.cards.values.map(\.due).min() ?? 0
                ContentUnavailableView {
                    Label("All Caught Up", systemImage: "checkmark.circle")
                } description: {
                    Text("Next card due \(Date(timeIntervalSince1970: next / 1000).formatted(date: .abbreviated, time: .shortened)).")
                } actions: {
                    Button("Review All Anyway") { store.makeAllDue() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ c: Card) -> some View {
        VStack(spacing: 12) {
            if termFirst {
                Text(c.l).font(.title.weight(.semibold)).multilineTextAlignment(.center)
            } else {
                Text(c.a).font(.system(size: 44, weight: .semibold, design: .monospaced)).foregroundStyle(.tint)
            }
            if flipped {
                Divider().frame(width: 80)
                if termFirst {
                    Text(c.a).font(.system(size: 32, weight: .semibold, design: .monospaced)).foregroundStyle(.tint)
                } else {
                    Text(c.l).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                }
                if let d = c.d, !d.isEmpty { Text(d).multilineTextAlignment(.center).foregroundStyle(.secondary) }
                if let de = c.de, !de.isEmpty { Text("German  ").foregroundStyle(.secondary) + Text(de) }
                Text("Box \(c.box) of 6").font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("Click or press Space to show the answer").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 520)
        .frame(minHeight: 240)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator))
        .contentShape(Rectangle())
    }

    private func grade(_ id: String, _ g: Int) {
        store.grade(id, g)
        flipped = false
    }

    private struct DeckRow: Identifiable {
        let id: String
        let card: Card
    }

    private var deck: some View {
        let rows = store.cards
            .filter { filter.isEmpty || $0.value.a.localizedCaseInsensitiveContains(filter) || $0.value.l.localizedCaseInsensitiveContains(filter) }
            .map { DeckRow(id: $0.key, card: $0.value) }
            .sorted { $0.card.a.localizedCaseInsensitiveCompare($1.card.a) == .orderedAscending }
        return VStack(spacing: 0) {
            SearchField(text: $filter, prompt: "Filter your deck").padding(16)
            Table(rows) {
                TableColumn("Abbreviation") { r in
                    Text(r.card.a).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(.tint)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Meaning") { r in Text(r.card.l) }
                TableColumn("Box") { r in Text("\(r.card.box)") }.width(40)
                TableColumn("Due") { r in
                    Text(r.card.due <= UserStore.nowMS ? "Now"
                         : Date(timeIntervalSince1970: r.card.due / 1000).formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("") { r in
                    Button("Remove") { store.removeCard(r.id) }.buttonStyle(.borderless)
                }
                .width(70)
            }
        }
    }
}

private struct Stat: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - My entries

@MainActor
struct MineView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: UserStore
    @State private var selection = Set<String>()
    @State private var editing: MineEntry?
    @State private var pendingDelete: Set<String>?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { editing = .blank() } label: { Label("Add Entry", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Spacer()
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Button("Import…") { importBackup() }
                Button("Export…") { exportBackup() }.disabled(store.mine.isEmpty && store.cards.isEmpty)
            }
            .padding(16)
            Divider()
            if store.mine.isEmpty {
                ContentUnavailableView("No Entries Yet", systemImage: "square.and.pencil",
                                       description: Text("Add abbreviations you meet in papers or lectures. They show up in Look Up, the quick panel and Expand Text. Import also accepts backups from the Acronome web page."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(store.mine, selection: $selection) {
                    TableColumn("Abbreviation") { m in
                        Text(m.a).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(.tint)
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("Full Form") { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.l)
                            if let d = m.d, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    TableColumn("Field") { m in Text(fieldName(m.f ?? "gen_bio")).foregroundStyle(.secondary) }
                    TableColumn("German") { m in Text(m.de ?? "") }
                    TableColumn("Source") { m in Text(m.src ?? "").foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first, let m = store.mine.first(where: { $0.id == id }) {
                        Button("Edit…") { editing = m }
                    }
                    Button("Delete", role: .destructive) { pendingDelete = ids }
                } primaryAction: { ids in
                    if let id = ids.first { editing = store.mine.first { $0.id == id } }
                }
                .onDeleteCommand { if !selection.isEmpty { pendingDelete = selection } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("My Entries")
        .sheet(item: $editing) { m in
            MineEditor(draft: m, isNew: !store.mine.contains { $0.id == m.id }) { saved, addCard in
                store.upsertMine(saved, addCard: addCard)
            }
        }
        .confirmationDialog(
            pendingDelete?.count == 1 ? "Delete this entry?" : "Delete \(pendingDelete?.count ?? 0) entries?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let ids = pendingDelete { store.deleteMine(ids) }
                pendingDelete = nil
            }
        }
        .onAppear(perform: takePending)
        .onChange(of: model.newEntryAbbr) { takePending() }
    }

    private func takePending() {
        if let a = model.newEntryAbbr {
            model.newEntryAbbr = nil
            editing = .blank(abbr: a)
        }
    }

    private func exportBackup() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]
        p.nameFieldStringValue = "Acronome Backup.json"
        if p.runModal() == .OK, let url = p.url {
            do {
                try store.exportData().write(to: url)
                message = "Exported"
            } catch {
                message = "Couldn’t export: \(error.localizedDescription)"
            }
        }
    }

    private func importBackup() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url {
            do {
                let n = try store.importData(Data(contentsOf: url))
                message = n == 1 ? "Imported 1 new entry" : "Imported \(n) new entries"
            } catch {
                message = "That file isn’t a Acronome backup."
            }
        }
    }
}

@MainActor
struct MineEditor: View {
    @State var draft: MineEntry
    let isNew: Bool
    let onSave: (MineEntry, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var addCard = true

    private var valid: Bool {
        !draft.a.trimmingCharacters(in: .whitespaces).isEmpty && !draft.l.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Abbreviation", text: $draft.a)
                TextField("Full form", text: $draft.l)
                Picker("Field", selection: Binding(get: { draft.f ?? "gen_bio" }, set: { draft.f = $0 })) {
                    ForEach(fieldNames, id: \.key) { Text($0.name).tag($0.key) }
                }
                TextField("Definition or note", text: optional(\.d), axis: .vertical).lineLimit(2...5)
                TextField("German", text: optional(\.de))
                TextField("Source (paper, lecture, DOI)", text: optional(\.src))
                if isNew { Toggle("Add to Flashcards", isOn: $addCard) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var m = draft
                    m.a = m.a.trimmingCharacters(in: .whitespaces)
                    m.l = m.l.trimmingCharacters(in: .whitespaces)
                    onSave(m, addCard)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
    }

    private func optional(_ kp: WritableKeyPath<MineEntry, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: kp] ?? "" },
                set: { draft[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Nomenclature

@MainActor
struct NomenclatureView: View {
    @EnvironmentObject private var library: Library
    @State private var symbol = "BDNF"

    private struct Org: Identifiable {
        let id: String
        let gene: String
        let geneRule: String
        let protein: String
        let proteinRule: String
        let note: String
    }

    private let organisms: [Org] = [
        Org(id: "Human (HGNC)", gene: "BRCA1", geneRule: "italic, all caps", protein: "BRCA1", proteinRule: "roman, all caps",
            note: "Approved symbols only; “p53” for TP53 is informal."),
        Org(id: "Mouse (MGI), rat (RGD)", gene: "Brca1", geneRule: "italic, first letter capital", protein: "BRCA1",
            proteinRule: "roman, all caps", note: "Alleles in superscript, e.g. Brca1 tm1Aash."),
        Org(id: "Zebrafish (ZFIN)", gene: "brca2", geneRule: "italic, all lowercase", protein: "Brca2",
            proteinRule: "roman, first letter capital", note: ""),
        Org(id: "Drosophila (FlyBase)", gene: "white (w), Notch (N)", geneRule: "italic", protein: "White, Notch",
            proteinRule: "roman", note: "Lowercase if first named for a recessive mutant, capitalised if dominant."),
        Org(id: "S. cerevisiae (SGD)", gene: "ADE2 / ade2", geneRule: "italic; caps = wild type, lowercase = recessive mutant",
            protein: "Ade2 or Ade2p", proteinRule: "roman", note: "Deletion: ade2Δ."),
        Org(id: "C. elegans (WormBase)", gene: "unc-22", geneRule: "italic, lowercase, hyphen", protein: "UNC-22",
            proteinRule: "roman, all caps", note: "Alleles: unc-22(e66)."),
        Org(id: "E. coli", gene: "lacZ", geneRule: "italic, three lowercase + capital", protein: "LacZ",
            proteinRule: "roman, first letter capital", note: "Operons: lacZYA."),
        Org(id: "Arabidopsis (TAIR)", gene: "AGAMOUS / AG", geneRule: "italic, all caps; mutants lowercase (ag-1)",
            protein: "AGAMOUS", proteinRule: "roman, all caps", note: ""),
    ]

    private let hgvs: [(String, String)] = [
        ("c.", "Coding DNA position — c.76A>T"),
        ("g.", "Genomic reference — g.12345G>C"),
        ("r.", "RNA, lowercase bases — r.76a>u"),
        ("p.", "Protein — p.(Gly12Asp) or p.G12D; parentheses mark a predicted change"),
        ("del · dup · ins", "Deletion, duplication, insertion — c.1521_1523del"),
        ("fs · Ter · *", "Frameshift, stop codon — p.(Arg97ProfsTer23)"),
        ("rs", "dbSNP reference SNP ID — rs6265 (BDNF Val66Met)"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Gene symbol", text: $symbol)
                            .font(.system(.title3, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        let U = symbol.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
                        if !U.isEmpty {
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                                GridRow { Text("Species").foregroundStyle(.secondary); Text("Gene").foregroundStyle(.secondary); Text("Protein").foregroundStyle(.secondary) }
                                GridRow { Text("Human"); Text(U).italic(); Text(U) }
                                GridRow { Text("Mouse, rat"); Text(mouseCase(U)).italic(); Text(U) }
                                GridRow { Text("Zebrafish"); Text(U.lowercased()).italic(); Text(mouseCase(U)) }
                            }
                            .font(.system(.body, design: .default))
                            hgncStatus(U)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } label: {
                    Text("See how a symbol is written in each species")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Gene and protein naming by organism").font(.headline)
                    Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 12) {
                        GridRow {
                            Text("Organism"); Text("Gene"); Text("Protein"); Text("Notes")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        ForEach(organisms) { o in
                            GridRow {
                                Text(o.id).fontWeight(.medium)
                                VStack(alignment: .leading) { Text(o.gene).italic(); Text(o.geneRule).font(.caption).foregroundStyle(.secondary) }
                                VStack(alignment: .leading) { Text(o.protein); Text(o.proteinRule).font(.caption).foregroundStyle(.secondary) }
                                Text(o.note).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Genes, transcripts and alleles are italic; proteins are roman. Many journals ask for the full gene name once, but gene symbols aren’t abbreviations you must spell out.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Variant notation (HGVS)").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        ForEach(hgvs, id: \.0) { row in
                            GridRow {
                                Text(row.0).font(.system(.body, design: .monospaced).weight(.semibold))
                                Text(row.1)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Gene Nomenclature")
    }

    @ViewBuilder private func hgncStatus(_ U: String) -> some View {
        if let hit = library.exact(U).first(where: { $0.source == .hgnc }) {
            Label("\(hit.abbr) is an approved HGNC symbol: \(hit.long)\(hit.gene.map { " · \($0.location)" } ?? "")",
                  systemImage: "checkmark.seal")
                .foregroundStyle(.secondary)
        } else {
            let aliases = library.entries(forKey: norm(U)).filter { $0.source == .hgnc && $0.abbr != U }
            if aliases.isEmpty {
                Label("Not an approved human gene symbol", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            } else {
                Label("Not approved — an alias or previous symbol of \(aliases.prefix(5).map(\.abbr).joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sources

@MainActor
struct SourcesView: View {
    @EnvironmentObject private var library: Library

    private struct Ref: Identifiable {
        let id: String
        let doi: String
    }

    private let refs: [Ref] = [
        Ref(id: "Grossman Liu, L., Grossman, R. H., Mitchell, E. G., Weng, C., Natarajan, K., Hripcsak, G., & Vawdrey, D. K. (2021). A deep database of medical abbreviations and acronyms for natural language processing. Scientific Data, 8, Article 149.",
            doi: "https://doi.org/10.1038/s41597-021-00929-4"),
        Ref(id: "Schwartz, A. S., & Hearst, M. A. (2003). A simple algorithm for identifying abbreviation definitions in biomedical text. Pacific Symposium on Biocomputing, 8, 451–462.",
            doi: "https://doi.org/10.1142/9789812776303_0042"),
        Ref(id: "Seal, R. L., Braschi, B., Gray, K., Jones, T. E. M., Tweedie, S., Haim-Vilmovsky, L., & Bruford, E. A. (2023). Genenames.org: The HGNC resources in 2023. Nucleic Acids Research, 51(D1), D1003–D1009.",
            doi: "https://doi.org/10.1093/nar/gkac888"),
        Ref(id: "Zhou, W., Torvik, V. I., & Smalheiser, N. R. (2006). ADAM: Another database of abbreviations in MEDLINE. Bioinformatics, 22(22), 2813–2818.",
            doi: "https://doi.org/10.1093/bioinformatics/btl480"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Where the data comes from").font(.title2.weight(.semibold))
                source("Hand-checked", count: library.counts[.core] ?? 0,
                       text: "Molecular and cell biology, genetics, neuroscience, immunology, lab methods, imaging and electrophysiology, statistics (including RQA, CRQA and DFA), pharmacology, physiology and dentistry. Each has a short definition; many have a German equivalent. Written for this app — still check anything important against a primary source.")
                source("Human genes (HGNC)", count: library.counts[.hgnc] ?? 0,
                       text: "Approved human gene symbols (protein-coding and named non-coding RNA) with previous symbols, aliases and chromosome location. HGNC data, CC0. Aliases aren’t unique: one alias can belong to several genes.")
                source("MEDLINE (ADAM)", count: library.counts[.adam] ?? 0,
                       text: (library.counts[.adam] ?? 0) == 0
                           ? "Not installed. Run scripts/fetch_data.py (build.sh does this automatically) to download it; it adds about 34,000 abbreviation meanings from MEDLINE."
                           : "Abbreviation–meaning pairs extracted automatically from MEDLINE abstracts (2006 baseline), kept if defined at least 10 times. Precision is 97.4 % overall, but newer terms are missing and the field labels are keyword guesses. The percentage shows how common a meaning is, not which one your paper means.")
                Text("How Expand Text works").font(.headline).padding(.top, 6)
                Text("Abbreviations your text defines itself, such as “long-term potentiation (LTP)”, are found first and always win. For the rest, the meaning is pre-selected from the other abbreviations and words in the text; you can change it in the glossary. Gene symbols are only matched with exact capitalisation.")
                Text("About").font(.headline).padding(.top, 6)
                Text("Acronome was created by Hadi Azraq and is open source under the MIT License. The MEDLINE layer (ADAM) is GPL-licensed data that is downloaded separately and not part of the app’s source. Answers from Claude are generated, not checked.")
                Text("References").font(.headline).padding(.top, 6)
                ForEach(refs) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.id).textSelection(.enabled)
                        if let u = URL(string: r.doi) { Link(r.doi, destination: u).font(.callout) }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Sources")
    }

    private func source(_ title: String, count: Int, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(text).foregroundStyle(.secondary)
        }
    }
}
