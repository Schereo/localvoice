import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation
import IOKit.hid
import OSLog
import ServiceManagement

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
    if let resources = Bundle.main.resourceURL {
        for key in ["command", "overlay", "model_python", "model_store", "vad", "parakeet_worker"] {
            if let path = config[key], !path.hasPrefix("/") {
                config[key] = resources.appendingPathComponent(path).standardizedFileURL.path
            }
        }
    }
    return config
}

// MARK: - Permission state

enum PermissionState: String {
    case granted
    case denied
    case undetermined
    case restricted
}

func microphoneState() -> PermissionState {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return .granted
    case .notDetermined: return .undetermined
    case .restricted: return .restricted
    default: return .denied
    }
}

func accessibilityState() -> PermissionState {
    // AX has no tri-state API; "not granted" covers both denied and never asked.
    AXIsProcessTrusted() ? .granted : .denied
}

func inputMonitoringState() -> PermissionState {
    // Check the same Core Graphics access the event tap actually needs.
    if CGPreflightListenEventAccess() { return .granted }
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeUnknown: return .undetermined
    default: return .denied
    }
}

// MARK: - Permission checklist

@MainActor
private final class AppBundleDragView: NSView, NSDraggingSource {
    private let appURL: URL
    private let icon: NSImage

    init(appURL: URL, appName: String) {
        self.appURL = appURL
        icon = Bundle.main.url(forResource: "LocalVoice", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) } ?? NSWorkspace.shared.icon(forFile: appURL.path)
        super.init(frame: .zero)
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: appName)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.toolTip = appName
        let tile = NSBox()
        tile.boxType = .custom
        tile.cornerRadius = 8
        tile.fillColor = .controlBackgroundColor
        tile.borderColor = .separatorColor
        tile.borderWidth = 1
        tile.contentViewMargins = NSSize(width: 12, height: 8)
        let stack = NSStackView(views: [image, label])
        stack.alignment = .centerY
        tile.contentView = stack
        tile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 36),
            image.heightAnchor.constraint(equalToConstant: 36),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Drag \(appName) into System Settings")
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation { .copy }
}

@MainActor
private final class PermissionDragPanel: NSPanel {
    init(permission: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 326, height: 104),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Add LocalVoice"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false

        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LocalVoice"
        let intro = NSTextField(labelWithString: "Drag into \(permission).")
        let tile = AppBundleDragView(appURL: Bundle.main.bundleURL, appName: name)
        let stack = NSStackView(views: [intro, tile])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tile.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tile.heightAnchor.constraint(equalToConstant: 54),
        ])
        contentView = view
    }

    required init?(coder: NSCoder) { nil }

    static let settingsID = "com.apple.systempreferences"

    static func settingsFrame() -> NSRect? {
        // Only read window bounds, never window pixels or titles.
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: settingsID).first,
              let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in windows where window[kCGWindowOwnerPID as String] as? pid_t == settings.processIdentifier {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 400, rect.height >= 300
            else { continue }
            // WindowServer uses a top-left origin; AppKit uses bottom-left.
            return NSRect(x: primary.frame.minX + rect.minX, y: primary.frame.maxY - rect.maxY,
                          width: rect.width, height: rect.height)
        }
        return nil
    }

    static func origin(beside target: NSRect, visible area: NSRect, size: NSSize) -> NSPoint {
        let gap: CGFloat = 10
        let right = target.maxX + gap
        let left = target.minX - gap - size.width
        let top = max(area.minY, min(target.maxY, area.maxY) - size.height)
        if right + size.width <= area.maxX { return NSPoint(x: right, y: top) }
        if left >= area.minX { return NSPoint(x: left, y: top) }
        let x = max(area.minX, min(target.maxX, area.maxX) - size.width)
        let below = target.minY - gap - size.height
        if below >= area.minY { return NSPoint(x: x, y: below) }
        let above = target.maxY + gap
        if above + size.height <= area.maxY { return NSPoint(x: x, y: above) }
        return NSPoint(x: max(area.minX, area.maxX - size.width), y: top)
    }

    func place(beside target: NSRect) {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let rect = screen.frame.intersection(target)
            return rect.isNull ? 0 : rect.width * rect.height
        }
        guard let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }) else { return }
        setFrameOrigin(Self.origin(beside: target, visible: screen.visibleFrame, size: frame.size))
    }
}

