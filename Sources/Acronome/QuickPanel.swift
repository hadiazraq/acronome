import AppKit
import SwiftUI

// MARK: - Panel window

/// Spotlight-style floating panel: takes keyboard focus without activating the app.
final class QuickPanel: NSPanel {
    var onCommandReturn: (() -> Void)?
    var onOpenApp: (() -> Void)?
    var onExplain: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    // The app isn't active while the panel is up, so the Edit menu can't deliver ⌘V etc.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            if event.keyCode == 36 || event.keyCode == 76 { onCommandReturn?(); return true }   // ⌘↩
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o": onOpenApp?(); return true
            case "e": onExplain?(); return true
            case "w": orderOut(nil); return true
            case "v": if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c": if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x": if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a": if NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self) { return true }
            case "z": if NSApp.sendAction(Selector(("undo:")), to: nil, from: self) { return true }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - State

@MainActor
final class QuickState: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { recompute() } }
    }
    @Published private(set) var results: [Entry] = []
    @Published private(set) var suggestions: [String] = []
    @Published var selection = 0
    @Published var focusToken = 0
    @Published var flash: String?

    let library: Library

    init(library: Library) { self.library = library }

    var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var selected: Entry? { results.indices.contains(selection) ? results[selection] : nil }

    func prepare(prefill: String?) {
        flash = nil
        if let prefill, prefill != query { query = prefill } else { recompute() }
    }

    func recompute() {
        let q = trimmed
        results = q.isEmpty ? [] : Array(library.search(q).prefix(80))
        if results.isEmpty, !q.isEmpty {
            var seen = Set<String>()
            suggestions = (library.prefixMatches(q, limit: 10) + library.fuzzy(q, limit: 8))
                .filter { seen.insert($0).inserted }
        } else {
            suggestions = []
        }
        selection = 0
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = max(0, min(results.count - 1, selection + delta))
    }
}

// MARK: - Controller

@MainActor
final class QuickPanelController {
    let state: QuickState
    private unowned let app: AppModel
    private var panel: QuickPanel?

    init(app: AppModel) {
        self.app = app
        self.state = QuickState(library: app.library)
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        let usePasteboard = UserDefaults.standard.bool(forKey: "prefillClipboard")
        state.prepare(prefill: usePasteboard ? clipboardCandidate() : nil)
        ensureOnScreen(p)
        p.makeKeyAndOrderFront(nil)
        state.focusToken += 1
    }

    func hide() { panel?.orderOut(nil) }

    private static let frameName = "AcronomeQuickPanel"
    private static let defaultSize = NSSize(width: 720, height: 488)

    func resetFrame() {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(Self.frameName)")
        guard let p = panel else { return }
        p.setContentSize(NSSize(width: 720, height: 460))
        position(p)
        p.saveFrame(usingName: Self.frameName)
    }

    /// Use the remembered frame; fall back to the default spot when there is none or it's off every screen.
    private func ensureOnScreen(_ p: NSPanel) {
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName)") != nil
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(p.frame.insetBy(dx: 40, dy: 40)) }
        if !saved || !visible { position(p) }
    }

    func explainSelected() {
        if let e = state.selected {
            app.claude.explain(e)
        } else if !state.trimmed.isEmpty {
            app.claude.lookup(state.trimmed)
        }
    }

    private func copyAndClose(_ e: Entry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(e.long, forType: .string)
        lastChangeCount = pb.changeCount
        app.store.pushRecent(e.abbr)
        state.flash = "Copied"
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.hide()
        }
    }

    private func openMain(_ section: AppSection?, _ query: String?) {
        hide()
        if !state.trimmed.isEmpty, !state.results.isEmpty { app.store.pushRecent(state.trimmed) }
        app.showMain(section: section, query: query)
    }

    private func makePanel() -> QuickPanel {
        let p = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                           styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                           backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for b in buttons { p.standardWindowButton(b)?.isHidden = true }
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.minSize = NSSize(width: 460, height: 240)

        let actions = QuickActions(
            copyAndClose: { [weak self] e in self?.copyAndClose(e) },
            openMain: { [weak self] s, q in self?.openMain(s, q) },
            close: { [weak self] in self?.hide() })
        let root = QuickView(state: state, actions: actions)
            .environmentObject(app.library)
            .environmentObject(app.store)
            .environmentObject(app.claude)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        p.contentView = host
        p.setFrameAutosaveName(Self.frameName)
        p.onCommandReturn = { [weak self] in
            guard let self else { return }
            self.openMain(.lookup, self.state.trimmed)
        }
        p.onOpenApp = { [weak self] in self?.openMain(nil, nil) }
        p.onExplain = { [weak self] in self?.explainSelected() }
        return p
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { p.center(); return }
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - vf.height * 0.2 - size.height))
    }

    private var lastChangeCount = -1

    /// A short, single-line clipboard string that was copied since we last used it.
    private func clipboardCandidate() -> String? {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount,
              let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, s.count <= 30, !s.contains("\n"), s.split(separator: " ").count <= 3
        else { return nil }
        lastChangeCount = pb.changeCount
        return s
    }
}

struct QuickActions {
    var copyAndClose: @MainActor (Entry) -> Void
    var openMain: @MainActor (AppSection?, String?) -> Void
    var close: @MainActor () -> Void
}

