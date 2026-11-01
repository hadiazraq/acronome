import AppKit
import Foundation
import Security
import SwiftUI

// MARK: - Settings

enum ClaudeProvider: String, CaseIterable, Identifiable {
    case api, cli
    var id: String { rawValue }
    var label: String { self == .api ? "Anthropic API key" : "Claude Code (your Claude plan)" }
}

enum ClaudeModel: String, CaseIterable, Identifiable {
    case haiku, sonnet, opus
    var id: String { rawValue }
    var label: String {
        switch self {
        case .haiku: return "Haiku 5.5 — fastest"
        case .sonnet: return "Sonnet 5.5 — balanced"
        case .opus: return "Opus 5.5 — most thorough"
        }
    }
    var apiID: String { "claude-\(rawValue)-5-5" }
    var shortName: String { rawValue.capitalized + " 5.5" }
}

enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "io.github.acronome.app") + ".anthropic"
    private static let account = "api-key"

    static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(key.utf8)]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

struct ClaudeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A meaning Claude proposes for an abbreviation that isn't in the database.
struct AIMeaning: Codable, Hashable, Identifiable {
    var long: String
    var field: String?
    var definition: String?
    var german: String?
    var confidence: String?
    var id: String { long }
}

private struct AIMeaningList: Codable { var meanings: [AIMeaning] }

// MARK: - Service

@MainActor
final class ClaudeService: ObservableObject {
    @Published private(set) var loading = Set<String>()
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var proposals: [String: [AIMeaning]] = [:]   // keyed by norm(abbreviation)

    private let store: UserStore

    init(store: UserStore) { self.store = store }

    static var provider: ClaudeProvider {
        if let raw = UserDefaults.standard.string(forKey: "claudeProvider"), let p = ClaudeProvider(rawValue: raw) { return p }
        return Keychain.read() != nil ? .api : .cli
    }

    static var model: ClaudeModel {
        ClaudeModel(rawValue: UserDefaults.standard.string(forKey: "claudeModel") ?? "") ?? .sonnet
    }

