import AVFoundation
import AppKit
import ApplicationServices
import CoreAudio
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

// MARK: - LocalVoice config file

// The launcher shares the service's config file rather than owning any state:
// the menu bar writes a key, the Python service's watcher applies it within
// seconds, and the pill reads it per spawn. One source of truth, no IPC.

let serviceLabel = "com.localvoice.app"

func localVoiceConfigPath() -> String {
    ProcessInfo.processInfo.environment["LOCALVOICE_CONFIG_DIR"].map { $0 + "/config" }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/localvoice/config").path
}

func readConfigValue(_ key: String) -> String? {
    guard let raw = try? String(contentsOfFile: localVoiceConfigPath(), encoding: .utf8) else {
        return nil
    }
    var value: String?
    for line in raw.split(separator: "\n") {
        let entry = line.trimmingCharacters(in: .whitespaces)
        guard !entry.hasPrefix("#"), let separator = entry.firstIndex(of: "=") else { continue }
        guard entry[..<separator].trimmingCharacters(in: .whitespaces).lowercased() == key else {
            continue
        }
        value = entry[entry.index(after: separator)...].trimmingCharacters(in: .whitespaces)
    }
    return (value?.isEmpty ?? true) ? nil : value
}

func writeConfigValue(_ key: String, _ value: String) {
    let path = localVoiceConfigPath()
    let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    var lines = raw.isEmpty ? [] : raw.components(separatedBy: "\n")

    var replaced = false
    for index in lines.indices {
        let entry = lines[index].trimmingCharacters(in: .whitespaces)
        guard !entry.hasPrefix("#"), let separator = entry.firstIndex(of: "=") else { continue }
        if entry[..<separator].trimmingCharacters(in: .whitespaces).lowercased() == key {
            lines[index] = "\(key) = \(value)"
            replaced = true
            break
        }
    }
    if !replaced {
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        lines.append("\(key) = \(value)")
        lines.append("")
    }

    try? FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Menu bar

/// The names of every device CoreAudio will record from, in system order.
/// These are the same names PortAudio shows the Python service, so writing
/// one into the config selects the same physical microphone on both sides.
func audioInputDeviceNames() -> [String] {
    var listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var listSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize
    ) == noErr, listSize > 0 else { return [] }

    var deviceIDs = [AudioDeviceID](
        repeating: 0, count: Int(listSize) / MemoryLayout<AudioDeviceID>.size
    )
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize, &deviceIDs
    ) == noErr else { return [] }

    var names: [String] = []
    for deviceID in deviceIDs {
        var configAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var configSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &configAddress, 0, nil, &configSize) == noErr,
              configSize > 0 else { continue }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID, &configAddress, 0, nil, &configSize,
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        ) == noErr else { continue }

        let buffers = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        let inputChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard inputChannels > 0 else { continue }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedName) { pointer in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, pointer)
        }
        if status == noErr, let name = unmanagedName?.takeRetainedValue() {
            names.append(name as String)
        }
    }
    return names
}

func runLaunchctl(_ subcommand: [String]) {
    let launchctl = Process()
    launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    launchctl.arguments = subcommand
    try? launchctl.run()
}

