import Foundation

// MARK: - Model

enum Source: String, Codable, CaseIterable, Identifiable {
    case core, mine, hgnc, adam
    var id: String { rawValue }

    var label: String {
        switch self {
        case .core: return "Checked"
        case .mine: return "Mine"
        case .hgnc: return "Human gene"
        case .adam: return "MEDLINE"
        }
    }

    var longLabel: String {
        switch self {
        case .core: return "Hand-checked list"
        case .mine: return "My entries"
        case .hgnc: return "Human genes (HGNC)"
        case .adam: return "MEDLINE (ADAM)"
        }
    }

    var rank: Int {
        switch self {
        case .core, .mine: return 0
        case .hgnc: return 1
        case .adam: return 2
        }
    }
}

let fieldNames: [(key: String, name: String)] = [
    ("mol", "Molecular Biology & Biochemistry"),
    ("gen", "Genetics & Genomics"),
    ("cell", "Cell Biology"),
    ("neuro", "Neuroscience"),
    ("imm", "Immunology"),
    ("micro", "Microbiology & Virology"),
    ("pharm", "Pharmacology"),
    ("phys", "Physiology & Endocrinology"),
    ("meth", "Lab Methods"),
    ("img", "Imaging & Electrophysiology"),
    ("stat", "Statistics & Bioinformatics"),
    ("clin", "Clinical & Psychiatry"),
    ("dent", "Dentistry & Oral Biology"),
    ("eco", "Ecology, Evolution & Development"),
    ("chem", "Chemistry & Reagents"),
    ("gen_bio", "Biomedical (Unclassified)"),
]

func fieldName(_ key: String) -> String {
    fieldNames.first { $0.key == key }?.name ?? key
}

struct GeneInfo: Hashable {
    var kind: String
    var location: String
    var hgncID: String
    var entrezID: String
    var group: String
}

struct Entry: Identifiable, Hashable {
    let id: String
    let abbr: String
    let long: String
    let fields: [String]
    let definition: String
    let german: String
    let source: Source
    var count: Int
    let alts: [String]
    let gene: GeneInfo?
    let note: String
    let aiGenerated: Bool
    let lowerLong: String
    let lowerGerman: String

    init(abbr: String, long: String, fields: [String], definition: String = "", german: String = "",
         source: Source, count: Int = 0, alts: [String] = [], gene: GeneInfo? = nil, note: String = "",
         aiGenerated: Bool = false) {
        self.abbr = abbr
        self.long = long
        self.fields = fields
        self.definition = definition
        self.german = german
        self.source = source
        self.count = count
        self.alts = alts
        self.gene = gene
        self.note = note
        self.aiGenerated = aiGenerated
        self.id = "\(source.rawValue):\(abbr):\(long)"
        self.lowerLong = long.lowercased()
        self.lowerGerman = german.lowercased()
    }

    static func == (a: Entry, b: Entry) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var geneSummary: String? {
        guard let g = gene else { return nil }
        var s = g.kind == "pc" ? "Human protein-coding gene" : "Human non-coding RNA gene"
        if !g.location.isEmpty { s += " · chromosome \(g.location)" }
        if !g.group.isEmpty { s += " · \(g.group)" }
        return s
    }
}

// MARK: - Normalisation

private let greekMap: [Character: String] = [
    "α": "a", "β": "b", "γ": "g", "δ": "d", "ε": "e", "ζ": "z", "η": "h", "θ": "th", "ι": "i",
    "κ": "k", "λ": "l", "μ": "m", "ν": "n", "ξ": "x", "π": "p", "ρ": "r", "σ": "s", "ς": "s",
    "τ": "t", "υ": "u", "φ": "f", "χ": "ch", "ψ": "ps", "ω": "w",
]

private func asciiAlnum(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars where (97...122).contains(u.value) || (48...57).contains(u.value) {
        out.append(u)
    }
    return String(out)
}

