import Foundation

// Compiled with src/localvoice-shortcuts.swift by scripts/check.sh. Covers what
// needs no keyboard: the config parser, tap counting and the service channel.

nonisolated(unsafe) var config: [String: String] = [:]
func readConfigValue(_ key: String) -> String? { config[key] }

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        FileHandle.standardError.write(Data("shortcuts_smoke.swift:\(line): \(message)\n".utf8))
        exit(1)
    }
}

@MainActor
func spin(until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !done() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

@main
struct ShortcutsSmoke {
    @MainActor
    static func main() {
        // Same acceptance as utils/localvoice_config.parse_hotkey.
        check(ModifierTapHotkey(config: "ctrl,3") == ModifierTapHotkey(modifier: .ctrl, taps: 3), "ctrl,3")
        check(ModifierTapHotkey(config: " CMD, 2 ") == ModifierTapHotkey(modifier: .cmd, taps: 2), "CMD, 2")
        for invalid in ["cmd ,2", "alt,5", "shift,1", "ctrl", "fn,3", "", "ctrl,x"] {
            check(ModifierTapHotkey(config: invalid) == nil, "accepted '\(invalid)'")
        }
        // Key combinations: modifiers in any order and spelling, written back canonically.
        check(Shortcut(config: "opt+space") == .combo(KeyCombo(keyCode: 49, modifiers: .option)), "opt+space")
        check(Shortcut(config: "CMD + Shift + D")?.configValue == "shift+cmd+d", "canonical order")
        check(Shortcut(config: "cmd+,")?.configValue == "cmd+comma", "comma key")
        check(Shortcut(config: "f5") == .combo(KeyCombo(keyCode: 96, modifiers: [])), "function key")
        check(Shortcut(config: "ctrl+#16")?.configValue == "ctrl+y", "raw key code")
        check(Shortcut(config: "ctrl,3") == .taps(.standard), "tap gesture")
        for invalid in ["hyper+a", "cmd+", "cmd+nokey", "ctrl,9", "", "+a", "ctrl,3+a"] {
            check(Shortcut(config: invalid) == nil, "accepted shortcut '\(invalid)'")
        }
        for value in ["return", "escape", "alt+space", "ctrl+alt+shift+cmd+f12", "cmd,2"] {
            check(Shortcut(config: value)?.configValue == value, "round trip '\(value)'")
        }

        // Modifiers alone: two or more, written canonically.
        check(Shortcut(config: "cmd+ctrl") == .chord([.control, .command]), "ctrl+cmd chord")
        check(Shortcut(config: "cmd+ctrl")?.configValue == "ctrl+cmd", "chord canonical order")
        check(Shortcut(config: "cmd+command") == nil, "one modifier twice is not a chord")

        // dictate, then the pre-1.5 hotkey key, then Control three times.
        check(DictationShortcut.current() == .taps(.standard), "default gesture")
        config["hotkey"] = "alt,2"
        check(DictationShortcut.current() == .taps(ModifierTapHotkey(modifier: .alt, taps: 2)), "hotkey is read")
        config["dictate"] = "alt+space"
        check(DictationShortcut.current() == Shortcut(config: "alt+space"), "dictate wins over hotkey")
        config["dictate"] = "nonsense"
        check(DictationShortcut.current() == .taps(ModifierTapHotkey(modifier: .alt, taps: 2)), "bad dictate falls back")

        check(DictationShortcut.problem(with: Shortcut(config: "d")!) != nil, "plain key refused")
        check(DictationShortcut.problem(with: Shortcut(config: "shift+d")!) != nil, "Shift alone refused")
        check(DictationShortcut.problem(with: Shortcut(config: "return")!) != nil, "Return refused")
        check(DictationShortcut.problem(with: Shortcut(config: "f5")!) == nil, "F5 alone is fine")
        check(DictationShortcut.problem(with: Shortcut(config: "alt+space")!) == nil, "alt+space is fine")
        check(DictationShortcut.problem(with: Shortcut(config: "ctrl+cmd")!) == nil, "ctrl+cmd is fine")

        // ⌃⌘ fires on release, and never when a key or click came in between (⌃⌘Q).
        var chord = ModifierChordDetector(chord: [.control, .command])
        check(!chord.modifiersChanged(to: .control) && !chord.modifiersChanged(to: [.control, .command])
              && !chord.modifiersChanged(to: .command), "nothing fires while held")
        check(chord.modifiersChanged(to: []), "release completes the chord")
        _ = chord.modifiersChanged(to: [.control, .command])
        chord.otherInput()
        check(!chord.modifiersChanged(to: []), "a key in between voids it")
        _ = chord.modifiersChanged(to: [.control, .command, .shift])
        check(!chord.modifiersChanged(to: []), "an extra modifier is another chord")
        _ = chord.modifiersChanged(to: .control)
        check(!chord.modifiersChanged(to: []), "Control alone is not the chord")
        chord.otherInput()  // typing with nothing held changes nothing
        _ = chord.modifiersChanged(to: [.control, .command])
        check(chord.modifiersChanged(to: []), "fires again afterwards")

        var counter = ModifierTapCounter(hotkey: .standard)
        check(!counter.press(isTapKey: true, at: 0) && !counter.press(isTapKey: true, at: 0.3),
              "two taps are not three")
        check(counter.press(isTapKey: true, at: 0.6), "third tap within 0.5 s of the last fires")
        check(!counter.press(isTapKey: true, at: 0.7), "the count starts over after firing")
        _ = counter.press(isTapKey: true, at: 0.8)
        check(!counter.press(isTapKey: true, at: 1.4), "a gap over 0.5 s starts over")
        _ = counter.press(isTapKey: true, at: 1.5)
        _ = counter.press(isTapKey: false, at: 1.6)
        check(!counter.press(isTapKey: true, at: 1.7), "another key in between starts over")
        _ = counter.press(isTapKey: true, at: 1.8)
        check(counter.press(isTapKey: true, at: 1.9), "three clean taps fire")

        var lines: [String] = []
        var closed = false
        guard let channel = ServiceChannel(onLine: { lines.append($0) }, onClose: { closed = true }) else {
            check(false, "socketpair failed")
            return
        }
        let service = channel.childEnd.fileDescriptor
        func serviceWrite(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBytes { write(service, $0.baseAddress, $0.count) }
        }
        serviceWrite("ready\nrecording ")
        serviceWrite("1\n")
        spin { lines.count == 2 }
        check(lines == ["ready", "recording 1"], "lines are reassembled: \(lines)")

        channel.send("toggle")
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = buffer.withUnsafeMutableBytes { read(service, $0.baseAddress, $0.count) }
        check(count > 0 && String(decoding: buffer[..<count], as: UTF8.self) == "toggle\n", "command reaches the service")

        // The service exiting closes its end: the app hears EOF.
        let peer = dup(service)
        channel.childStarted()
        check(!closed, "closing the app's copy of the child end is not EOF")
        close(peer)
        spin { closed }
        check(closed, "EOF reports the service gone")
        channel.send("toggle")  // after close: a no-op, and no SIGPIPE
        print("shortcuts smoke: ok")
    }
}
