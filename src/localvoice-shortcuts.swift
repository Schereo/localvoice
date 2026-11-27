import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import OSLog

// Global shortcuts, owned by the app rather than the Python service.
//
// The service used to watch the keyboard itself through pynput, which can only
// observe: Esc and Enter pressed to end a recording also reached the frontmost
// app (Enter sent the half-written Slack message). The app now detects the
// shortcuts and sends commands to the service over its stdin, a Unix socket
// pair (see docs/how-it-works.md):
//
//   * a modifier-tap gesture (Control three times) comes from a listen-only
//     CGEventTap on a thread of its own, so a busy main thread never delays or
//     disables it;
//   * a key combination (⌥Space) is a Carbon hotkey: macOS delivers it to us
//     instead of the frontmost app, and reports when another app holds it;
//   * Insert and Discard (Enter and Esc by default) are Carbon hotkeys
//     registered only while a recording runs, so they are swallowed then and
//     untouched the rest of the time.
//
// If the tap cannot be created, the service is started without the channel
// and falls back to its own pynput listener.

private let shortcutLog = Logger(subsystem: "com.localvoice.app", category: "shortcuts")

// MARK: - Model

/// `<modifier>,<taps>`: a repeated tap on one modifier key (`hotkey = ctrl,3`).
struct ModifierTapHotkey: Hashable, Sendable {
    enum Modifier: String, CaseIterable, Sendable {
        case ctrl, cmd, alt, shift

        /// Left and right key codes (kVK_Control, kVK_RightControl, …).
        var keyCodes: [Int64] {
            switch self {
            case .ctrl: [59, 62]
            case .cmd: [55, 54]
            case .alt: [58, 61]
            case .shift: [56, 60]
            }
        }

        var modifiers: KeyModifiers {
            switch self {
            case .ctrl: .control
            case .cmd: .command
            case .alt: .option
            case .shift: .shift
            }
        }
    }

    var modifier: Modifier
    var taps: Int

    static let standard = ModifierTapHotkey(modifier: .ctrl, taps: 3)

    init(modifier: Modifier, taps: Int) {
        self.modifier = modifier
        self.taps = taps
    }

    /// Parses the config value the way the service does (utils/localvoice_config.py).
    init?(config raw: String?) {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let comma = text.firstIndex(of: ","),
              let modifier = Modifier(rawValue: String(text[..<comma])),
              let taps = Int(text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces)),
              (2...4).contains(taps) else { return nil }
        self.init(modifier: modifier, taps: taps)
    }

    var configValue: String { "\(modifier.rawValue),\(taps)" }
}

/// The four modifiers a key combination can hold, in macOS display order.
struct KeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let control = KeyModifiers(rawValue: 1)
    static let option = KeyModifiers(rawValue: 2)
    static let shift = KeyModifiers(rawValue: 4)
    static let command = KeyModifiers(rawValue: 8)

    /// (modifier, config name, glyph, spoken name, SF Symbol), in display order.
    static let all: [(KeyModifiers, String, String, String, String)] = [
        (.control, "ctrl", "⌃", "Control", "control"),
        (.option, "alt", "⌥", "Option", "option"),
        (.shift, "shift", "⇧", "Shift", "shift"),
        (.command, "cmd", "⌘", "Command", "command"),
    ]
    /// Accepted spellings in the config file.
    static let configNames: [String: KeyModifiers] = [
        "ctrl": .control, "control": .control, "alt": .option, "opt": .option, "option": .option,
        "shift": .shift, "cmd": .command, "command": .command,
    ]

    init(rawValue: Int) { self.rawValue = rawValue }

    init(cgFlags flags: CGEventFlags) {
        var value: KeyModifiers = []
        if flags.contains(.maskControl) { value.insert(.control) }
        if flags.contains(.maskAlternate) { value.insert(.option) }
        if flags.contains(.maskShift) { value.insert(.shift) }
        if flags.contains(.maskCommand) { value.insert(.command) }
        self = value
    }

    init(eventFlags flags: NSEvent.ModifierFlags) {
        var value: KeyModifiers = []
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        self = value
    }

    /// For RegisterEventHotKey.
    var carbon: Int {
        var value = 0
        if contains(.control) { value |= controlKey }
        if contains(.option) { value |= optionKey }
        if contains(.shift) { value |= shiftKey }
        if contains(.command) { value |= cmdKey }
        return value
    }

    var glyphs: String { Self.all.filter { contains($0.0) }.map(\.2).joined() }
    var count: Int { Self.all.filter { contains($0.0) }.count }
}

