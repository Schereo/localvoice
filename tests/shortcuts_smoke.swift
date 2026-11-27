import Foundation

// Compiled with src/localvoice-shortcuts.swift by scripts/check.sh. Covers what
// needs no keyboard: the config parser, tap counting and the service channel.

nonisolated(unsafe) var configuredHotkey: String?
func readConfigValue(_ key: String) -> String? { key == "hotkey" ? configuredHotkey : nil }

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
        configuredHotkey = "nonsense"
        check(ModifierTapHotkey.current() == .standard, "invalid config falls back to ctrl,3")
        configuredHotkey = "alt,2"
        check(ModifierTapHotkey.current() == ModifierTapHotkey(modifier: .alt, taps: 2), "config is read")

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
