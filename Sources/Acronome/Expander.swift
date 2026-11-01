import Foundation

struct ExpandToken {
    let range: NSRange
    let key: String
    let local: Bool
}

struct ExpansionResult {
    var text = ""
    var tokens: [ExpandToken] = []
    var defs: [String: String] = [:]      // defined in the text itself
    var senses: [String: [Entry]] = [:]
    var choice: [String: Int] = [:]

    var keys: [String] {
        Array(Set(tokens.map(\.key))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func chosen(_ k: String) -> (long: String, entry: Entry?) {
        if let d = defs[k] { return (d, nil) }
        guard let s = senses[k], !s.isEmpty else { return (k, nil) }
        let e = s[min(choice[k] ?? 0, s.count - 1)]
        return (e.long, e)
    }

    func glossaryText() -> String {
        keys.map { "\($0) — \(chosen($0).long)" }.joined(separator: "\n")
    }

    /// APA style: spell each abbreviation out at its first use, e.g. "long-term potentiation (LTP)".
    func expandedText() -> String {
        let ns = text as NSString
        var out = ""
        var pos = 0
        var done = Set(defs.keys)
        for t in tokens {
            out += ns.substring(with: NSRange(location: pos, length: t.range.location - pos))
            let orig = ns.substring(with: t.range)
            if done.contains(t.key) {
                out += orig
            } else {
                done.insert(t.key)
                out += "\(chosen(t.key).long) (\(orig))"
            }
            pos = t.range.location + t.range.length
        }
        out += ns.substring(from: pos)
        return out
    }
}

@MainActor
enum Expander {
    static let example = "Long-term potentiation (LTP) at Schaffer collateral–CA1 synapses requires NMDAR activation and CaMKII autophosphorylation. In acute slices from P21 mice, BDNF–TrkB signalling enhanced LTP, whereas siRNA knockdown of CREB abolished it. Western blot (WB) and RT-qPCR showed reduced Arc mRNA. EEG recordings revealed increased theta PSD, and RQA of the LFP indicated higher DET. GFAP immunoreactivity and ROS levels were unchanged; data are mean ± SEM, analysed by two-way ANOVA with FDR correction."

    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9α-ωΑ-Ω][A-Za-z0-9α-ωΑ-Ω\-/′'+.]*[A-Za-z0-9α-ωΑ-Ω+]|[A-Za-zα-ω]"#)
    private static let defRegex = try! NSRegularExpression(pattern: #"\(([^()]{1,14})\)"#)
    private static let stop: Set<String> = ["with", "from", "that", "this", "into", "type", "factor",
                                            "protein", "cell", "cells", "acid", "human", "test", "analysis"]

    static func run(_ text: String, library: Library) -> ExpansionResult {
        var r = ExpansionResult()
        r.text = text
        r.defs = findDefs(text)
        let ns = text as NSString
        for m in tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var t = ns.substring(with: m.range)
            var range = m.range
            if r.defs[t] != nil {
                r.tokens.append(ExpandToken(range: range, key: t, local: true))
                continue
            }
            var senses = r.senses[t] ?? lookup(t, library)
            if senses == nil, t.contains("-"), let head = t.split(separator: "-").first.map(String.init),
               head.count >= 2, let s = lookup(head, library) {
                senses = s
                t = head
                range = NSRange(location: range.location, length: (head as NSString).length)
            }
            guard let s = senses else { continue }
            if r.senses[t] == nil { r.senses[t] = s }
            r.tokens.append(ExpandToken(range: range, key: t, local: false))
        }
        disambiguate(&r)
        return r
    }

    // Schwartz & Hearst (2003): "long form (SF)" definitions inside the text.
    static func findDefs(_ text: String) -> [String: String] {
        let ns = text as NSString
        var defs: [String: String] = [:]
        for m in defRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var sf = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if let r = sf.range(of: #"[;,]\s"#, options: .regularExpression) { sf = String(sf[..<r.lowerBound]) }
            guard sf.count >= 2, sf.split(separator: " ").count <= 2, sf.contains(where: { $0.isLetter }),
                  let first = sf.first, first.isLetter || first.isNumber else { continue }
            let start = max(0, m.range.location - 250)
            let before = ns.substring(with: NSRange(location: start, length: m.range.location - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let words = before.split(whereSeparator: { $0.isWhitespace })
            let maxW = min(sf.count + 5, sf.count * 2)
            let cand = words.suffix(maxW).joined(separator: " ")
            if let lf = bestLF(sf, cand), lf.count > sf.count, defs[sf] == nil {
                defs[sf] = String(lf.drop(while: { !$0.isLetter && !$0.isNumber }))
            }
        }
        return defs
    }

    static func bestLF(_ sf: String, _ lf: String) -> String? {
        let S = Array(sf.lowercased()), L = Array(lf.lowercased()), orig = Array(lf)
        guard L.count == orig.count, !L.isEmpty else { return nil }
        func alnum(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var s = S.count - 1, l = L.count - 1
        while s >= 0 {
            let c = S[s]
            if !alnum(c) { s -= 1; continue }
            while (l >= 0 && L[l] != c) || (s == 0 && l > 0 && alnum(L[l - 1])) { l -= 1 }
            if l < 0 { return nil }
            l -= 1
            s -= 1
        }
        var start = 0
        var i = l
        while i >= 0 {
            if L[i] == " " { start = i + 1; break }
            i -= 1
        }
        return String(orig[start...]).trimmingCharacters(in: .whitespaces)
    }

    static func looksAbbr(_ t: String) -> Bool {
        guard t.count >= 2 else { return false }
        let ups = t.filter { $0.isUppercase }.count
        if ups >= 2 { return true }
        if let f = t.first, f.isLowercase, ups > 0 { return true }               // mRNA, cAMP
        if t.contains(where: { $0.isLetter }) && t.contains(where: { $0.isNumber }) { return true }   // CA1
        if t.unicodeScalars.contains(where: { (0x391...0x3C9).contains($0.value) }) { return true }
        return false
    }

    static func lookup(_ t: String, _ lib: Library) -> [Entry]? {
        var ex = lib.exact(t)
        let curated = ex.contains { $0.source == .core || $0.source == .mine }
        if !looksAbbr(t) && !curated { return nil }
        if ex.isEmpty { ex = lib.entries(forKey: norm(t)).filter { $0.source != .hgnc } }
        if ex.isEmpty, t.hasSuffix("s"), t.count > 2 {      // plurals: SNPs, GPCRs
            let b = String(t.dropLast())
            ex = lib.exact(b)
            if ex.isEmpty, looksAbbr(b) { ex = lib.entries(forKey: norm(b)).filter { $0.source != .hgnc } }
        }
        return ex.isEmpty ? nil : lib.sort(ex, query: t)
    }

    /// Picks the most plausible meaning from the document's other abbreviations and words.
    static func disambiguate(_ r: inout ExpansionResult) {
        var profile: [String: Int] = [:]
        for (_, s) in r.senses {
            let cur = s.filter { $0.source == .core || $0.source == .mine }
            if cur.count == 1 { for f in cur[0].fields { profile[f, default: 0] += 1 } }
        }
        let low = r.text.lowercased()
        for (k, s) in r.senses where s.count > 1 {
            var best = 0
            var bestScore = -Double.infinity
            for (i, x) in s.enumerated() {
                var sc: Double
                switch x.source {
                case .core, .mine: sc = 3
                case .hgnc: sc = 1
                case .adam: sc = log10(Double(max(x.count, 1))) / 2
                }
                sc += x.fields.reduce(0.0) { $0 + Double(min(3, profile[$1] ?? 0)) * 0.6 }
                let words = x.lowerLong.split(whereSeparator: { !$0.isLetter }).map(String.init)
                    .filter { $0.count >= 4 && !stop.contains($0) }
                sc += Double(words.filter { low.contains($0) }.count) * 1.5
                if sc > bestScore { bestScore = sc; best = i }
            }
            r.choice[k] = best
        }
    }
}