/// Key names for the config file. Character keys are named by their position on a
/// US keyboard: the key code is what is stored, and Settings shows the key in the
/// active layout (on a German keyboard `cmd+y` is shown as ⌘Z).
enum KeyNames {
    private static let table: [(String, Int64)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
        ("section", 10), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17),
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("equal", 24), ("9", 25),
        ("7", 26), ("minus", 27), ("8", 28), ("0", 29), ("bracketright", 30), ("o", 31), ("u", 32),
        ("bracketleft", 33), ("i", 34), ("p", 35), ("return", 36), ("l", 37), ("j", 38), ("quote", 39),
        ("k", 40), ("semicolon", 41), ("backslash", 42), ("comma", 43), ("slash", 44), ("n", 45),
        ("m", 46), ("period", 47), ("tab", 48), ("space", 49), ("grave", 50), ("delete", 51),
        ("escape", 53), ("enter", 76), ("f17", 64), ("f18", 79), ("f19", 80), ("f20", 90), ("f5", 96),
        ("f6", 97), ("f7", 98), ("f3", 99), ("f8", 100), ("f9", 101), ("f11", 103), ("f13", 105),
        ("f16", 106), ("f14", 107), ("f10", 109), ("f12", 111), ("f15", 113), ("help", 114),
        ("home", 115), ("pageup", 116), ("forwarddelete", 117), ("f4", 118), ("end", 119), ("f2", 120),
        ("pagedown", 121), ("f1", 122), ("left", 123), ("right", 124), ("down", 125), ("up", 126),
    ]
    private static let aliases: [String: Int64] = [
        "esc": 53, "ret": 36, "backspace": 51, "spacebar": 49, "=": 24, "-": 27, "]": 30, "[": 33,
        "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50,
    ]
    private static let codes = Dictionary(table.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
    private static let names = Dictionary(table.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })

    static let functionKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107,
                                           113, 106, 64, 79, 80, 90]

    /// A key name, a US-layout character, or `#<key code>`.
    static func keyCode(_ name: String) -> Int64? {
        let name = name.lowercased()
        if name.hasPrefix("#"), let code = Int64(name.dropFirst()), (0..<128).contains(code) { return code }
        return codes[name] ?? aliases[name]
    }

    static func name(_ keyCode: Int64) -> String { names[keyCode] ?? "#\(keyCode)" }

    /// Keys that mean the same on every layout: label and SF Symbol (when one reads better).
    static let special: [Int64: (label: String, symbol: String?)] = [
        36: ("Return", "return"), 48: ("Tab", "arrow.right.to.line"), 49: ("Space", "space"),
        51: ("Delete", "delete.left"), 53: ("esc", nil), 76: ("Enter", "return"),
        114: ("Help", nil), 115: ("Home", "arrow.up.left"), 116: ("Page Up", "arrow.up.to.line"),
        117: ("Forward Delete", "delete.right"), 119: ("End", "arrow.down.right"),
        121: ("Page Down", "arrow.down.to.line"), 123: ("Left Arrow", "arrow.left"),
        124: ("Right Arrow", "arrow.right"), 125: ("Down Arrow", "arrow.down"), 126: ("Up Arrow", "arrow.up"),
    ]
}

/// One key as drawn: an SF Symbol where one reads better than text, and a small R
/// badge for a right-side modifier.
struct Keycap: Equatable, Sendable {
    var text: String
    var symbol: String?
    var rightSide = false
}

struct KeyCombo: Hashable, Sendable {
    var keyCode: Int64
    var modifiers: KeyModifiers

    static let returnKey = KeyCombo(keyCode: 36, modifiers: [])
    static let escape = KeyCombo(keyCode: 53, modifiers: [])
}

/// What starts dictation: a key combination, two or more modifiers pressed together
/// and released, or a modifier-tap gesture.
enum Shortcut: Hashable, Sendable {
    case combo(KeyCombo)
    case chord(KeyModifiers)
    case taps(ModifierTapHotkey)

