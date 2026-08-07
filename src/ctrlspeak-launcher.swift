import AVFoundation
import ApplicationServices
import Foundation
import IOKit.hid

// Native entry point for LocalVoice.app.
//
// macOS attributes TCC permissions to the *responsible process*, which is the
// root of the process tree rather than whichever binary happens to call the
// API. Running ctrlSPEAK straight from a LaunchAgent made that root /bin/bash,
// so Microphone, Accessibility and Input Monitoring had to be granted to bash
// or to the Homebrew Python symlink — a versioned Cellar path that Input
// Monitoring will not accept and that breaks on every Python upgrade.
//
// This launcher is that root instead. It is a real Mach-O binary inside a
// bundle, so the permission panes show "LocalVoice", and every child it spawns
// inherits it as the responsible process.
//
// Modes:
//   (default)        run the dictation service via the wrapper
//   --setup          guided permission setup: request all three permissions so
//                    macOS pre-lists the app in the privacy panes; the user
//                    only confirms, never hunts for a hidden path
//   --setup-status   print each permission's state and exit (used by doctor.sh)
//
// It deliberately spawns the wrapper as a child rather than exec'ing it:
// exec would replace this image, and the responsible process would become the
// shell again. For the same reason it holds no configuration of its own —
// paths are read from Resources/launch.conf so the binary stays byte-identical
// across machines and keeps its code signature, and with it its permissions,
// stable between installs.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("LocalVoice: \(message)\n".utf8))
    exit(code)
}

func loadConfig() -> [String: String] {
    guard let configURL = Bundle.main.url(forResource: "launch", withExtension: "conf"),
          let rawConfig = try? String(contentsOf: configURL, encoding: .utf8) else {
        fail("launch.conf is missing from the app bundle; re-run install.sh", code: 78)
    }

    var config: [String: String] = [:]
    for line in rawConfig.split(separator: "\n") {
        let entry = line.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty, !entry.hasPrefix("#"),
              let separator = entry.firstIndex(of: "=") else { continue }
        config[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
    }
    return config
}

// MARK: - Permission state

enum PermissionState: String {
    case granted
    case denied
    case undetermined
}

func microphoneState() -> PermissionState {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return .granted
    case .notDetermined: return .undetermined
    default: return .denied
    }
}

func accessibilityState() -> PermissionState {
    // AX has no tri-state API; "not granted" covers both denied and never asked.
    AXIsProcessTrusted() ? .granted : .denied
}

func inputMonitoringState() -> PermissionState {
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeGranted: return .granted
    case kIOHIDAccessTypeUnknown: return .undetermined
    default: return .denied
    }
}

// MARK: - Setup wizard

/// Feed status lines to the recording pill so the wizard has a visible face.
final class SetupPill {
    private var process: Process?
    private var stdin: FileHandle?

    init(overlayPath: String?) {
        guard let overlayPath, FileManager.default.isExecutableFile(atPath: overlayPath) else {
            return
        }

        let pill = Process()
        pill.executableURL = URL(fileURLWithPath: overlayPath)
        pill.arguments = ["permission", "de"]
        let pipe = Pipe()
        pill.standardInput = pipe
        pill.standardOutput = FileHandle.nullDevice
        pill.standardError = FileHandle.nullDevice

        do {
            try pill.run()
            process = pill
            stdin = pipe.fileHandleForWriting
        } catch {
            process = nil
            stdin = nil
        }
    }

    func detail(_ text: String) {
        send("detail \(text)")
    }

    func close() {
        send("quit")
        try? stdin?.close()
        process = nil
        stdin = nil
    }

    private func send(_ command: String) {
        guard let stdin, process?.isRunning == true else { return }
        try? stdin.write(contentsOf: Data((command + "\n").utf8))
    }
}

func openPrivacyPane(_ anchor: String) {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["x-apple.systempreferences:com.apple.preference.security?\(anchor)"]
    try? open.run()
}

func writeSetupStatus(_ value: String) {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ctrlspeak", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data((value + "\n").utf8).write(to: directory.appendingPathComponent("setup-status"))
}