/// Case-, hyphen- and Greek-insensitive key: "TNF-α", "TNFa", "tnf alpha" → "tnfa".
func norm(_ s: String) -> String {
    let folded = s.decomposedStringWithCompatibilityMapping.lowercased()
        .folding(options: .diacriticInsensitive, locale: nil)
    var out = ""
    for ch in folded {
        if let g = greekMap[ch] { out += g } else { out.append(ch) }
    }
    for (w, r) in [("alpha", "a"), ("beta", "b"), ("gamma", "g"), ("delta", "d"), ("kappa", "k")] {
        out = out.replacingOccurrences(of: w, with: r)
    }
    return asciiAlnum(out)
}

func lfnorm(_ s: String) -> String {
    var t = asciiAlnum(s.lowercased().replacingOccurrences(of: "ae", with: "e").replacingOccurrences(of: "oe", with: "e"))
    if t.hasSuffix("s") { t.removeLast() }
    return t
}

enum ResourceLocator {
    static func url(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: "json") { return u }
        // `swift run` during development: Resources/data next to Package.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dev = root.appendingPathComponent("Resources/data/\(name).json")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
}

// MARK: - Library

@MainActor
final class Library: ObservableObject {
    @Published private(set) var isLoaded = false
    @Published private(set) var revision = 0
    @Published private(set) var counts: [Source: Int] = [:]

    private(set) var base: [Entry] = []
    private var keyIndex: [String: [Int]] = [:]
    private var exactIndex: [String: [Int]] = [:]
    private var adamTotals: [String: Int] = [:]
    private var sortedKeys: [String] = []

    private(set) var mine: [Entry] = []
    private var mineKey: [String: [Int]] = [:]
    private var mineExact: [String: [Int]] = [:]

    struct Built {
        var entries: [Entry]
        var keyIndex: [String: [Int]]
        var exactIndex: [String: [Int]]
        var totals: [String: Int]
        var sortedKeys: [String]
    }