    /// `ctrl,3` (tap gesture), `ctrl+cmd` (modifiers alone) or `alt+space`,
    /// `shift+cmd+d` (key combination).
    init?(config raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let taps = ModifierTapHotkey(config: raw) {
            self = .taps(taps)
            return
        }
        // A comma only appears as the key itself ("cmd+,"); otherwise it is a malformed gesture.
        guard !raw.contains(",") || raw.hasSuffix("+,") || raw == "," else { return nil }
        var parts = raw.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let last = parts.last, !last.isEmpty else { return nil }
        if parts.count >= 2, parts.allSatisfy({ KeyModifiers.configNames[$0] != nil }) {
            let modifiers = parts.reduce(into: KeyModifiers()) { $0.insert(KeyModifiers.configNames[$1]!) }
            guard modifiers.count >= 2 else { return nil }
            self = .chord(modifiers)
            return
        }
        parts.removeLast()
        guard let keyCode = KeyNames.keyCode(last) else { return nil }
        var modifiers: KeyModifiers = []
        for part in parts {
            guard let modifier = KeyModifiers.configNames[part] else { return nil }
            modifiers.insert(modifier)
        }
        self = .combo(KeyCombo(keyCode: keyCode, modifiers: modifiers))
    }

    var configValue: String {
        switch self {
        case let .taps(taps): taps.configValue
        case let .combo(combo):
            (KeyModifiers.all.filter { combo.modifiers.contains($0.0) }.map(\.1) + [KeyNames.name(combo.keyCode)])
                .joined(separator: "+")
        case let .chord(modifiers):
            KeyModifiers.all.filter { modifiers.contains($0.0) }.map(\.1).joined(separator: "+")
        }
    }

    var combo: KeyCombo? {
        if case let .combo(combo) = self { return combo }
        return nil
    }
}

// MARK: - Display

/// Characters for key codes in the active keyboard layout (UCKeyTranslate). Main thread only.
@MainActor
enum KeyboardLayout {
    static func character(for keyCode: Int64) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return text.isEmpty ? nil : text.uppercased()
        }
    }

    static func label(for keyCode: Int64) -> (label: String, symbol: String?) {
        if let special = KeyNames.special[keyCode] { return special }
        if KeyNames.functionKeys.contains(keyCode) { return (KeyNames.name(keyCode).uppercased(), nil) }
        return (character(for: keyCode) ?? KeyNames.name(keyCode).uppercased(), nil)
    }
}

extension Shortcut {
    @MainActor
    var keycaps: [Keycap] {
        switch self {
        case let .taps(taps):
            let modifier = KeyModifiers.all.first { $0.0 == taps.modifier.modifiers }!
            return Array(repeating: Keycap(text: modifier.2, symbol: modifier.4), count: taps.taps)
        case let .combo(combo):
            let key = KeyboardLayout.label(for: combo.keyCode)
            return KeyModifiers.all.filter { combo.modifiers.contains($0.0) }.map { Keycap(text: $0.2, symbol: $0.4) }
                + [Keycap(text: key.label, symbol: key.symbol)]
        case let .chord(modifiers):
            return KeyModifiers.all.filter { modifiers.contains($0.0) }.map { Keycap(text: $0.2, symbol: $0.4) }
        }
    }

    /// Short text form: "⌥Space", "⌃ ×3".
    @MainActor
    var displayName: String {
        switch self {
        case let .taps(taps):
            "\(KeyModifiers.all.first { $0.0 == taps.modifier.modifiers }!.2) ×\(taps.taps)"
        case let .combo(combo):
            combo.modifiers.glyphs + KeyboardLayout.label(for: combo.keyCode).label
        case let .chord(modifiers):
            modifiers.glyphs
        }
    }

    /// For sentences and VoiceOver: "Control three times", "Option-Space".
    @MainActor
    var spokenName: String {
        switch self {
        case let .taps(taps):
            let counts = [2: "twice", 3: "three times", 4: "four times"]
            return "\(KeyModifiers.all.first { $0.0 == taps.modifier.modifiers }!.3) \(counts[taps.taps] ?? "")"
        case let .combo(combo):
            return (KeyModifiers.all.filter { combo.modifiers.contains($0.0) }.map(\.3)
                + [KeyboardLayout.label(for: combo.keyCode).label]).joined(separator: "-")
        case let .chord(modifiers):
            return KeyModifiers.all.filter { modifiers.contains($0.0) }.map(\.3).joined(separator: "-")
        }
    }

