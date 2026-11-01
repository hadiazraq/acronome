import Carbon.HIToolbox
import Foundation

struct HotKeyPreset: Identifiable {
    let id: Int
    let label: String
    let keyCode: UInt32
    let modifiers: UInt32

    static let all: [HotKeyPreset] = [
        HotKeyPreset(id: 0, label: "⌃⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(id: 1, label: "⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
        HotKeyPreset(id: 2, label: "⌥⌘B", keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | cmdKey)),
        HotKeyPreset(id: 3, label: "⌃⌥B", keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(id: 4, label: "⌃⌥⌘A", keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey | cmdKey)),
    ]

    static var current: HotKeyPreset {
        let i = UserDefaults.standard.integer(forKey: "hotKeyPreset")
        return all.first { $0.id == i } ?? all[0]
    }
}

/// System-wide shortcut through Carbon's RegisterEventHotKey: no Accessibility permission needed.
final class HotKeyCenter {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate var action: (@MainActor () -> Void)?

    func register(_ preset: HotKeyPreset, action: @escaping @MainActor () -> Void) -> Bool {
        self.action = action
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_: EventHandlerCallRef?, _: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus in
                    guard let userData else { return OSStatus(eventNotHandledErr) }
                    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in center.action?() }
                    return OSStatus(noErr)
                },
                1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            if status != OSStatus(noErr) { return false }
        }
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4143_524E), id: 1)   // 'ACRN'
        let status = RegisterEventHotKey(preset.keyCode, preset.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == OSStatus(noErr)
    }
}