    static func detectCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [UserDefaults.standard.string(forKey: "claudeCLIPath") ?? "",
                          "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Prompts

    private static let explainSystem = """
    You write glossary notes on abbreviations in biology, neuroscience and biomedical research for graduate \
    students and researchers in the life sciences. Be formal, precise and research-level. Use Markdown, with these bold headings \
    on their own lines, each followed by short text or "- " bullets: **Definition**, **Mechanism and context**, \
    **In the literature** (how papers use the term, typical measures or methods), **Related terms**, **German**, \
    **Key references**. Keep it under 260 words. Explain only the meaning you are given. For references, list 1–3 \
    real, well-known papers or reviews in APA 7 with DOI; if you are not certain a reference or DOI exists, leave it \
    out rather than guess. Write nothing before the first heading.
    """

    private static var lookupSystem: String {
        let codes = fieldNames.map(\.key).joined(separator: ", ")
        return """
        You expand abbreviations used in biology, neuroscience and biomedical research. Reply with JSON only — no \
        prose, no code fence — in exactly this shape: {"meanings":[{"long":"full form","field":"one of: \(codes)",\
        "definition":"one sentence, at most 25 words","german":"German term or empty string",\
        "confidence":"high|medium|low"}]}. List up to 5 meanings in these fields, most common first. If the context \
        names a field, put meanings from that field first. Never invent a meaning; if you know none, return \
        {"meanings":[]}.
        """
    }

    // MARK: Actions

    func explain(_ e: Entry) {
        guard !loading.contains(e.id) else { return }
        loading.insert(e.id)
        errors[e.id] = nil
        var prompt = "Abbreviation: \(e.abbr)\nMeaning: \(e.long)"
        let fields = e.fields.filter { $0 != "gen_bio" }.map(fieldName)
        if !fields.isEmpty { prompt += "\nField: \(fields.joined(separator: ", "))" }
        if !e.definition.isEmpty { prompt += "\nShort definition already on file: \(e.definition)" }
        if let g = e.geneSummary { prompt += "\nThis is a human gene symbol (HGNC): \(g)" }
        let model = Self.model
        Task {
            do {
                let text = try await complete(system: Self.explainSystem, prompt: prompt, maxTokens: 900)
                store.setNote(AINote(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                     model: model.shortName, date: Date()), for: e.id)
            } catch {
                errors[e.id] = error.localizedDescription
            }
            loading.remove(e.id)
        }
    }

    func lookup(_ abbr: String) {
        let key = "q:" + norm(abbr)
        guard !loading.contains(key) else { return }
        loading.insert(key)
        errors[key] = nil
        Task {
            do {
                let raw = try await complete(system: Self.lookupSystem, prompt: "Abbreviation: \(abbr)", maxTokens: 700)
                guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
                      let data = String(raw[start...end]).data(using: .utf8) else {
                    throw ClaudeError(message: "Claude’s answer couldn’t be read. Try again.")
                }
                let list = try JSONDecoder().decode(AIMeaningList.self, from: data)
                proposals[norm(abbr)] = list.meanings.filter { !$0.long.trimmingCharacters(in: .whitespaces).isEmpty }
            } catch let e as ClaudeError {
                errors[key] = e.message
            } catch {
                errors[key] = error.localizedDescription
            }
            loading.remove(key)
        }
    }

    func test() async -> String {
        do {
            let r = try await complete(system: "Answer in at most five words.", prompt: "Expand the abbreviation LTP in neuroscience.", maxTokens: 30)
            return "Connected — \(Self.model.shortName) replied: “\(r.trimmingCharacters(in: .whitespacesAndNewlines))”"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Transport

    func complete(system: String, prompt: String, maxTokens: Int) async throws -> String {
        switch Self.provider {
        case .api: return try await callAPI(system: system, prompt: prompt, maxTokens: maxTokens)
        case .cli: return try await callCLI(system: system, prompt: prompt)
        }
    }

    private func callAPI(system: String, prompt: String, maxTokens: Int) async throws -> String {
        guard let key = Keychain.read(), !key.isEmpty else {
            throw ClaudeError(message: "No API key saved. Add one in Settings → Claude.")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["model": Self.model.apiID, "max_tokens": maxTokens, "system": system,
                                   "messages": [["role": "user", "content": prompt]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = (obj?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw ClaudeError(message: "Anthropic API: \(msg)")
        }
        let blocks = obj?["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw ClaudeError(message: "Claude returned an empty answer.") }
        return text
    }

    private func callCLI(system: String, prompt: String) async throws -> String {
        guard let path = Self.detectCLI() else {
            throw ClaudeError(message: "Claude Code wasn’t found. Install it, set its path in Settings → Claude, or use an API key.")
        }
        let model = Self.model.rawValue
        let out: Data = try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-p", prompt, "--model", model, "--output-format", "json", "--tools", "",
                           "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
                           "--system-prompt", system]
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (URL(fileURLWithPath: path).deletingLastPathComponent().path) + ":/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try p.run()
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 150, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            return data
        }.value
        guard let obj = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] else {
            throw ClaudeError(message: "Claude Code gave no readable answer.")
        }
        let result = obj["result"] as? String ?? ""
        if (obj["is_error"] as? Bool) == true {
            var msg = "Claude Code: \(result.isEmpty ? "request failed" : result)"
            if result.localizedCaseInsensitiveContains("auth") {
                msg += " — open Terminal, run `claude`, and log in again."
            }
            throw ClaudeError(message: msg)
        }
        guard !result.isEmpty else { throw ClaudeError(message: "Claude returned an empty answer.") }
        return result
    }
}

// MARK: - Views

/// Claude's explanation of one meaning: a button until asked, then the cached note.
@MainActor
struct ExplanationView: View {
    let entry: Entry
    @EnvironmentObject private var claude: ClaudeService
    @EnvironmentObject private var store: UserStore

    var body: some View {
        if let note = store.aiNotes[entry.id] {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Text(markdown(note.text))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label("Claude \(note.model) · \(note.date.formatted(date: .abbreviated, time: .omitted)) · not verified",
                          systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if claude.loading.contains(entry.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Regenerate") { claude.explain(entry) }
                        Button("Copy") { copyToPasteboard(note.text) }
                    }
                }
                .controlSize(.small)
                if let err = claude.errors[entry.id] { Text(err).font(.caption).foregroundStyle(.red) }
            }
        } else if claude.loading.contains(entry.id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking Claude…").foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button { claude.explain(entry) } label: { Label("Explain with Claude", systemImage: "sparkles") }
                if let err = claude.errors[entry.id] {
                    Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func markdown(_ raw: String) -> AttributedString {
        let s = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.drop(while: { $0 == " " })
            if t.hasPrefix("- ") || t.hasPrefix("* ") { return "•  " + t.dropFirst(2) }
            if t.hasPrefix("#") { return "**" + t.drop(while: { $0 == "#" || $0 == " " }) + "**" }
            return String(line)
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// For an abbreviation that isn't in the database: ask Claude, then save chosen meanings to My Entries.
@MainActor
struct AskClaudeView: View {
    let abbr: String
    @EnvironmentObject private var claude: ClaudeService
    @EnvironmentObject private var store: UserStore

    private var key: String { norm(abbr) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let list = claude.proposals[key] {
                if list.isEmpty {
                    Text("Claude doesn’t know a meaning for “\(abbr)” in these fields either.")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Claude suggests — not verified", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(list) { m in row(m) }
                }
            } else if claude.loading.contains("q:" + key) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking Claude…").foregroundStyle(.secondary)
                }
            } else {
                Button { claude.lookup(abbr) } label: { Label("Ask Claude", systemImage: "sparkles") }
                    .help("Ask Claude what “\(abbr)” can stand for")
            }
            if let err = claude.errors["q:" + key] {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 520)
    }

    private func saved(_ m: AIMeaning) -> Bool {
        store.mine.contains { norm($0.a) == key && $0.l.lowercased() == m.long.lowercased() }
    }

    private func row(_ m: AIMeaning) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.long).fontWeight(.semibold)
                if let d = m.definition, !d.isEmpty { Text(d).font(.callout) }
                HStack(spacing: 6) {
                    if let f = m.field { Text(fieldName(f)) }
                    if let c = m.confidence { Text("· \(c) confidence") }
                    if let g = m.german, !g.isEmpty { Text("· German: \(g)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if saved(m) {
                Label("Saved", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Save to My Entries") { save(m) }.controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func save(_ m: AIMeaning) {
        var e = MineEntry.blank(abbr: abbr)
        e.l = m.long
        e.f = fieldNames.contains { $0.key == m.field } ? m.field : "gen_bio"
        e.d = m.definition
        e.de = (m.german?.isEmpty ?? true) ? nil : m.german
        e.src = "Claude \(ClaudeService.model.shortName), \(Date().formatted(date: .abbreviated, time: .omitted)) — not verified"
        e.ai = true
        store.upsertMine(e, addCard: false)
    }
}

/// Main-window sheet with an entry and its explanation.
@MainActor
struct ExplainSheet: View {
    let entry: Entry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    EntryDetail(entry: entry, compact: true)
                    ExplanationView(entry: entry)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 600, height: 560)
    }
}

/// Settings → Claude.
@MainActor
struct ClaudeSettingsSection: View {
    @EnvironmentObject private var claude: ClaudeService
    @AppStorage("claudeProvider") private var provider = ClaudeService.provider.rawValue
    @AppStorage("claudeModel") private var model = ClaudeModel.sonnet.rawValue
    @AppStorage("claudeCLIPath") private var cliPath = ""
    @State private var keyDraft = ""
    @State private var hasKey = Keychain.read() != nil
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Section {
            Picker("Connect through", selection: $provider) {
                ForEach(ClaudeProvider.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if provider == ClaudeProvider.api.rawValue {
                if hasKey {
                    LabeledContent("API key") {
                        HStack {
                            Text("Saved in Keychain").foregroundStyle(.secondary)
                            Button("Remove") { Keychain.delete(); hasKey = false }
                        }
                    }
                } else {
                    LabeledContent("API key") {
                        HStack {
                            SecureField("sk-ant-…", text: $keyDraft).frame(minWidth: 160)
                            Button("Save") {
                                hasKey = Keychain.save(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                                keyDraft = ""
                            }
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            } else {
                LabeledContent("Claude Code") {
                    TextField("", text: $cliPath, prompt: Text(ClaudeService.detectCLI() ?? "Path to claude"))
                        .frame(minWidth: 200)
                }
            }
            Picker("Model", selection: $model) {
                ForEach(ClaudeModel.allCases) { Text($0.label).tag($0.rawValue) }
            }
            HStack {
                Button("Test Connection") {
                    testing = true
                    testResult = nil
                    Task {
                        testResult = await claude.test()
                        testing = false
                    }
                }
                .disabled(testing)
                if testing { ProgressView().controlSize(.small) }
            }
            if let testResult {
                Text(testResult).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("Used only when you ask: Explain with Claude (⌘E in the quick panel) and Ask Claude for abbreviations that aren’t in the database. Answers are marked as not verified; explanations are saved on this Mac.")
                .foregroundStyle(.secondary)
        }
    }
}