    /// "tap Control three times", "press Option-Space".
    @MainActor
    var instruction: String {
        switch self {
        case .taps: "tap \(spokenName)"
        case .combo, .chord: "press \(spokenName)"
        }
    }
}

// MARK: - The dictation shortcut

/// The one configurable shortcut: start and stop dictation (`dictate = …`).
/// Return and Esc during a recording are fixed.
enum DictationShortcut {
    static let configKey = "dictate"
    static let standard = Shortcut.taps(.standard)

    /// The configured shortcut, or the default. Falls back to the pre-1.5
    /// `hotkey` key, which is a tap gesture.
    static func current(_ read: (String) -> String? = readConfigValue) -> Shortcut {
        if let shortcut = Shortcut(config: read(configKey)) { return shortcut }
        if let taps = ModifierTapHotkey(config: read("hotkey")) { return .taps(taps) }
        return standard
    }

    /// Why `shortcut` cannot start dictation, or nil.
    static func problem(with shortcut: Shortcut) -> String? {
        if let combo = shortcut.combo, !KeyNames.functionKeys.contains(combo.keyCode),
           combo.modifiers.isDisjoint(with: [.control, .option, .command]) {
            // A plain or Shift-only key would fire while typing.
            return "Add a modifier, like ⌘, ⌥ or ⌃."
        }
        if let combo = shortcut.combo, combo.modifiers.isEmpty,
           [KeyCombo.returnKey.keyCode, KeyCombo.escape.keyCode].contains(combo.keyCode) {
            return "Return and Esc end a recording; pick another key."
        }
        return nil
    }
}

extension Notification.Name {
    /// A shortcut recorder opened (`object` true) or closed (false): global shortcuts pause meanwhile.
    static let localVoiceShortcutRecording = Notification.Name("LocalVoiceShortcutRecording")
    /// The shortcut was saved; apply it now instead of on the next config poll.
    static let localVoiceShortcutsChanged = Notification.Name("LocalVoiceShortcutsChanged")
}

// MARK: - Event tap

/// Device-dependent modifier bits (NX_DEVICELCTLKEYMASK …) by key code: whether a
/// flagsChanged event for that key is its press or its release.
private let modifierKeyMasks: [Int64: UInt64] = [
    59: 0x0000_0001, 62: 0x0000_2000,  // Control
    56: 0x0000_0002, 60: 0x0000_0004,  // Shift
    55: 0x0000_0008, 54: 0x0000_0010,  // Command
    58: 0x0000_0020, 61: 0x0000_0040,  // Option
]

enum ShortcutKey {
    static let escape: Int64 = 53
}

/// What the tap hands to the main thread. Only keys a shortcut uses leave the tap
/// thread; ordinary typing is never forwarded.
enum TapEvent: Sendable {
    case gesture
    case keyDown(keyCode: Int64, flags: UInt64)
}

/// Repeated-tap detection, the same rules the pynput listener applied: presses of
/// the configured modifier at most 0.5 s apart count up, and any other key press
/// (another modifier too) starts over. Releases do not count.
struct ModifierTapCounter {
    var hotkey: ModifierTapHotkey
    var timeout: TimeInterval = 0.5
    private var count = 0
    private var last: TimeInterval = -.infinity

    init(hotkey: ModifierTapHotkey) { self.hotkey = hotkey }

    /// Feeds a modifier key going down (`isTapKey`: one of the configured
    /// modifier's keys) or any other key going down; true when the gesture completes.
    mutating func press(isTapKey: Bool, at time: TimeInterval) -> Bool {
        guard isTapKey else {
            count = 0
            return false
        }
        count = time - last > timeout ? 1 : count + 1
        last = time
        if count == hotkey.taps {
            count = 0
            return true
        }
        return false
    }

    mutating func reset() { count = 0 }
}

/// Two or more modifiers pressed together and released with nothing else in
/// between. It fires on release, so ⌃⌘Q (lock screen) or ⌃⌘-click never starts
/// dictation: any key or click while they are held voids it.
struct ModifierChordDetector {
    var chord: KeyModifiers
    private var peak: KeyModifiers = []
    private var voided = false

