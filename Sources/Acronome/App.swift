import AppKit
import Combine
import ServiceManagement
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case lookup, reverse, expand, cards, mine, nomenclature, sources
    var id: String { rawValue }

    var title: String {
        switch self {
        case .lookup: return "Look Up"
        case .reverse: return "Find Abbreviation"
        case .expand: return "Expand Text"
        case .cards: return "Flashcards"
        case .mine: return "My Entries"
        case .nomenclature: return "Gene Nomenclature"
        case .sources: return "Sources"
        }
    }

    var symbol: String {
        switch self {
        case .lookup: return "magnifyingglass"
        case .reverse: return "text.magnifyingglass"
        case .expand: return "doc.text.magnifyingglass"
        case .cards: return "rectangle.on.rectangle.angled"
        case .mine: return "square.and.pencil"
        case .nomenclature: return "textformat"
        case .sources: return "info.circle"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let library = Library()
    let store = UserStore()
    private let hotKeys = HotKeyCenter()
    private(set) lazy var claude = ClaudeService(store: store)
    private(set) lazy var quick = QuickPanelController(app: self)

    @Published var section: AppSection = .lookup
    @Published var lookupQuery = ""
    @Published var reverseQuery = ""
    @Published var newEntryAbbr: String?
    @Published var hotKeyError: String?

    private var mainWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    private init() {
        store.$mine.sink { [weak self] m in self?.library.setMine(m) }.store(in: &bag)
        library.$revision.dropFirst().sink { [weak self] _ in self?.quick.state.recompute() }.store(in: &bag)
        library.load()
    }

    func registerHotKey() {
        let preset = HotKeyPreset.current
        let ok = hotKeys.register(preset) { [weak self] in self?.quick.toggle() }
        hotKeyError = ok ? nil : "\(preset.label) is already used by another app. Choose a different shortcut."
    }

    func showMain(section: AppSection? = nil, query: String? = nil) {
        if let section { self.section = section }
        if let query {
            if self.section == .reverse { reverseQuery = query } else { lookupQuery = query }
        }
        if mainWindow == nil {
            let root = MainView()
                .environmentObject(self)
                .environmentObject(library)
                .environmentObject(store)
                .environmentObject(claude)
            let controller = NSHostingController(rootView: root)
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.title = "Acronome"
            window.setContentSize(NSSize(width: 1040, height: 700))
            window.minSize = NSSize(width: 760, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("AcronomeMainWindow")
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "prefillClipboard": true, "showMenuBar": true, "openWindowAtLaunch": true, "hotKeyPreset": 0,
        ])
        let model = AppModel.shared
        model.registerHotKey()
        if UserDefaults.standard.bool(forKey: "openWindowAtLaunch") { model.showMain() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showMain()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AcronomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        MenuBarExtra("Acronome", systemImage: "character.book.closed", isInserted: $showMenuBar) {
            MenuBarContent()
        }
        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
                .environmentObject(AppModel.shared.claude)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Acronome Window") { AppModel.shared.showMain() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Quick Look Up") { AppModel.shared.quick.show() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
struct MenuBarContent: View {
    var body: some View {
        Button("Quick Look Up (\(HotKeyPreset.current.label))") { AppModel.shared.quick.show() }
        Button("Open Acronome") { AppModel.shared.showMain() }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit Acronome") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hotKeyPreset") private var preset = 0
    @AppStorage("prefillClipboard") private var prefill = true
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("openWindowAtLaunch") private var openAtLaunch = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Keyboard shortcut", selection: $preset) {
                    ForEach(HotKeyPreset.all) { Text($0.label).tag($0.id) }
                }
                .onChange(of: preset) { model.registerHotKey() }
                if let err = model.hotKeyError {
                    Text(err).font(.callout).foregroundStyle(.red)
                }
                Toggle("Look up the clipboard automatically", isOn: $prefill)
                Button("Reset Panel Size and Position") { model.quick.resetFrame() }
            } header: {
                Text("Quick Look Up")
            } footer: {
                Text("When you’ve just copied a short abbreviation, the panel opens with it already looked up. Drag the panel’s edges to resize it; its size and position are remembered.")
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLogin(launchAtLogin) }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
                Toggle("Show in menu bar", isOn: $showMenuBar)
                Toggle("Open the main window at launch", isOn: $openAtLaunch)
            }
            ClaudeSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn’t change this: \(error.localizedDescription)"
        }
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }
}
