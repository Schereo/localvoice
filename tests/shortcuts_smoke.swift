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
        config["dictate"] = "return"
        check(DictationShortcut.current() == .taps(ModifierTapHotkey(modifier: .alt, taps: 2)),
              "a refused dictate from the file falls back too")

        check(DictationShortcut.problem(with: Shortcut(config: "d")!) != nil, "plain key refused")
        check(DictationShortcut.problem(with: Shortcut(config: "shift+d")!) != nil, "Shift alone refused")
        check(DictationShortcut.problem(with: Shortcut(config: "return")!) != nil, "Return refused")
        check(DictationShortcut.problem(with: Shortcut(config: "f5")!) == nil, "F5 alone is fine")
        check(DictationShortcut.problem(with: Shortcut(config: "alt+space")!) == nil, "alt+space is fine")
        check(DictationShortcut.problem(with: Shortcut(config: "ctrl+cmd")!) == nil, "ctrl+cmd is fine")
        check(DictationShortcut.problem(with: Shortcut(config: "alt+escape")!) != nil, "Option+Esc quits, refused")

        // ⌃⌘: pressed when exactly both are held, released as soon as that ends,
        // ended once all are up; not clean if a key, click or another modifier came.
        var chord = ModifierChordDetector(chord: [.control, .command])
        check(chord.modifiersChanged(to: .control) == [], "one of two is nothing")
        check(chord.modifiersChanged(to: [.control, .command]) == [.pressed], "both held is the press")
        check(chord.modifiersChanged(to: .command) == [.released(clean: true)], "letting one go releases")
        check(chord.modifiersChanged(to: []) == [.ended(clean: true)], "all up ends it")
        _ = chord.modifiersChanged(to: [.control, .command])
        chord.otherInput()
        check(chord.modifiersChanged(to: []) == [.released(clean: false), .ended(clean: false)],
              "a key in between is not clean")
        _ = chord.modifiersChanged(to: [.control, .command])
        check(chord.modifiersChanged(to: [.control, .command, .shift]) == [.released(clean: false)],
              "an extra modifier is another shortcut")
        check(chord.modifiersChanged(to: [.control, .command]) == [], "no new press until all are up")
        check(chord.modifiersChanged(to: []) == [.ended(clean: false)], "and the sequence stays unclean")
        _ = chord.modifiersChanged(to: [.control, .shift])
        check(chord.modifiersChanged(to: [.control, .command, .shift]) == []
              && chord.modifiersChanged(to: [.control, .command]) == [], "arriving via a superset never presses")
        _ = chord.modifiersChanged(to: [])
        // Ctrl, a click, then Cmd: never all clean from the start.
        _ = chord.modifiersChanged(to: .control)
        chord.otherInput()
        check(chord.modifiersChanged(to: [.control, .command]) == [], "a click before the press voids it")
        _ = chord.modifiersChanged(to: [])
        // ⌃⌘, let go of ⌃, ⌘Space (Spotlight): the release was clean, the sequence not.
        _ = chord.modifiersChanged(to: [.control, .command])
        _ = chord.modifiersChanged(to: .command)
        chord.otherInput()
        check(chord.modifiersChanged(to: []) == [.ended(clean: false)], "⌘Space after ⌃⌘ is not a toggle")
        chord.otherInput()  // typing with nothing held changes nothing
        check(chord.modifiersChanged(to: [.command, .control]) == [.pressed], "fires again afterwards")
        _ = chord.modifiersChanged(to: [])
        var triple = ModifierChordDetector(chord: [.control, .command, .shift])
        _ = triple.modifiersChanged(to: [.control, .command])
        _ = triple.modifiersChanged(to: .command)
        check(triple.modifiersChanged(to: [.command, .shift]) == [] && triple.modifiersChanged(to: []) == [],
              "held in turns, never all at once, is not the chord")

        // Modes: a tap gesture always toggles; otherwise dictate-mode decides.
        config["dictate"] = "ctrl+cmd"
        config["dictate-mode"] = "hybrid"
        check(DictationShortcut.mode() == .hybrid, "mode is read")
        config["dictate"] = "ctrl,3"
        check(DictationShortcut.mode() == .toggle, "a gesture toggles")
        config["dictate-mode"] = "sideways"
        config["dictate"] = "alt+space"
        check(DictationShortcut.mode() == .toggle, "unknown mode toggles")

        var hold = DictationPress(mode: .hold)
        check(hold.pressed(at: 0) == "start", "hold: press starts")
        check(hold.released(at: 0.1, clean: true) == "stop", "hold: even a short release stops")
        _ = hold.pressed(at: 1)
        check(hold.released(at: 2, clean: false) == "cancel", "hold: an unclean release cancels, queued")
        check(hold.released(at: 3, clean: true) == nil, "a stray release does nothing")
        _ = hold.pressed(at: 4)
        check(hold.settle() == "stop" && hold.released(at: 5, clean: true) == nil,
              "hold: cut off from its release, it stops then")

        var hybrid = DictationPress(mode: .hybrid)
        check(hybrid.pressed(at: 0) == "start", "hybrid: press starts")
        check(hybrid.released(at: 0.2, clean: true) == nil, "hybrid: a short press latches")
        hybrid.recordingStarted()
        check(hybrid.pressed(at: 5) == "stop", "hybrid: the next press inserts")
        check(hybrid.released(at: 5.1, clean: true) == nil, "its release is ignored")
        check(hybrid.pressed(at: 5.2) == "start", "a press before recording 0 starts the next one")
        hybrid.recordingEnded()  // the earlier recording's end: not this press's
        check(hybrid.released(at: 5.3, clean: true) == nil, "short again: latched")
        hybrid.recordingStarted()
        check(hybrid.pressed(at: 6) == "stop", "the latch survived the earlier recording 0")
        _ = hybrid.released(at: 6.1, clean: true)
        check(hybrid.pressed(at: 9) == "start", "hybrid: press starts again")
        check(hybrid.released(at: 10, clean: true) == "stop", "hybrid: a long press was hold-to-talk")
        _ = hybrid.pressed(at: 11)
        _ = hybrid.released(at: 11.1, clean: true)
        hybrid.recordingStarted()
        hybrid.recordingEnded()  // Esc while latched
        check(hybrid.pressed(at: 12) == "start", "hybrid: after Esc a press starts anew")
        _ = hybrid.released(at: 12.1, clean: true)
        hybrid.startFailed()  // the microphone did not open
        check(hybrid.pressed(at: 13) == "start", "hybrid: after a failed start a press starts anew")
        _ = hybrid.released(at: 13.1, clean: true)
        hybrid.recordingStarted()
        check(hybrid.pressed(at: 14, deferStop: true) == nil, "hybrid chord: latched, the press waits")
        check(hybrid.released(at: 14.1, clean: false) == nil, "⌃⌘Q keeps the recording")
        check(hybrid.pressed(at: 15, deferStop: true) == nil && hybrid.released(at: 15.1, clean: true) == "stop",
              "a clean release inserts")

        _ = hybrid.pressed(at: 20)
        hybrid.recordingStarted()
        hybrid.recordingEnded()  // Esc while held
        check(hybrid.released(at: 20.1, clean: true) == nil && hybrid.pressed(at: 21) == "start",
              "hybrid: Esc while held leaves no latch")

        var toggle = DictationPress(mode: .toggle)
        check(toggle.pressed(at: 0) == "toggle" && toggle.released(at: 1, clean: true) == nil,
              "toggle: press toggles, release is nothing")

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