    init(chord: KeyModifiers) { self.chord = chord }

    /// The modifiers now held; true when they were all released and the chord completes.
    mutating func modifiersChanged(to held: KeyModifiers) -> Bool {
        guard held.isEmpty else {
            peak.formUnion(held)
            return false
        }
        defer {
            peak = []
            voided = false
        }
        return !voided && peak == chord
    }

    /// A key, a click, caps lock or fn while modifiers are held.
    mutating func otherInput() {
        if !peak.isEmpty { voided = true }
    }

    mutating func reset() {
        peak = []
        voided = false
    }
}

final class KeyboardTap: @unchecked Sendable {
    /// What the tap looks for: the tap gesture (nil while dictation uses a key
    /// combination) and the key codes to forward.
    struct Watch: Sendable {
        var gesture: ModifierTapHotkey?
        var chord: KeyModifiers?
        var keys: Set<Int64>
    }

    // Written on the main thread, read on the tap thread.
    private let lock = NSLock()
    private var pendingWatch: Watch?
    // Tap thread only.
    private var counter = ModifierTapCounter(hotkey: .standard)
    private var gestureEnabled = false
    private var chord: ModifierChordDetector?
    private var keys: Set<Int64> = []
    private var port: CFMachPort?
    private let deliver: @Sendable (TapEvent) -> Void

    init(watch: Watch, deliver: @escaping @Sendable (TapEvent) -> Void) {
        self.deliver = deliver
        pendingWatch = watch
    }

    func setWatch(_ watch: Watch) {
        lock.lock()
        pendingWatch = watch
        lock.unlock()
    }

    /// Creates the tap (needs Input Monitoring) and runs it on its own thread.
    func start() -> Bool {
        if port != nil { return true }
        // Mouse buttons only void a modifier chord (⌃⌘-click is not dictation).
        let mask = [CGEventType.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // The tap lives as long as the app; this reference is never released
        // once it is installed.
        let context = Unmanaged.passRetained(self)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                if let info {
                    Unmanaged<KeyboardTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context.toOpaque()
        ) else {
            shortcutLog.error("Could not create the keyboard event tap (Input Monitoring missing?)")
            context.release()
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            context.release()
            return false
        }
        self.port = port
        let box = RunLoopSourceBox(source: source, port: port)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), box.source, .commonModes)
            CGEvent.tapEnable(tap: box.port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "LocalVoice keyboard tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off after a slow callback or secure input; turn it back on.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            counter.reset()
            chord?.reset()
            return
        default:
            break
        }
        lock.lock()
        if let watch = pendingWatch {
            pendingWatch = nil
            gestureEnabled = watch.gesture != nil
            if let gesture = watch.gesture { counter.hotkey = gesture }
            counter.reset()
            chord = watch.chord.map(ModifierChordDetector.init(chord:))
            keys = watch.keys
        }
        lock.unlock()

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            chord?.otherInput()
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime
        if type == .flagsChanged {
            if modifierKeyMasks[keyCode] != nil {
                if chord?.modifiersChanged(to: KeyModifiers(cgFlags: event.flags)) == true { deliver(.gesture) }
            } else {
                chord?.otherInput()
            }
            // A modifier going up is not a press; caps lock, fn and unknown keys always count as one.
            if let mask = modifierKeyMasks[keyCode], event.flags.rawValue & mask == 0 { return }
            if keyCode == 63, !event.flags.contains(.maskSecondaryFn) { return }
            if counter.press(isTapKey: counter.hotkey.modifier.keyCodes.contains(keyCode), at: now),
               gestureEnabled {
                deliver(.gesture)
            }
        } else if type == .keyDown {
            _ = counter.press(isTapKey: false, at: now)
            chord?.otherInput()
            if keys.contains(keyCode) {
                deliver(.keyDown(keyCode: keyCode, flags: event.flags.rawValue))
            }
        }
    }
}

private struct RunLoopSourceBox: @unchecked Sendable {
    let source: CFRunLoopSource
    let port: CFMachPort
}

// MARK: - Carbon hotkeys