func runSetup(config: [String: String]) -> Never {
    struct Step {
        let name: String
        let shortName: String
        let state: () -> PermissionState
        let request: () -> Void
        let pane: String
    }

    // Requesting is what pre-lists the app in each privacy pane, which is the
    // entire point of the wizard: the user confirms a dialog or flips one
    // switch, instead of digging a hidden unix path out of a file picker.
    let steps = [
        Step(
            name: "Microphone",
            shortName: "Mic",
            state: microphoneState,
            request: { AVCaptureDevice.requestAccess(for: .audio) { _ in } },
            pane: "Privacy_Microphone"
        ),
        Step(
            name: "Accessibility",
            shortName: "Access",
            state: accessibilityState,
            request: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            },
            pane: "Privacy_Accessibility"
        ),
        Step(
            name: "Input Monitoring",
            shortName: "Input",
            state: inputMonitoringState,
            request: { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) },
            pane: "Privacy_ListenEvent"
        ),
    ]

    if steps.allSatisfy({ $0.state() == .granted }) {
        writeSetupStatus("granted")
        exit(0)
    }

    let pill = SetupPill(overlayPath: config["overlay"])

    func statusLine() -> String {
        steps.map { "\($0.shortName) \($0.state() == .granted ? "✓" : "○")" }
            .joined(separator: "  ·  ")
    }

    let deadline = Date().addingTimeInterval(15 * 60)
    var requested = Set<String>()
    var paneOpened = Set<String>()
    var waitingSince: [String: Date] = [:]

    while Date() < deadline {
        guard let current = steps.first(where: { $0.state() != .granted }) else { break }

        if !requested.contains(current.name) {
            requested.insert(current.name)
            waitingSince[current.name] = Date()
            current.request()
        }

        // The system dialog covers the happy path. If it was dismissed or the
        // permission was denied earlier (no second dialog exists), take the
        // user to the right pane — the app is already listed there.
        if current.state() == .denied,
           !paneOpened.contains(current.name),
           Date().timeIntervalSince(waitingSince[current.name] ?? Date()) > 8 {
            paneOpened.insert(current.name)
            openPrivacyPane(current.pane)
        }

        pill.detail("\(statusLine())  —  waiting for \(current.name)")
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    }

    let allGranted = steps.allSatisfy { $0.state() == .granted }
    if allGranted {
        pill.detail("\(statusLine())  —  all set")
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    }
    pill.close()

    writeSetupStatus(allGranted ? "granted" : "timeout")
    exit(allGranted ? 0 : 1)
}

func printSetupStatus() -> Never {
    let report = [
        "microphone=\(microphoneState().rawValue)",
        "accessibility=\(accessibilityState().rawValue)",
        "input-monitoring=\(inputMonitoringState().rawValue)",
    ].joined(separator: "\n")

    print(report)

    // Also written to a file: doctor.sh must launch this through
    // LaunchServices for the answer to be about the app rather than the
    // terminal, and "open" provides no stdout channel.
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ctrlspeak", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data((report + "\n").utf8).write(to: directory.appendingPathComponent("permission-status"))

    exit(0)
}

// MARK: - Service mode

func runService(config: [String: String], arguments: [String]) -> Never {
    guard let command = config["command"] else {
        fail("launch.conf has no 'command' entry; re-run install.sh", code: 78)
    }

    guard FileManager.default.isExecutableFile(atPath: command) else {
        fail("\(command) is missing or not executable; re-run install.sh", code: 72)
    }

    let child = Process()
    child.executableURL = URL(fileURLWithPath: command)
    child.arguments = arguments

    var environment = ProcessInfo.processInfo.environment
    if let path = config["path"] {
        environment["PATH"] = path
    }
    if let overlay = config["overlay"] {
        environment["CTRLSPEAK_OVERLAY_PATH"] = overlay
    }
    child.environment = environment

    // launchctl bootout signals this process; the child has to come down with
    // it or KeepAlive would restart into an orphaned transcription worker.
    // The sources must outlive this setup, so they are kept alive in an array
    // referenced by the termination handler's captured context.
    var terminationSources: [DispatchSourceSignal] = []
    for terminationSignal in [SIGTERM, SIGINT, SIGHUP] {
        signal(terminationSignal, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: terminationSignal, queue: .main)
        source.setEventHandler {
            if child.isRunning {
                child.terminate()
            }
        }
        source.resume()
        terminationSources.append(source)
    }

    child.terminationHandler = { finished in
        withExtendedLifetime(terminationSources) {}
        exit(finished.terminationStatus)
    }

    do {
        try child.run()
    } catch {
        fail("could not start \(command): \(error.localizedDescription)", code: 70)
    }

    dispatchMain()
}

// MARK: - Entry

let config = loadConfig()
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--setup") {
    runSetup(config: config)
} else if arguments.contains("--setup-status") {
    printSetupStatus()
} else {
    runService(config: config, arguments: arguments)
}