    func load() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let built = Library.build()
            await self?.apply(built)
        }
    }

    private func apply(_ b: Built) {
        base = b.entries
        keyIndex = b.keyIndex
        exactIndex = b.exactIndex
        adamTotals = b.totals
        sortedKeys = b.sortedKeys
        var c: [Source: Int] = [:]
        for e in base { c[e.source, default: 0] += 1 }
        counts = c
        isLoaded = true
        revision += 1
    }

    nonisolated static func loadRows(_ name: String) -> [[Any]] {
        guard let url = ResourceLocator.url(name),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let rows = obj as? [[Any]] else { return [] }
        return rows
    }

    nonisolated static func build() -> Built {
        var entries: [Entry] = []
        entries.reserveCapacity(64_000)
        for row in loadRows("core") {
            guard row.count >= 5, let a = row[0] as? String, let l = row[1] as? String else { continue }
            entries.append(Entry(abbr: a, long: l, fields: row[2] as? [String] ?? [],
                                 definition: row[3] as? String ?? "", german: row[4] as? String ?? "",
                                 source: .core))
        }
        // Spelling variants of one meaning (tumour/tumor, -alpha/-α/-a, plurals) are merged.
        var senseIndex: [String: Int] = [:]
        for (i, e) in entries.enumerated() { senseIndex[senseKey(e.abbr, e.long)] = i }

        var totals: [String: Int] = [:]
        for row in loadRows("adam") {
            guard row.count >= 5, let a = row[0] as? String, let l = row[1] as? String else { continue }
            let n = (row[3] as? Int) ?? 0
            let k = norm(a)
            totals[k, default: 0] += n
            let sk = senseKey(a, l)
            if let i = senseIndex[sk] { entries[i].count += n; continue }
            senseIndex[sk] = entries.count
            entries.append(Entry(abbr: a, long: l, fields: row[2] as? [String] ?? [], source: .adam,
                                 count: n, alts: row[4] as? [String] ?? []))
        }
        for row in loadRows("hgnc") {
            guard row.count >= 8, let a = row[0] as? String, let l = row[1] as? String else { continue }
            let g = GeneInfo(kind: row[2] as? String ?? "", location: row[3] as? String ?? "",
                             hgncID: row[4] as? String ?? "", entrezID: row[5] as? String ?? "",
                             group: row[7] as? String ?? "")
            entries.append(Entry(abbr: a, long: l, fields: ["gen"], source: .hgnc,
                                 alts: row[6] as? [String] ?? [], gene: g))
        }
        var key: [String: [Int]] = [:]
        var exact: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() { index(e, i, &key, &exact) }
        return Built(entries: entries, keyIndex: key, exactIndex: exact, totals: totals,
                     sortedKeys: key.keys.sorted())
    }

    nonisolated static func senseKey(_ abbr: String, _ long: String) -> String {
        var l = long.lowercased()
            .replacingOccurrences(of: "our", with: "or")
            .replacingOccurrences(of: "alfa", with: "alpha")
            .replacingOccurrences(of: "ae", with: "e")
            .replacingOccurrences(of: "oe", with: "e")
        l = norm(l)
        if l.hasSuffix("s") { l.removeLast() }
        return norm(abbr) + "|" + l
    }

    nonisolated static func index(_ e: Entry, _ i: Int, _ key: inout [String: [Int]], _ exact: inout [String: [Int]]) {
        var keys = Set<String>([norm(e.abbr)])
        for a in e.alts { keys.insert(norm(a)) }
        for k in keys where !k.isEmpty { key[k, default: []].append(i) }
        var ex = [e.abbr]
        if e.source != .hgnc { ex += e.alts }
        for x in ex { exact[x, default: []].append(i) }
    }

    func setMine(_ items: [MineEntry]) {
        mine = items.map {
            Entry(abbr: $0.a, long: $0.l, fields: [$0.f ?? "gen_bio"], definition: $0.d ?? "",
                  german: $0.de ?? "", source: .mine, note: $0.src ?? "", aiGenerated: $0.ai ?? false)
        }
        var k: [String: [Int]] = [:]
        var ex: [String: [Int]] = [:]
        for (i, e) in mine.enumerated() { Library.index(e, i, &k, &ex) }
        mineKey = k
        mineExact = ex
        revision += 1
    }

    // MARK: Queries

    func entries(forKey k: String) -> [Entry] {
        (keyIndex[k] ?? []).map { base[$0] } + (mineKey[k] ?? []).map { mine[$0] }
    }

    func exact(_ s: String) -> [Entry] {
        (exactIndex[s] ?? []).map { base[$0] } + (mineExact[s] ?? []).map { mine[$0] }
    }

    func sort(_ list: [Entry], query: String) -> [Entry] {
        list.sorted { x, y in
            if x.source.rank != y.source.rank { return x.source.rank < y.source.rank }
            let xe = x.abbr == query, ye = y.abbr == query
            if xe != ye { return xe }
            if x.count != y.count { return x.count > y.count }
            return x.long.localizedCaseInsensitiveCompare(y.long) == .orderedAscending
        }
    }

    func search(_ raw: String, sources: Set<Source> = Set(Source.allCases), fields: Set<String> = []) -> [Entry] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        let k = norm(q)
        guard !k.isEmpty else { return [] }
        var hits = entries(forKey: k).filter { sources.contains($0.source) }
        if !fields.isEmpty { hits = hits.filter { !Set($0.fields).isDisjoint(with: fields) } }
        return sort(hits, query: q)
    }

    /// Share of all MEDLINE definitions of this abbreviation that use this meaning (0…1).
    func share(_ e: Entry) -> Double {
        let tot = adamTotals[norm(e.abbr)] ?? 0
        return tot > 0 ? min(1, Double(e.count) / Double(tot)) : 0
    }

    private func display(_ key: String) -> String {
        if let i = keyIndex[key]?.first { return base[i].abbr }
        if let i = mineKey[key]?.first { return mine[i].abbr }
        return key
    }

    func prefixMatches(_ raw: String, limit: Int = 24) -> [String] {
        let k = norm(raw)
        guard !k.isEmpty else { return [] }
        var lo = 0, hi = sortedKeys.count
        while lo < hi {
            let m = (lo + hi) / 2
            if sortedKeys[m] < k { lo = m + 1 } else { hi = m }
        }
        var out: [String] = []
        var i = lo
        while i < sortedKeys.count, out.count < limit, sortedKeys[i].hasPrefix(k) {
            if sortedKeys[i] != k { out.append(display(sortedKeys[i])) }
            i += 1
        }
        return out
    }

    func fuzzy(_ raw: String, limit: Int = 12) -> [String] {
        let k = norm(raw)
        guard k.count >= 2 else { return [] }
        let a = Array(k.utf8)
        var out: [String] = []
        for key in sortedKeys where key != k && abs(key.utf8.count - a.count) <= 1 {
            if Library.oneEdit(a, Array(key.utf8)) {
                out.append(display(key))
                if out.count >= limit { break }
            }
        }
        return out
    }

    nonisolated static func oneEdit(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var i = 0, j = 0, d = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            d += 1
            if d > 1 { return false }
            if a.count > b.count { i += 1 } else if b.count > a.count { j += 1 } else { i += 1; j += 1 }
        }
        return d + (a.count - i) + (b.count - j) <= 1
    }

    /// Full term (English or German) → abbreviations.
    func reverse(_ raw: String, limit: Int = 80) -> (total: Int, hits: [Entry]) {
        let q = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return (0, []) }
        let words = q.split(whereSeparator: { " ,;/".contains($0) }).map(String.init)
        var hits: [(Int, Entry)] = []
        for e in [base, mine].joined() {
            guard words.allSatisfy({ e.lowerLong.contains($0) || e.lowerGerman.contains($0) }) else { continue }
            let germanParts = e.lowerGerman.split(whereSeparator: { "()".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let exact = (e.lowerLong == q || e.lowerGerman == q || germanParts.contains(q)) ? 0 : 1
            hits.append((exact, e))
        }
        hits.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.source.rank != b.1.source.rank { return a.1.source.rank < b.1.source.rank }
            return a.1.count > b.1.count
        }
        return (hits.count, hits.prefix(limit).map { $0.1 })
    }

    func randomCore(field: String?, excluding: Set<String>, count: Int) -> [Entry] {
        base.filter { $0.source == .core && (field == nil || $0.fields.contains(field!)) && !excluding.contains($0.id) }
            .shuffled().prefix(count).map { $0 }
    }
}

// MARK: - Links

enum Links {
    static func pubmed(_ e: Entry) -> URL? {
        var c = URLComponents(string: "https://pubmed.ncbi.nlm.nih.gov/")
        c?.queryItems = [URLQueryItem(name: "term", value: "\"\(e.abbr)\" \"\(e.long)\"")]
        return c?.url
    }

    static func mesh(_ e: Entry) -> URL? {
        var c = URLComponents(string: "https://meshb.nlm.nih.gov/search")
        c?.queryItems = [URLQueryItem(name: "searchInField", value: "allTerms"), URLQueryItem(name: "q", value: e.long)]
        return c?.url
    }

    static func hgnc(_ e: Entry) -> URL? {
        guard let g = e.gene else { return nil }
        return URL(string: "https://www.genenames.org/data/gene-symbol-report/#!/hgnc_id/HGNC:\(g.hgncID)")
    }

    static func ncbiGene(_ e: Entry) -> URL? {
        guard let g = e.gene, !g.entrezID.isEmpty else { return nil }
        return URL(string: "https://www.ncbi.nlm.nih.gov/gene/\(g.entrezID)")
    }
}