/// RegisterEventHotKey: the system delivers the key to us instead of the
/// frontmost app. Needs no permission.
@MainActor
final class CarbonHotkeys {
    static let shared = CarbonHotkeys()
    private static let signature: OSType = 0x4C56_686B  // 'LVhk'
    private var handler: EventHandlerRef?
    private var registered: [UInt32: (ref: EventHotKeyRef, action: @MainActor () -> Void)] = [:]

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            // Carbon dispatches hotkeys on the main thread's event loop.
            MainActor.assumeIsolated { CarbonHotkeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handler)
        return status == noErr
    }

    /// False if the key is taken (eventHotKeyExistsErr) or cannot be registered.
    /// Exclusive, so an app that registers the key after us does not get it too.
    func register(_ id: UInt32, keyCode: Int64, modifiers: Int, action: @escaping @MainActor () -> Void) -> Bool {
        unregister(id)
        guard installHandler() else { return false }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            shortcutLog.error("Could not register hotkey \(id) (key \(keyCode)): \(status)")
            return false
        }
        registered[id] = (ref, action)
        return true
    }

    func unregister(_ id: UInt32) {
        if let entry = registered.removeValue(forKey: id) {
            UnregisterEventHotKey(entry.ref)
        }
    }

    private func fire(_ id: EventHotKeyID) {
        guard id.signature == Self.signature else { return }
        registered[id.id]?.action()
    }
}

// MARK: - Channel to the service

/// The app's end of the service's stdin: a Unix socket pair carrying one command
/// per line each way. While the app holds it the service keeps running; when the
/// app quits or crashes the kernel closes it and the service reads EOF.
@MainActor
final class ServiceChannel {
    /// Pass as the child's standardInput; closed in the app once the child runs.
    let childEnd: FileHandle
    private let descriptor: Int32
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var onLine: ((String) -> Void)?
    private var onClose: (() -> Void)?

    init?(onLine: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var on: Int32 = 1
        // A write to a dead child must fail, not kill the app with SIGPIPE.
        _ = setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Never block the main thread on a service that stopped reading.
        _ = fcntl(pair[0], F_SETFL, fcntl(pair[0], F_GETFL) | O_NONBLOCK)
        descriptor = pair[0]
        childEnd = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        self.onLine = onLine
        self.onClose = onClose
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        source.setCancelHandler { [descriptor] in _ = Darwin.close(descriptor) }
        self.source = source
        source.resume()
    }

    /// The child holds its own copy now; drop ours so its exit reads as EOF here.
    func childStarted() {
        try? childEnd.close()
    }

    func send(_ command: String) {
        guard source != nil else { return }
        let line = Array((command + "\n").utf8)
        let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        if written != line.count {
            shortcutLog.error("Could not send '\(command, privacy: .public)' to the service")
        }
    }

    func close() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        try? childEnd.close()
        onLine = nil
        let closed = onClose
        onClose = nil
        closed?()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[..<count])
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { break }
            // EOF or a hard error: the service is gone.
            deliverLines()
            close()
            return
        }
        deliverLines()
    }

    private func deliverLines() {
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            onLine?(line.trimmingCharacters(in: .whitespaces))
        }
    }
}

// MARK: - Controller

/// Owns the shortcuts and turns them into service commands.
@MainActor
final class ShortcutController {
    private enum HotkeyID: UInt32 {
        case discard = 1, finish, dictate = 10

        var command: String {
            switch self {
            case .discard: "discard"
            case .finish: "finish"
            case .dictate: "toggle"
            }
        }
    }

    private var dictate: Shortcut
    // Fixed: during a recording, Return inserts and Esc discards.
    private let insert = KeyCombo.returnKey
    private let discard = KeyCombo.escape
    private lazy var tap = KeyboardTap(watch: watch) { [weak self] event in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }
    private var channel: ServiceChannel?
    private var serviceReady = false
    private var recording = false
    // A shortcut recorder is open: its keys must reach it, not start dictation.
    private var paused = false
    // Combinations that could not be registered (another app holds them); the tap
    // still sees those keys and they work as before, unswallowed.
    private var unswallowed: [KeyCombo: HotkeyID] = [:]