// MARK: - Query field (AppKit, for precise focus and arrow-key handling)

@MainActor
struct QueryField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var placeholder: String
    var onMove: @MainActor (Int) -> Void
    var onSubmit: @MainActor () -> Void
    var onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 24, weight: .regular)
        f.placeholderString = placeholder
        f.cell?.usesSingleLineMode = true
        f.cell?.lineBreakMode = .byTruncatingTail
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        if context.coordinator.lastToken != focusToken {
            context.coordinator.lastToken = focusToken
            Task { @MainActor in
                f.window?.makeFirstResponder(f)
                f.currentEditor()?.selectAll(nil)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QueryField
        var lastToken = -1

        init(_ parent: QueryField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

// MARK: - Panel content

@MainActor
struct QuickView: View {
    @ObservedObject var state: QuickState
    let actions: QuickActions
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var store: UserStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                QueryField(text: $state.query, focusToken: state.focusToken, placeholder: "Abbreviation",
                           onMove: { state.move($0) },
                           onSubmit: { if let e = state.selected { actions.copyAndClose(e) } },
                           onCancel: { actions.close() })
                if !state.query.isEmpty {
                    Button {
                        state.query = ""
                        state.focusToken += 1
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear")
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .layoutPriority(2)

            Divider()
            // Only the middle shrinks or grows with the panel; search bar and footer keep their height.
            content
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
            Divider()
            footer.layoutPriority(2)
        }
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        .ignoresSafeArea()   // no empty title-bar strip above the search field
        .background { PanelBackground() }
    }

    @ViewBuilder private var content: some View {
        if !library.isLoaded {
            ProgressView("Loading abbreviations…").controlSize(.small)
        } else if state.trimmed.isEmpty {
            emptyHint
        } else if state.results.isEmpty {
            noMatch
        } else {
            GeometryReader { geo in
            HStack(spacing: 0) {
                resultList.frame(width: min(320, max(190, geo.size.width * 0.4)))
                Divider()
                if let e = state.selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            EntryDetail(entry: e, compact: true)
                            ExplanationView(entry: e)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Spacer()
                }
            }
            }
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(state.results.indices, id: \.self) { i in
                        ResultRow(entry: state.results[i], selected: i == state.selection)
                            .id(i)
                            .onTapGesture(count: 2) { actions.copyAndClose(state.results[i]) }
                            .onTapGesture { state.selection = i }
                    }
                }
                .padding(8)
            }
            .onChange(of: state.selection) { proxy.scrollTo(state.selection) }
        }
    }

    private var emptyHint: some View {
        ViewThatFits(in: .vertical) {
            fullHint
            Text("Type or paste an abbreviation").foregroundStyle(.secondary)
            Color.clear
        }
    }

    private var fullHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Type or paste an abbreviation").font(.title3.weight(.medium))
            Text("Case, hyphens and Greek letters don’t matter.")
                .foregroundStyle(.secondary)
            if !store.recent.isEmpty {
                HStack {
                    ForEach(store.recent.prefix(6), id: \.self) { r in
                        Button(r) { state.query = r }
                            .font(.system(.callout, design: .monospaced))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 6)
            }
        }
    }

    private var noMatch: some View {
        ScrollView {
        VStack(spacing: 12) {
            Text("No match for “\(state.trimmed)”").font(.title3.weight(.medium))
            if !state.suggestions.isEmpty {
                Text("Did you mean:").foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 6) {
                    ForEach(state.suggestions, id: \.self) { s in
                        Button(s) { state.query = s }
                            .font(.system(.callout, design: .monospaced))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: 520)
            }
            AskClaudeView(abbr: state.trimmed)
                .padding(.vertical, 4)
            HStack {
                Button("Search as a Full Term") { actions.openMain(.reverse, state.trimmed) }
                Button("Add to My Entries…") {
                    AppModel.shared.newEntryAbbr = state.trimmed
                    actions.openMain(.mine, nil)
                }
            }
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if let flash = state.flash {
                Label(flash, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary).fixedSize()
            } else if !state.results.isEmpty {
                let n = state.results.count
                Text(n == 1 ? "1 meaning" : "\(n) meanings").foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 8)
            // Key hints give way first when the panel gets narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    KeyHint(keys: "↩", label: "Copy")
                    KeyHint(keys: "⌘E", label: "Ask Claude")
                    KeyHint(keys: "⌘↩", label: "Show in Acronome")
                }
                HStack(spacing: 16) {
                    KeyHint(keys: "↩", label: "Copy")
                    KeyHint(keys: "⌘E", label: "Ask Claude")
                }
                KeyHint(keys: "↩", label: "Copy")
                Color.clear.frame(width: 0, height: 0)
            }
            Button("Open Acronome") { actions.openMain(nil, nil) }
                .controlSize(.small)
                .fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

private struct ResultRow: View {
    let entry: Entry
    let selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.abbr)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(width: 82, alignment: .leading)
            Text(entry.long)
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
        }
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}

/// Liquid Glass on macOS 26+, the system popover material before that.
private struct PanelBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 0))
                .ignoresSafeArea()
        } else {
            VisualEffectBackground(material: .popover).ignoresSafeArea()
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
