import Foundation

struct MineEntry: Codable, Identifiable, Hashable {
    var id: String
    var a: String
    var l: String
    var f: String?
    var d: String?
    var de: String?
    var src: String?
    var t: Double?
    var ai: Bool?      // suggested by Claude, not verified

    static func blank(abbr: String = "") -> MineEntry {
        MineEntry(id: "m" + UUID().uuidString.prefix(8).lowercased(), a: abbr, l: "", f: "gen_bio",
                  t: Date().timeIntervalSince1970 * 1000)
    }
}

struct AINote: Codable, Hashable {
    var text: String
    var model: String
    var date: Date
}

struct Card: Codable, Hashable {
    var a: String
    var l: String
    var d: String?
    var de: String?
    var f: [String]?
    var box: Int
    var due: Double   // ms since 1970 — same format as the web version's backups
}

/// File format shared with the Acronome web page's backup JSON.
struct Backup: Codable {
    var app: String?
    var v: Int?
    var mine: [MineEntry]
    var cards: [String: Card]?
    var recent: [String]?
}

@MainActor
final class UserStore: ObservableObject {
    @Published private(set) var mine: [MineEntry] = []
    @Published private(set) var cards: [String: Card] = [:]
    @Published private(set) var recent: [String] = []
    @Published private(set) var aiNotes: [String: AINote] = [:]   // Claude explanations, keyed by entry id

    static let intervals: [Double] = [0, 0, 1, 3, 7, 16, 35]   // days, indexed by box 1…6
    private let fileURL: URL
    private let notesURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Acronome", isDirectory: true)
        // The app was called BioAbbr before its first public release: carry its data over once.
        let legacy = support.appendingPathComponent("BioAbbr", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("state.json")
        notesURL = dir.appendingPathComponent("ai-notes.json")
        if let data = try? Data(contentsOf: notesURL),
           let n = try? JSONDecoder().decode([String: AINote].self, from: data) {
            aiNotes = n
        }
        if let data = try? Data(contentsOf: fileURL),
           let b = try? JSONDecoder().decode(Backup.self, from: data) {
            mine = b.mine
            cards = b.cards ?? [:]
            recent = b.recent ?? []
        }
    }

    static var nowMS: Double { Date().timeIntervalSince1970 * 1000 }

    private func save() {
        let b = Backup(app: "acronome", v: 1, mine: mine, cards: cards, recent: recent)
        if let data = try? JSONEncoder().encode(b) { try? data.write(to: fileURL, options: .atomic) }
    }

    func setNote(_ note: AINote, for id: String) {
        aiNotes[id] = note
        if let data = try? JSONEncoder().encode(aiNotes) { try? data.write(to: notesURL, options: .atomic) }
    }

    // MARK: Flashcards

    func hasCard(_ id: String) -> Bool { cards[id] != nil }

    private func makeCard(_ e: Entry) -> Card {
        let d = e.definition.isEmpty ? (e.source == .hgnc ? e.geneSummary : nil) : e.definition
        return Card(a: e.abbr, l: e.long, d: d, de: e.german.isEmpty ? nil : e.german, f: e.fields, box: 1, due: 0)
    }

    func toggleCard(_ e: Entry) {
        if cards[e.id] != nil { cards[e.id] = nil } else { cards[e.id] = makeCard(e) }
        save()
    }

    @discardableResult
    func addCards(_ list: [Entry]) -> Int {
        var n = 0
        for e in list where cards[e.id] == nil { cards[e.id] = makeCard(e); n += 1 }
        if n > 0 { save() }
        return n
    }

    func addLocalCard(abbr: String, long: String) -> Bool {
        let id = "mine:\(abbr):\(long)"
        guard cards[id] == nil else { return false }
        cards[id] = Card(a: abbr, l: long, d: "Defined in a pasted text", de: nil, f: ["gen_bio"], box: 1, due: 0)
        save()
        return true
    }

    func removeCard(_ id: String) {
        cards[id] = nil
        save()
    }

    var dueIDs: [String] {
        let now = Self.nowMS
        return cards.filter { $0.value.due <= now }
            .sorted { ($0.value.box, $0.value.due, $0.key) < ($1.value.box, $1.value.due, $1.key) }
            .map(\.key)
    }

    /// 1 again · 2 hard · 3 good · 4 easy (Leitner boxes 1–6)
    func grade(_ id: String, _ g: Int) {
        guard var c = cards[id] else { return }
        let day = 86_400_000.0, now = Self.nowMS
        switch g {
        case 1:
            c.box = 1
            c.due = now + 10 * 60_000
        case 2:
            c.due = now + max(0.5, Self.intervals[c.box] / 2) * day
        default:
            c.box = min(6, c.box + (g == 4 ? 2 : 1))
            c.due = now + Self.intervals[c.box] * day
        }
        cards[id] = c
        save()
    }

    func makeAllDue() {
        for k in cards.keys { cards[k]?.due = 0 }
        save()
    }

    // MARK: My entries

    func upsertMine(_ m: MineEntry, addCard: Bool) {
        let newID = "mine:\(m.a):\(m.l)"
        if let i = mine.firstIndex(where: { $0.id == m.id }) {
            let old = mine[i]
            mine[i] = m
            let oldID = "mine:\(old.a):\(old.l)"
            if oldID != newID, let c = cards[oldID] {
                cards[oldID] = nil
                cards[newID] = Card(a: m.a, l: m.l, d: m.d, de: m.de, f: [m.f ?? "gen_bio"], box: c.box, due: c.due)
            }
        } else {
            mine.insert(m, at: 0)
            if addCard {
                cards[newID] = Card(a: m.a, l: m.l, d: m.d, de: m.de, f: [m.f ?? "gen_bio"], box: 1, due: 0)
            }
        }
        save()
    }

    func deleteMine(_ ids: Set<String>) {
        mine.removeAll { ids.contains($0.id) }
        save()
    }

    func pushRecent(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        recent = [t] + recent.filter { norm($0) != norm(t) }
        recent = Array(recent.prefix(20))
        save()
    }

    // MARK: Backup

    func exportData() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(Backup(app: "acronome", v: 1, mine: mine, cards: cards, recent: nil))) ?? Data()
    }

    /// Merges a backup (from this app or the web version). Returns the number of new entries.
    func importData(_ data: Data) throws -> Int {
        let b = try JSONDecoder().decode(Backup.self, from: data)
        let known = Set(mine.map(\.id))
        let fresh = b.mine.filter { !known.contains($0.id) }
        mine += fresh
        for (k, v) in b.cards ?? [:] { cards[k] = v }
        save()
        return fresh.count
    }
}
