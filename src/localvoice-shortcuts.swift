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
//   * the modifier-tap gesture (Control three times) comes from a listen-only
//     CGEventTap on a thread of its own, so a busy main thread never delays or
//     disables it;
//   * Esc and Enter are Carbon hotkeys registered only while a recording runs,
//     so they are swallowed then, and untouched the rest of the time.
//
// If the tap cannot be created, the service is started without the channel
// and falls back to its own pynput listener.

private let shortcutLog = Logger(subsystem: "com.localvoice.app", category: "shortcuts")

// MARK: - The configured gesture

/// `hotkey = <modifier>,<taps>`: a repeated tap on one modifier key.
struct ModifierTapHotkey: Equatable, Sendable {
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

    static func current() -> ModifierTapHotkey {
        ModifierTapHotkey(config: readConfigValue("hotkey")) ?? .standard
    }
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
    static let returnKey: Int64 = 36
}

/// What the tap hands to the main thread. Only the keys shortcuts use leave the
/// tap thread; ordinary typing is never forwarded.
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

final class KeyboardTap: @unchecked Sendable {
    // Written on the main thread, read on the tap thread.
    private let lock = NSLock()
    private var pendingHotkey: ModifierTapHotkey?
    // Tap thread only.
    private var counter: ModifierTapCounter
    private var port: CFMachPort?
    private let deliver: @Sendable (TapEvent) -> Void

    init(hotkey: ModifierTapHotkey, deliver: @escaping @Sendable (TapEvent) -> Void) {
        counter = ModifierTapCounter(hotkey: hotkey)
        self.deliver = deliver
    }

    func setHotkey(_ hotkey: ModifierTapHotkey) {
        lock.lock()
        pendingHotkey = hotkey
        lock.unlock()
    }

    /// Creates the tap (needs Input Monitoring) and runs it on its own thread.
    func start() -> Bool {
        if port != nil { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
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
            return
        default:
            break
        }
        lock.lock()
        if let hotkey = pendingHotkey {
            pendingHotkey = nil
            counter.hotkey = hotkey
            counter.reset()
        }
        lock.unlock()

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime
        if type == .flagsChanged {
            // A modifier going up is not a press; caps lock, fn and unknown keys always count as one.
            if let mask = modifierKeyMasks[keyCode], event.flags.rawValue & mask == 0 { return }
            if keyCode == 63, !event.flags.contains(.maskSecondaryFn) { return }
            if counter.press(isTapKey: counter.hotkey.modifier.keyCodes.contains(keyCode), at: now) {
                deliver(.gesture)
            }
        } else if type == .keyDown {
            _ = counter.press(isTapKey: false, at: now)
            if [ShortcutKey.escape, ShortcutKey.returnKey].contains(keyCode) {
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
    private enum HotkeyID: UInt32 { case discard = 1, finish }

    private var hotkey = ModifierTapHotkey.current()
    private lazy var tap = KeyboardTap(hotkey: hotkey) { [weak self] event in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }
    private var channel: ServiceChannel?
    private var serviceReady = false
    private var recording = false
    // Keys that could not be registered while recording; the tap still sees them.
    private var unswallowed: Set<HotkeyID> = []

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

    /// Follows edits of `hotkey` in the config file.
    func reloadConfig() {
        let current = ModifierTapHotkey.current()
        guard current != hotkey else { return }
        hotkey = current
        tap.setHotkey(current)
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
        guard serviceReady else { return }
        channel?.send(command)
    }

    private func setRecording(_ active: Bool) {
        guard active != recording else { return }
        recording = active
        let keys = CarbonHotkeys.shared
        unswallowed = []
        guard active else {
            for id in [HotkeyID.discard, .finish] { keys.unregister(id.rawValue) }
            return
        }
        if !keys.register(HotkeyID.discard.rawValue, keyCode: ShortcutKey.escape, modifiers: 0,
                          action: { [weak self] in self?.send("discard") }) {
            unswallowed.insert(.discard)
        }
        if !keys.register(HotkeyID.finish.rawValue, keyCode: ShortcutKey.returnKey, modifiers: 0,
                          action: { [weak self] in self?.send("finish") }) {
            unswallowed.insert(.finish)
        }
    }

    private func handle(_ event: TapEvent) {
        switch event {
        case .gesture:
            send("toggle")
        case let .keyDown(keyCode, rawFlags):
            let flags = CGEventFlags(rawValue: rawFlags)
            if keyCode == ShortcutKey.escape && flags.contains(.maskAlternate) {
                // Option+Esc stops the service, as it always has; observed, not swallowed.
                send("quit")
                return
            }
            guard recording else { return }
            // The plain keys are Carbon hotkeys and arrive there, swallowed.
            // With a modifier (Shift+Return) they still end the recording, as
            // with the service's own listener, but reach the app as well.
            let plain = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
            if keyCode == ShortcutKey.escape && (!plain || unswallowed.contains(.discard)) {
                send("discard")
            } else if keyCode == ShortcutKey.returnKey && (!plain || unswallowed.contains(.finish)) {
                send("finish")
            }
        }
    }
}