/// The status item: microphone picker, language, pill options, and service
/// controls. Every selection is a write to the config file; the menu is
/// rebuilt on each open so it always shows the file's current truth and the
/// devices currently attached.
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    var isVisible: Bool { statusItem != nil }

    func setVisible(_ visible: Bool) {
        if visible && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let icon = NSImage(
                    systemSymbolName: "waveform.and.mic", accessibilityDescription: "LocalVoice"
                ) ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "LocalVoice")
                icon?.isTemplate = true
                button.image = icon
                button.toolTip = "LocalVoice"
            }
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.submenu = microphoneMenu()
        menu.addItem(microphoneItem)

        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu()
        menu.addItem(languageItem)

        menu.addItem(.separator())
        menu.addItem(toggleItem(
            title: "Compact Pill", key: "compact", selector: #selector(toggleCompact)
        ))
        menu.addItem(toggleItem(
            title: "Microphone Standby", key: "mic-standby", selector: #selector(toggleStandby)
        ))

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Open Config File", selector: #selector(openConfig), key: ","))
        menu.addItem(actionItem(title: "Restart Service", selector: #selector(restartService)))
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit LocalVoice", selector: #selector(quitService), key: "q"))
    }

    private func microphoneMenu() -> NSMenu {
        let menu = NSMenu()
        let setting = (readConfigValue("microphone") ?? "built-in").lowercased()

        let builtIn = actionItem(title: "Built-in Microphone", selector: #selector(selectMicrophone(_:)))
        builtIn.representedObject = "built-in"
        builtIn.state = setting == "built-in" ? .on : .off
        menu.addItem(builtIn)

        let system = actionItem(title: "System Default", selector: #selector(selectMicrophone(_:)))
        system.representedObject = "system"
        system.state = setting == "system" ? .on : .off
        menu.addItem(system)

        let devices = audioInputDeviceNames()
        if !devices.isEmpty {
            menu.addItem(.separator())
            for name in devices {
                let item = actionItem(title: name, selector: #selector(selectMicrophone(_:)))
                item.representedObject = name
                if setting != "built-in" && setting != "system" {
                    item.state = name.lowercased().contains(setting) ? .on : .off
                }
                menu.addItem(item)
            }
        }
        return menu
    }

    private func languageMenu() -> NSMenu {
        let menu = NSMenu()
        let setting = (readConfigValue("language") ?? "de").lowercased()
        for (code, title) in [("de", "German"), ("en", "English"), ("auto", "Automatic")] {
            let item = actionItem(title: title, selector: #selector(selectLanguage(_:)))
            item.representedObject = code
            item.state = setting == code ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func toggleItem(title: String, key: String, selector: Selector) -> NSMenuItem {
        let item = actionItem(title: title, selector: selector)
        let value = (readConfigValue(key) ?? "off").lowercased()
        item.state = ["on", "true", "1", "yes"].contains(value) ? .on : .off
        return item
    }

    private func actionItem(title: String, selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String {
            writeConfigValue("microphone", value)
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String {
            writeConfigValue("language", value)
        }
    }

    @objc private func toggleCompact(_ sender: NSMenuItem) {
        writeConfigValue("compact", sender.state == .on ? "off" : "on")
    }

    @objc private func toggleStandby(_ sender: NSMenuItem) {
        writeConfigValue("mic-standby", sender.state == .on ? "off" : "on")
    }

    @objc private func openConfig() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-t", localVoiceConfigPath()]
        try? open.run()
    }

    @objc private func restartService() {
        // kickstart -k kills the whole job — this launcher included — and
        // launchd brings it straight back; the menu bar icon returns with it.
        runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(serviceLabel)"])
    }

    @objc private func quitService() {
        // bootout unloads the job, so KeepAlive does not resurrect it; the
        // next login (or scripts/restart.sh) brings LocalVoice back.
        runLaunchctl(["bootout", "gui/\(getuid())/\(serviceLabel)"])
    }
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

    // The launcher outlives the fork/exec dance anyway (it is the TCC
    // identity root), which makes it the natural host for the menu bar icon:
    // no extra process, no extra permissions. An AppKit run loop replaces
    // dispatchMain(); the signal sources and termination handler above are
    // main-queue based and keep working under it.
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let menuBar = MenuBarController()

    func menuBarEnabled() -> Bool {
        // Default on; only an explicit "off" (or falsy value) hides it.
        guard let value = readConfigValue("menubar")?.lowercased() else { return true }
        return ["on", "true", "1", "yes"].contains(value)
    }

    menuBar.setVisible(menuBarEnabled())

    // Follow config edits, so `menubar = off` takes effect like every other
    // key: within a couple of seconds, no restart.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
    timer.setEventHandler {
        let enabled = menuBarEnabled()
        if enabled != menuBar.isVisible {
            menuBar.setVisible(enabled)
        }
    }
    timer.resume()

    withExtendedLifetime((menuBar, timer)) {
        application.run()
    }
    exit(0)
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