@MainActor
private final class PermissionChecklist: NSWindowController, NSWindowDelegate {
    private struct Step {
        let name: String
        let explanation: String
        let pane: String
        let state: () -> PermissionState
    }

    private let steps = [
        Step(name: "Microphone", explanation: "Records audio when you start dictation.",
             pane: "Privacy_Microphone", state: microphoneState),
        Step(name: "Accessibility", explanation: "Inserts text into the app you’re using.",
             pane: "Privacy_Accessibility", state: accessibilityState),
        Step(name: "Input Monitoring", explanation: "Detects your global dictation shortcut.",
             pane: "Privacy_ListenEvent", state: inputMonitoringState),
    ]
    private var statusLabels: [NSTextField] = []
    private var actions: [NSButton] = []
    private var microphonePending = false
    private var dragPanel: PermissionDragPanel?
    private var dragStep: Int?
    private var dragPlacement: Task<Void, Never>?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    private var lastStatuses: [PermissionState] = []
    private let log = Logger(subsystem: "com.localvoice", category: "permissions")
    private var wasReady = false
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let done = NSButton(title: "Set Up Later", target: nil, action: nil)
    var onReady: (() -> Void)?
    var onClose: ((Bool) -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 410),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "LocalVoice Permissions"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self

        let heading = NSTextField(labelWithString: "Set Up Permissions")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString:
            "LocalVoice checks access automatically. macOS only asks when you choose an action below.")
        intro.textColor = .secondaryLabelColor
        let content = NSStackView(views: [heading, intro])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        intro.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        for (index, step) in steps.enumerated() {
            let title = NSTextField(labelWithString: step.name)
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            let explanation = NSTextField(labelWithString: step.explanation)
            explanation.textColor = .secondaryLabelColor
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            let labels = NSStackView(views: [title, explanation, status])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 3
            let button = NSButton(title: "Open Settings", target: self, action: #selector(handlePermission))
            button.tag = index
            let row = NSStackView(views: [labels, NSView(), button])
            row.alignment = .centerY
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            statusLabels.append(status)
            actions.append(button)
        }

        summary.textColor = .secondaryLabelColor
        content.addArrangedSubview(summary)
        summary.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        done.target = self
        done.action = #selector(dismiss)
        let reveal = NSButton(title: "Show App in Finder", target: self, action: #selector(revealApp))
        let footer = NSStackView(views: [reveal, NSView(), done])
        content.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let view = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
        ])
        window.contentView = view
        window.center()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationActivated),
            name: NSApplication.didBecomeActiveNotification, object: NSApp
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        if previousActivationPolicy == nil {
            previousActivationPolicy = NSApp.activationPolicy()
            // A menu-bar app is absent from Cmd-Tab. Setup sends the user to
            // another app, so stay in the Dock and app switcher until closed.
            if !NSApp.setActivationPolicy(.regular) {
                log.error("Could not make the permission checklist a regular app window")
            }
        }
        NSApp.unhide(nil)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    @objc private func applicationActivated(_ notification: Notification) { refresh() }

    @objc private func workspaceActivated(_ notification: Notification) {
        guard let dragPanel,
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        if app.bundleIdentifier == PermissionDragPanel.settingsID {
            if dragPlacement == nil && !dragPanel.isVisible { placeDragPanelWhenSettingsOpen() }
        } else if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            dragPanel.orderOut(nil)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === dragPanel {
            dragPlacement?.cancel()
            dragPlacement = nil
            dragPanel = nil
            dragStep = nil
            return
        }
        dragPanel?.close()
        if let previousActivationPolicy {
            self.previousActivationPolicy = nil
            NSApp.setActivationPolicy(previousActivationPolicy)
        }
        onClose?(steps.allSatisfy { $0.state() == .granted })
    }

    @objc private func dismiss() { close() }

    @objc private func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func showDragPanel(for index: Int) {
        if dragStep != index || dragPanel == nil {
            dragPanel?.close()
            let panel = PermissionDragPanel(permission: steps[index].name)
            panel.delegate = self
            dragPanel = panel
            dragStep = index
        }
    }

    private func placeDragPanelWhenSettingsOpen() {
        guard let dragPanel else { return }
        dragPlacement?.cancel()
        dragPlacement = Task { @MainActor [weak self, weak dragPanel] in
            // A new Settings window may not exist yet when we open the pane.
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let dragPanel else { return }
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == PermissionDragPanel.settingsID,
                   let frame = PermissionDragPanel.settingsFrame() {
                    dragPanel.place(beside: frame)
                    dragPanel.orderFrontRegardless()
                    self.dragPlacement = nil
                    return
                }
            }
            guard let self, let dragPanel else { return }
            self.dragPlacement = nil
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if frontmost == PermissionDragPanel.settingsID || frontmost == Bundle.main.bundleIdentifier {
                if let frame = self.window?.frame { dragPanel.place(beside: frame) }
                dragPanel.orderFrontRegardless()
            }
        }
    }

    @objc private func handlePermission(_ button: NSButton) {
        let index = button.tag
        let step = steps[index]
        let status = step.state()
        guard status != .granted, status != .restricted else { refresh(); return }
        guard index == 0 && status == .undetermined else {
            if index != 0 { showDragPanel(for: index) }
            else { dragPanel?.close() }
            openPrivacyPane(step.pane)
            if index != 0 { placeDragPanelWhenSettingsOpen() }
            return
        }
        guard !microphonePending else { return }
        microphonePending = true
        Task { @MainActor [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            self?.microphoneRequestFinished()
        }
        refresh()
    }

    private func microphoneRequestFinished() {
        microphonePending = false
        // Don't reopen a dismissed checklist or steal focus from another app.
        guard let window, window.isVisible else { return }
        if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
        refresh()
    }

    var isPresented: Bool { previousActivationPolicy != nil }

    private func refresh() {
        guard window?.isVisible == true else { return }
        let statuses = steps.map { $0.state() }
        if let dragStep, statuses[dragStep] == .granted { dragPanel?.close() }
        if statuses != lastStatuses {
            log.notice("Permission status: microphone=\(statuses[0].rawValue, privacy: .public) accessibility=\(statuses[1].rawValue, privacy: .public) inputMonitoring=\(statuses[2].rawValue, privacy: .public)")
            lastStatuses = statuses
        }
        let ready = statuses.allSatisfy { $0 == .granted }
        for (index, step) in steps.enumerated() {
            let status = statuses[index]
            let label = statusLabels[index]
            let button = actions[index]
            switch status {
            case .granted: label.stringValue = "Granted"
            case .restricted: label.stringValue = "Restricted by macOS"
            case .undetermined: label.stringValue = "Not requested"
            case .denied: label.stringValue = "Not granted"
            }
            label.textColor = status == .granted ? .systemGreen : .secondaryLabelColor
            button.isEnabled = status != .granted && status != .restricted && !(index == 0 && microphonePending)
            switch status {
            case .granted: button.title = "Allowed"
            case .restricted: button.title = "Unavailable"
            default:
                if index == 0 && microphonePending {
                    button.title = "Waiting for macOS…"
                } else {
                    button.title = index == 0 && status == .undetermined ? "Request Access…" : "Open Settings…"
                }
            }
            button.setAccessibilityLabel("\(button.title) for \(step.name)")
        }
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LocalVoice"
        summary.stringValue = ready
            ? "All permissions are granted."
            : "Enable \(name) in System Settings. If macOS offers Quit & Reopen, choose it."
        done.title = ready ? "Done" : "Set Up Later"
        done.keyEquivalent = ready ? "\r" : ""
        let newlyReady = ready && !wasReady
        wasReady = ready
        if newlyReady { onReady?() }
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

func writeSetupStatus(_ value: String, managed: Bool) {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(managed ? "Library/Application Support/LocalVoice" : ".config/ctrlspeak",
                                isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data((value + "\n").utf8).write(to: directory.appendingPathComponent("setup-status"))
}

func runSetup(config: [String: String]) -> Int32 {
    let managed = config["managed_models"] == "1"
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
        writeSetupStatus("granted", managed: managed)
        return 0
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

    writeSetupStatus(allGranted ? "granted" : "timeout", managed: managed)
    return allGranted ? 0 : 1
}

@MainActor
private func runManagedSetup() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let checklist = PermissionChecklist()
    checklist.onClose = { granted in
        writeSetupStatus(granted ? "granted" : "deferred", managed: true)
        exit(granted ? 0 : 1)
    }
    checklist.present()
    withExtendedLifetime(checklist) { app.run() }
    exit(1)
}

func printSetupStatus(config: [String: String]) -> Never {
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
        .appendingPathComponent(
            config["managed_models"] == "1" ? "Library/Application Support/LocalVoice" : ".config/ctrlspeak",
            isDirectory: true
        )
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

@discardableResult
func writeConfigValue(_ key: String, _ value: String) -> Bool {
    guard value.rangeOfCharacter(from: .newlines) == nil else { return false }
    let path = localVoiceConfigPath()
    let raw: String
    do {
        raw = try String(contentsOfFile: path, encoding: .utf8)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        raw = ""
    } catch {
        return false
    }
    var lines = raw.isEmpty ? [] : raw.components(separatedBy: "\n")

    var replaced = false
    for index in lines.indices {
        let entry = lines[index].trimmingCharacters(in: .whitespaces)
        guard !entry.hasPrefix("#"), let separator = entry.firstIndex(of: "=") else { continue }
        if entry[..<separator].trimmingCharacters(in: .whitespaces).lowercased() == key {
            lines[index] = "\(key) = \(value)"
            replaced = true
        }
    }
    if !replaced {
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        lines.append("\(key) = \(value)")
        lines.append("")
    }

    do {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return true
    } catch {
        return false
    }
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

@MainActor
private final class SettingsViewController: NSViewController {
    private let modifier = NSPopUpButton()
    private let taps = NSPopUpButton()
    private let microphone = NSPopUpButton()
    private let preview = NSButton(checkboxWithTitle: "Show text while dictating", target: nil, action: nil)
    private let standby = NSButton(checkboxWithTitle: "Keep microphone open between dictations", target: nil, action: nil)
    private let pauseMedia = NSButton(checkboxWithTitle: "Pause media during dictation", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "")

    override func loadView() {
        configure(modifier, label: "Hotkey Modifier", action: #selector(changeHotkey))
        configure(taps, label: "Hotkey Tap Count", action: #selector(changeHotkey))
        configure(microphone, label: "Microphone", action: #selector(changeMicrophone))
        setItems([("Control", "ctrl"), ("Command", "cmd"), ("Option", "alt"), ("Shift", "shift")], on: modifier)
        setItems((2...4).map { ("\($0) taps", "\($0)") }, on: taps)

        for (button, key) in [(preview, "live-preview"), (standby, "mic-standby"), (pauseMedia, "pause-media")] {
            button.identifier = NSUserInterfaceItemIdentifier(key)
            button.target = self
            button.action = #selector(changeToggle)
        }

        let hotkey = NSStackView(views: [modifier, taps])
        hotkey.spacing = 6
        let controls = NSGridView(views: [
            [NSTextField(labelWithString: "Hotkey"), hotkey],
            [NSTextField(labelWithString: "Microphone"), microphone],
            [NSTextField(labelWithString: "Live Preview"), preview],
            [NSTextField(labelWithString: "Microphone Standby"), standby],
            [NSTextField(labelWithString: "Audio"), pauseMedia],
        ])
        controls.column(at: 0).xPlacement = .trailing
        controls.column(at: 1).xPlacement = .leading
        controls.yPlacement = .center
        controls.columnSpacing = 14
        controls.rowSpacing = 14

        message.textColor = .systemRed
        let stack = NSStackView(views: [controls, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 235))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            microphone.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        view = content
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let key = (readConfigValue("hotkey") ?? "").lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        select(key.count == 2 ? key[0] : "ctrl", fallback: "ctrl", on: modifier)
        select(key.count == 2 ? key[1] : "3", fallback: "3", on: taps)

        let current = readConfigValue("microphone") ?? "built-in"
        var devices = [("Built-in Microphone", "built-in"), ("System Default", "system")]
        for device in audioInputDeviceNames()
            where !devices.contains(where: { $0.1.caseInsensitiveCompare(device) == .orderedSame }) {
            devices.append((device, device))
        }
        if !devices.contains(where: { $0.1.caseInsensitiveCompare(current) == .orderedSame }) {
            devices.append(("\(current) (Not Listed)", current))
        }
        setItems(devices, on: microphone)
        select(current, fallback: "built-in", on: microphone)
        for button in [preview, standby, pauseMedia] {
            let key = button.identifier!.rawValue
            button.state = ["1", "on", "true", "yes"].contains(readConfigValue(key)?.lowercased() ?? "") ? .on : .off
        }
    }

    private func configure(_ button: NSPopUpButton, label: String, action: Selector) {
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    private func setItems(_ values: [(String, String)], on button: NSPopUpButton) {
        button.removeAllItems()
        for (title, value) in values {
            button.addItem(withTitle: title)
            button.lastItem?.representedObject = value
        }
    }

    private func select(_ value: String, fallback: String, on button: NSPopUpButton) {
        let item = button.itemArray.first {
            ($0.representedObject as? String)?.caseInsensitiveCompare(value) == .orderedSame
        } ?? button.itemArray.first { $0.representedObject as? String == fallback }
        button.select(item)
    }

    private func save(_ key: String, _ value: String) {
        let saved = writeConfigValue(key, value)
        if !saved { refresh() }
        message.stringValue = saved ? "" : "Could not save the setting."
    }

    @objc private func changeHotkey() {
        guard let key = modifier.selectedItem?.representedObject as? String,
              let count = taps.selectedItem?.representedObject as? String else { return }
        save("hotkey", "\(key),\(count)")
    }

    @objc private func changeMicrophone() {
        if let device = microphone.selectedItem?.representedObject as? String { save("microphone", device) }
    }

    @objc private func changeToggle(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { save(key, sender.state == .on ? "on" : "off") }
    }
}

/// The status item: microphone picker, language, pill options, and service
/// controls. Every selection is a write to the config file; the menu is
/// rebuilt on each open so it always shows the file's current truth and the
/// devices currently attached.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    var showModels: (() -> Void)?
    var showSettings: (() -> Void)?
    var setupPermissions: (() -> Void)?
    var restart: (() -> Void)?
    var quit: (() -> Void)?

    var isVisible: Bool { statusItem != nil }

    func installApplicationMenu() {
        let main = NSMenu()
        let app = NSMenuItem()
        let submenu = NSMenu(title: "LocalVoice")
        submenu.addItem(actionItem(title: "Settings…", selector: #selector(openSettings), key: ","))
        submenu.addItem(.separator())
        submenu.addItem(actionItem(title: "Quit LocalVoice", selector: #selector(quitService), key: "q"))
        app.submenu = submenu
        main.addItem(app)
        NSApp.mainMenu = main
    }

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

        if showSettings != nil {
            menu.addItem(actionItem(title: "Settings…", selector: #selector(openSettings), key: ","))
        } else {
            let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
            microphoneItem.submenu = microphoneMenu()
            menu.addItem(microphoneItem)
            let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
            languageItem.submenu = languageMenu()
            menu.addItem(languageItem)
            menu.addItem(toggleItem(
                title: "Compact Pill", key: "compact", selector: #selector(toggleCompact)
            ))
            menu.addItem(toggleItem(
                title: "Microphone Standby", key: "mic-standby", selector: #selector(toggleStandby)
            ))
            menu.addItem(toggleItem(
                title: "Pause Media While Recording", key: "pause-media",
                selector: #selector(togglePauseMedia)
            ))
            menu.addItem(toggleItem(
                title: "Live Transcript Preview", key: "live-preview", selector: #selector(toggleLivePreview)
            ))
        }

        menu.addItem(.separator())
        if showModels != nil {
            menu.addItem(actionItem(title: "Models…", selector: #selector(openModels)))
        }
        if setupPermissions != nil {
            menu.addItem(actionItem(title: "Set Up Permissions…", selector: #selector(openPermissions)))
            let login = actionItem(title: "Launch at Login", selector: #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        if showSettings == nil {
            menu.addItem(actionItem(title: "Open Config File", selector: #selector(openConfig), key: ","))
        }
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

    private func toggleItem(
        title: String, key: String, selector: Selector, defaultValue: String = "off"
    ) -> NSMenuItem {
        let item = actionItem(title: title, selector: selector)
        let value = (readConfigValue(key) ?? defaultValue).lowercased()
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

    @objc private func togglePauseMedia(_ sender: NSMenuItem) {
        writeConfigValue("pause-media", sender.state == .on ? "off" : "on")
    }

    @objc private func toggleLivePreview(_ sender: NSMenuItem) {
        writeConfigValue("live-preview", sender.state == .on ? "off" : "on")
    }

    @objc private func openSettings() { showSettings?() }

    @objc private func openConfig() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-t", localVoiceConfigPath()]
        try? open.run()
    }

    @objc private func restartService() {
        if let restart { restart(); return }
        // kickstart -k kills the whole job — this launcher included — and
        // launchd brings it straight back; the menu bar icon returns with it.
        runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(serviceLabel)"])
    }

    @objc private func quitService() {
        if let quit { quit(); return }
        // bootout unloads the job, so KeepAlive does not resurrect it; the
        // next login (or scripts/restart.sh) brings LocalVoice back.
        runLaunchctl(["bootout", "gui/\(getuid())/\(serviceLabel)"])
    }

    @objc private func openModels() { showModels?() }
    @objc private func openPermissions() { setupPermissions?() }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Service mode

@MainActor
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
    let terminationSources = [SIGTERM, SIGINT, SIGHUP].map { terminationSignal in
        signal(terminationSignal, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: terminationSignal, queue: .main)
        source.setEventHandler {
            if child.isRunning {
                child.terminate()
            }
        }
        source.resume()
        return source
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

// MARK: - Managed service

@MainActor
private final class ManagedService: NSObject, NSApplicationDelegate {
    private struct Switch {
        let model: String
        let fallback: String?
        let complete: (Bool) -> Void
        var recovering = false
    }

    private static let defaultModel = "whisper-turbo-fp16"
    private let config: [String: String]
    private let arguments: [String]
    private let scratch: URL
    private let selection: URL
    private let instanceLock: Int32
    private let menuBar = MenuBarController()
    private var library: StoreModelLibraryBackend?
    private var modelWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var menuTimer: Timer?
    private var child: Process?
    private var runningModel: String?
    private var readyTimer: Timer?
    private var gate: Int32 = -1
    private var pending: Switch?
    private var nextModel: String?
    private var stopping = false
    private var permissionChecklist: PermissionChecklist?
    private var waitingForPermissions = false
    private var mayRetry = true

    init(config: [String: String], arguments: [String]) throws {
        self.config = config
        self.arguments = arguments
        let files = FileManager.default
        let data = files.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalVoice", isDirectory: true)
        try files.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        selection = data.appendingPathComponent("selected-model")
        let descriptor = open(data.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw POSIXError(.EWOULDBLOCK)
        }
        instanceLock = descriptor
        scratch = files.temporaryDirectory.appendingPathComponent("localvoice-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            close(descriptor)
            throw error
        }
        super.init()
    }

    private var savedModel: String? {
        guard let value = try? String(contentsOf: selection, encoding: .utf8),
              Self.allowedModel(value) else { return nil }
        return value
    }

    private static func allowedModel(_ id: String) -> Bool {
        [defaultModel, "whisper-turbo-q4", "parakeet-v3", "parakeet-ultra", "parakeet-redux",
         "nemotron-streaming"].contains(id)
    }

    func begin() {
        guard let python = config["model_python"], let store = config["model_store"] else {
            fail("Managed model tools are missing from launch.conf.", code: 78)
        }
        library = StoreModelLibraryBackend(
            python: URL(fileURLWithPath: python),
            store: URL(fileURLWithPath: store),
            selectedModel: nil,
            parakeetWorker: config["parakeet_worker"].map { URL(fileURLWithPath: $0) }
        ) { [weak self] model, complete in
            guard let self else { complete(false); return }
            self.switchTo(model, complete: complete)
        }
        menuBar.showModels = { [weak self] in self?.showModels() }
        menuBar.showSettings = { [weak self] in self?.showSettings() }
        menuBar.setupPermissions = { [weak self] in self?.setupPermissions() }
        menuBar.restart = { [weak self] in self?.restart() }
        menuBar.quit = { [weak self] in self?.quit() }
        menuBar.installApplicationMenu()
        applyMenuVisibility()
        menuTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyMenuVisibility() }
        }
        if permissionsGranted {
            start(savedModel ?? Self.defaultModel)
            if savedModel == nil { showModels() }
        } else {
            setupPermissions()
        }
    }

    private var permissionsGranted: Bool {
        microphoneState() == .granted && accessibilityState() == .granted && inputMonitoringState() == .granted
    }

    private func applyMenuVisibility() {
        let value = readConfigValue("menubar")?.lowercased() ?? "on"
        menuBar.setVisible(["on", "true", "1", "yes"].contains(value))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if permissionChecklist?.isPresented == true || !permissionsGranted {
            setupPermissions()
        } else {
            showModels()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if waitingForPermissions && permissionChecklist?.isPresented != true && permissionsGranted {
            permissionsBecameReady()
        }
    }

    private func showModels() {
        guard let library else { return }
        library.refresh()
        if modelWindow == nil {
            let controller = ModelLibraryViewController(
                backend: library,
                notice: "Models run locally. Language changes apply to the next dictation.",
                readLanguage: { id in
                    DictationLanguage(rawValue: readConfigValue("language.\(id)")?.lowercased() ?? "") ?? .auto
                },
                saveLanguage: { id, language in
                    DictationLanguage.canSelect(for: id) && writeConfigValue("language.\(id)", language.rawValue)
                }
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "LocalVoice"
            // The store lists every catalog model (six), available or not; the
            // controller refits the window once it has the actual list.
            window.setContentSize(ModelLibraryViewController.preferredSize(
                modelCount: library.models.isEmpty ? 6 : library.models.count))
            window.isReleasedWhenClosed = false
            window.center()
            modelWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        modelWindow?.makeKeyAndOrderFront(nil)
    }

    private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsViewController()
            let window = NSWindow(contentViewController: controller)
            window.title = "LocalVoice Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 520, height: 235))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        (settingsWindow?.contentViewController as? SettingsViewController)?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func setupPermissions() {
        if permissionChecklist == nil {
            let checklist = PermissionChecklist()
            checklist.onReady = { [weak self] in self?.permissionsBecameReady() }
            checklist.onClose = { [weak self] granted in
                guard let self else { return }
                if granted && self.savedModel == nil { self.showModels() }
            }
            permissionChecklist = checklist
        }
        waitingForPermissions = !permissionsGranted
        permissionChecklist?.present()
    }

    private func permissionsBecameReady() {
        waitingForPermissions = false
        writeSetupStatus("granted", managed: true)
        if child == nil, let savedModel {
            start(savedModel)
        }
    }

    // The dictation service takes the same exclusive lock before starting a
    // session and holds it through insertion or cancellation.
    private func takeGate() -> Bool {
        guard gate == -1 else { return false }
        let path = scratch.appendingPathComponent("session.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        gate = descriptor
        return true
    }

    private func releaseGate() {
        if gate >= 0 {
            close(gate)
            gate = -1
        }
    }

    private func switchTo(_ id: String, complete: @escaping (Bool) -> Void) {
        guard permissionsGranted else {
            setupPermissions()
            complete(false)
            return
        }
        guard Self.allowedModel(id), takeGate() else {
            complete(false)
            return
        }
        pending = Switch(model: id, fallback: runningModel, complete: complete)
        mayRetry = true
        replace(with: id)
    }

    private func restart() {
        guard permissionsGranted, takeGate() else { return }
        mayRetry = true
        replace(with: savedModel ?? Self.defaultModel)
    }

    private func replace(with id: String) {
        if let child {
            nextModel = id
            terminate(child)
        } else {
            start(id)
        }
    }

    private func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak process] in
                guard let self, let process, self.child === process, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func start(_ model: String) {
        guard !stopping else { return }
        guard permissionsGranted else {
            failedStart(model)
            setupPermissions()
            return
        }
        library?.setLoadingModel(model)
        let ready = scratch.appendingPathComponent("ready")
        try? FileManager.default.removeItem(at: ready)
        guard let command = config["command"] else {
            failedStart(model)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Relative runtime paths are resolved by the bundle, not the user's shell.
        environment["PATH"] = config["path"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CTRLSPEAK_OVERLAY_PATH"] = config["overlay"]
        environment["LOCALVOICE_VAD_PATH"] = config["vad"]
        environment["LOCALVOICE_PARAKEET_WORKER"] = config["parakeet_worker"]
        environment["LOCALVOICE_MODEL_ID"] = model
        environment["LOCALVOICE_PERMISSIONS_PREFLIGHT"] = "1"
        environment["LOCALVOICE_READY_FILE"] = ready.path
        environment["LOCALVOICE_STATE_DIR"] = selection.deletingLastPathComponent().path
        environment["LOCALVOICE_SESSION_LOCK"] = scratch.appendingPathComponent("session.lock").path
        process.environment = environment
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { [weak self] in
                self?.ended(finished, model: model)
            }
        }
        do {
            try process.run()
        } catch {
            failedStart(model)
            return
        }
        child = process
        let deadline = Date().addingTimeInterval(150)
        readyTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak process] _ in
            DispatchQueue.main.async { [weak self, weak process] in
                guard let self, let process, self.child === process,
                      self.nextModel == nil, !self.stopping else { return }
                if process.isRunning,
                   (try? String(contentsOf: ready, encoding: .utf8)) == "\(process.processIdentifier)\n" {
                    self.becameReady(model)
                } else if Date() > deadline {
                    self.readyTimer?.invalidate()
                    self.readyTimer = nil
                    self.terminate(process)
                }
            }
        }
    }

    private func becameReady(_ model: String) {
        readyTimer?.invalidate()
        readyTimer = nil
        if let operation = pending, !operation.recovering {
            do {
                try FileManager.default.createDirectory(at: selection.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(model.utf8).write(to: selection, options: .atomic)
            } catch {
                if let child { terminate(child) }
                return
            }
        }
        runningModel = model
        library?.setActiveModel(model)
        library?.setLoadingModel(nil)
        if let operation = pending {
            pending = nil
            operation.complete(!operation.recovering)
        }
        releaseGate()
    }

    private func ended(_ process: Process, model: String) {
        guard child === process else { return }
        let wasReady = runningModel == model
        child = nil
        readyTimer?.invalidate()
        readyTimer = nil
        runningModel = nil
        library?.setActiveModel(nil)
        if stopping {
            exitCleanly()
        } else if let replacement = nextModel {
            nextModel = nil
            start(replacement)
        } else if wasReady, process.terminationStatus != 0, mayRetry {
            mayRetry = false
            start(model)
        } else {
            failedStart(model)
        }
    }

    private func failedStart(_ model: String) {
        if var operation = pending {
            if !operation.recovering, let fallback = operation.fallback, fallback != model {
                operation.recovering = true
                pending = operation
                start(fallback)
                return
            }
            pending = nil
            operation.complete(false)
        }
        releaseGate()
        library?.setLoadingModel(nil)
        library?.refresh()
        showModels()
    }

    func quit() {
        stopping = true
        menuTimer?.invalidate()
        library?.stop()
        if let child {
            terminate(child)
        } else {
            exitCleanly()
        }
    }

    private func exitCleanly() -> Never {
        releaseGate()
        try? FileManager.default.removeItem(at: scratch)
        close(instanceLock)
        exit(0)
    }
}

@MainActor
private func runManagedService(config: [String: String], arguments: [String]) -> Never {
    let managed: ManagedService
    do {
        managed = try ManagedService(config: config, arguments: arguments)
    } catch let error as POSIXError where error.code == .EWOULDBLOCK {
        exit(0)
    } catch {
        fail("Could not create service state: \(error.localizedDescription)", code: 74)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = managed
    let signals = [SIGTERM, SIGINT, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { managed.quit() }
        source.resume()
        return source
    }
    managed.begin()
    withExtendedLifetime(signals) { app.run() }
    exit(0)
}

// MARK: - Entry

@main
struct LocalVoiceLauncher {
    @MainActor
    static func main() {
        let config = loadConfig()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--setup") {
            if config["managed_models"] == "1" { runManagedSetup() }
            exit(runSetup(config: config))
        } else if arguments.contains("--setup-status") {
            printSetupStatus(config: config)
        } else if config["managed_models"] == "1" {
            runManagedService(config: config, arguments: arguments)
        } else {
            runService(config: config, arguments: arguments)
        }
    }
}