    init() {
        dictate = DictationShortcut.current()
        let center = NotificationCenter.default
        center.addObserver(forName: .localVoiceShortcutRecording, object: nil, queue: .main) { [weak self] note in
            let active = note.object as? Bool ?? false
            MainActor.assumeIsolated { self?.setPaused(active) }
        }
        center.addObserver(forName: .localVoiceShortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadConfig() }
        }
        registerDictate()
    }

    /// A channel for a service about to start, or nil if the app cannot watch
    /// the keyboard; the service then runs its own listener.
    func connectService() -> ServiceChannel? {
        disconnectService()
        guard tap.start() else { return nil }
        var opened: ServiceChannel?
        opened = ServiceChannel(
            onLine: { [weak self] line in self?.serviceSaid(line) },
            onClose: { [weak self] in
                guard let self, self.channel === opened else { return }
                self.channel = nil
                self.serviceReady = false
                self.setRecording(false)
            }
        )
        channel = opened
        return opened
    }

    func disconnectService() {
        channel?.close()
    }

    /// Follows edits of the shortcut in the config file.
    func reloadConfig() {
        let current = DictationShortcut.current()
        guard current != dictate else { return }
        dictate = current
        registerDictate()
        tap.setWatch(watch)
    }

    /// The tap's view: the gesture or modifier chord dictation uses, and the keys it
    /// may have to stand in for when their Carbon hotkey could not be registered.
    private var watch: KeyboardTap.Watch {
        var keys: Set<Int64> = [ShortcutKey.escape, insert.keyCode, discard.keyCode]  // Esc also for Option+Esc
        switch dictate {
        case let .taps(taps): return .init(gesture: taps, chord: nil, keys: keys)
        case let .chord(modifiers): return .init(gesture: nil, chord: modifiers, keys: keys)
        case let .combo(combo):
            keys.insert(combo.keyCode)
            return .init(gesture: nil, chord: nil, keys: keys)
        }
    }

    private func serviceSaid(_ line: String) {
        switch line {
        case "ready": serviceReady = true
        case "recording 1": setRecording(true)
        case "recording 0": setRecording(false)
        default: break  // newer service, older app: ignore
        }
    }

    private func send(_ command: String) {
        // Before "ready" the service is still loading; a buffered toggle would start
        // a recording long after the gesture.
        guard serviceReady, !paused else { return }
        channel?.send(command)
    }

    private func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        // Unregister so the recorder can capture the combination itself.
        registerDictate()
        if recording {
            unregisterRecordingKeys()
            if !paused { registerRecordingKeys() }
        }
    }

    private func register(_ id: HotkeyID, _ combo: KeyCombo) {
        unswallowed = unswallowed.filter { $0.value != id }
        if !CarbonHotkeys.shared.register(id.rawValue, keyCode: combo.keyCode, modifiers: combo.modifiers.carbon,
                                          action: { [weak self] in self?.send(id.command) }) {
            unswallowed[combo] = id
        }
    }

    private func unregister(_ id: HotkeyID) {
        CarbonHotkeys.shared.unregister(id.rawValue)
        unswallowed = unswallowed.filter { $0.value != id }
    }

    private func registerDictate() {
        if let combo = dictate.combo, !paused {
            register(.dictate, combo)
        } else {
            unregister(.dictate)
        }
    }

    private func registerRecordingKeys() {
        register(.discard, discard)
        register(.finish, insert)
    }

    private func unregisterRecordingKeys() {
        for id in [HotkeyID.discard, .finish] { unregister(id) }
    }

    private func setRecording(_ active: Bool) {
        guard active != recording else { return }
        recording = active
        unregisterRecordingKeys()
        if active && !paused { registerRecordingKeys() }
    }

    private func handle(_ event: TapEvent) {
        guard !paused else { return }
        switch event {
        case .gesture:
            send("toggle")
        case let .keyDown(keyCode, rawFlags):
            let modifiers = KeyModifiers(cgFlags: CGEventFlags(rawValue: rawFlags))
            if keyCode == ShortcutKey.escape && modifiers == .option {
                // Option+Esc stops the service, as it always has; observed, not swallowed.
                send("quit")
                return
            }
            let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
            if let id = unswallowed[combo] {
                if id == .dictate || recording { send(id.command) }
                return
            }
            // The plain keys are Carbon hotkeys and arrive there, swallowed.
            // With a modifier (Shift+Return) they still end the recording, as
            // with the service's own listener, but reach the app as well.
            guard recording, !modifiers.isEmpty, combo != dictate.combo else { return }
            if keyCode == discard.keyCode {
                send("discard")
            } else if keyCode == insert.keyCode {
                send("finish")
            }
        }
    }
}
