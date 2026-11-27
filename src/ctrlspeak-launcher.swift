import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation
import IOKit.hid
import OSLog
import Security
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

enum PermissionKind: Int, CaseIterable {
    case microphone, accessibility, inputMonitoring

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var explanation: String {
        switch self {
        case .microphone: "Records your voice while you dictate."
        case .accessibility: "Types your words into the app you’re using."
        case .inputMonitoring: "Notices when you tap \(hotkeyDescription())."
        }
    }

    var symbol: NSImage? {
        switch self {
        case .microphone:
            NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        case .accessibility:
            // "accessibility" exists from macOS 14, "figure.stand" from macOS 11.
            NSImage(systemSymbolName: "accessibility", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "figure.stand", accessibilityDescription: nil)
        case .inputMonitoring:
            NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        }
    }

    var pane: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
    }

    var tccService: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "ListenEvent"
        }
    }

    var ledgerKey: String {
        switch self {
        case .microphone: "permissions.grantedBy.microphone"
        case .accessibility: "permissions.grantedBy.accessibility"
        case .inputMonitoring: "permissions.grantedBy.inputMonitoring"
        }
    }

    var step: Int { rawValue + 1 }
}

/// "Command twice" for `hotkey = cmd,2`; the service's default is Control three times.
func hotkeyDescription() -> String {
    let parts = (readConfigValue("hotkey") ?? "ctrl,3").lowercased().split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
    let modifiers = ["ctrl": "Control", "cmd": "Command", "alt": "Option", "shift": "Shift"]
    let taps = ["2": "twice", "3": "three times", "4": "four times"]
    guard parts.count == 2, let modifier = modifiers[parts[0]], let count = taps[parts[1]] else {
        return "Control three times"
    }
    return "\(modifier) \(count)"
}

func bundleDisplayName() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LocalVoice"
}

/// One read of the three permissions. Every call here is a check, never a prompt.
struct PermissionSnapshot: Equatable {
    var microphone: PermissionState
    var accessibility: Bool
    var inputMonitoring: Bool
    // IOHIDCheckAccess is only a hint (for "reopen needed"); granted means the CG check.
    var listenAccess: IOHIDAccessType

    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .microphone: microphone == .granted
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        }
    }

    var allGranted: Bool { PermissionKind.allCases.allSatisfy(isGranted) }
    var grantedCount: Int { PermissionKind.allCases.filter(isGranted).count }
}

@MainActor
protocol PermissionProbe: AnyObject {
    func read() -> PermissionSnapshot
}

@MainActor
final class LivePermissionProbe: PermissionProbe {
    func read() -> PermissionSnapshot {
        PermissionSnapshot(microphone: microphoneState(), accessibility: AXIsProcessTrusted(),
                           inputMonitoring: CGPreflightListenEventAccess(),
                           listenAccess: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
    }
}

/// The running build's code identity. Under ad-hoc signing macOS keys permissions to
/// the cdhash, so every rebuild is a new identity and earlier grants stop applying.
struct BuildIdentity: Sendable {
    let cdhash: String?
    let isAdhoc: Bool

    static let current: BuildIdentity = {
        let none = BuildIdentity(cdhash: nil, isAdhoc: false)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return none }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return none }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let unique = dictionary[kSecCodeInfoUnique as String] as? Data else { return none }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return BuildIdentity(cdhash: unique.map { String(format: "%02x", $0) }.joined(),
                             isAdhoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0)
    }()
}

/// What the setup window remembers across launches and rebuilds (UserDefaults of the app).
struct PermissionLedger {
    let store: UserDefaults
    static let resumeWindow: TimeInterval = 600

    static var standard: PermissionLedger { PermissionLedger(store: .standard) }

    func grantedBy(_ kind: PermissionKind) -> String? { store.string(forKey: kind.ledgerKey) }

    func setGrantedBy(_ kind: PermissionKind, _ value: String?) {
        if let value { store.set(value, forKey: kind.ledgerKey) } else { store.removeObject(forKey: kind.ledgerKey) }
    }

    var reopenedFor: String? {
        get { store.string(forKey: "permissions.reopenedFor") }
        nonmutating set { store.set(newValue, forKey: "permissions.reopenedFor") }
    }

    // Set while setup is unfinished; survives Quit & Reopen so the relaunch can resume.
    var resumeIsFresh: Bool {
        guard let date = store.object(forKey: "setup.resumeAt") as? Date else { return false }
        let age = Date().timeIntervalSince(date)
        return age >= 0 && age < Self.resumeWindow
    }

    func stampResume() { store.set(Date(), forKey: "setup.resumeAt") }
    func clearResume() { store.removeObject(forKey: "setup.resumeAt") }
}

enum SetupServiceState: Equatable {
    case needsModel, starting(String), ready, stopped
}

/// Removes this app's entry for one service. Runs off the main thread, 5 s at most.
func resetPermission(service: String, bundle: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
    process.arguments = ["reset", service, bundle]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning && Date() < deadline { usleep(50_000) }
    if process.isRunning {
        process.terminate()
        return false
    }
    return process.terminationStatus == 0
}

private enum PermissionRowState: Equatable {
    // coveredByAccessibility: event listening is allowed through the Accessibility grant,
    // so Input Monitoring works although its own list is empty.
    case granted, coveredByAccessibility, restricted, clearing, pending, reopening, waiting, relaunchDetected,
         oldEntry, relaunchReturned, needsAttention, off, notSetUp

    var showsSpinner: Bool { [.clearing, .pending, .reopening, .waiting].contains(self) }
    var isDone: Bool { self == .granted || self == .coveredByAccessibility }
    var isOpen: Bool { !isDone && self != .restricted }

    func status(for kind: PermissionKind) -> (word: String, note: String) {
        switch self {
        case .granted: ("Allowed", "")
        case .coveredByAccessibility: ("With Accessibility", "No switch needed")
        case .restricted: ("Managed", "By your organization")
        case .clearing: ("Clearing…", "Removing old entry")
        case .pending: ("Waiting…", "Answer the dialog")
        case .reopening: ("Reopening…", "Starting a fresh copy")
        case .waiting: ("Waiting…", "In System Settings")
        case .relaunchDetected: ("Reopen needed", "Applies after reopening")
        case .oldEntry: ("Old entry", "From an earlier build")
        case .relaunchReturned: ("Not detected", "Reopen if switched on")
        case .needsAttention: ("Not on yet", "Old entries can block it")
        case .off: ("Off", "Switch on in Settings")
        case .notSetUp: ("Not set up", kind == .microphone ? "macOS asks once" : "Touch ID or password")
        }
    }

    var statusColor: NSColor {
        switch self {
        case .oldEntry, .relaunchDetected: .systemOrange
        case .coveredByAccessibility: .secondaryLabelColor
        default: .labelColor
        }
    }

    func button(for kind: PermissionKind) -> (title: String, enabled: Bool)? {
        switch self {
        case .granted, .coveredByAccessibility, .restricted: nil
        case .clearing: ("Re-add…", false)
        case .pending: ("Allow…", false)
        case .reopening: ("Reopen", false)
        case .waiting, .off: ("Open Settings…", true)
        case .relaunchDetected, .relaunchReturned: ("Reopen", true)
        case .oldEntry: ("Re-add…", true)
        case .needsAttention: ("Try Again…", true)
        case .notSetUp: (kind == .microphone ? "Allow…" : "Open Settings…", true)
        }
    }
}

private enum PermissionMetrics {
    static let inset: CGFloat = 20
    static let badge: CGFloat = 22
    static let textX: CGFloat = 54
    static let statusWidth: CGFloat = 136
    static let actionWidth: CGFloat = 132
    static let buttonWidth: CGFloat = 124
    static let gap: CGFloat = 16
    static let headerHeight: CGFloat = 38
    static let rowHeight: CGFloat = 58
    static let cardWidth: CGFloat = 644
    static var statusTrailing: CGFloat { inset + actionWidth + gap }
}

/// Remembers when the mouse went down, so an action can be matched to the activation that
/// the same click caused (the action itself only fires on mouse-up).
private final class PressTimedButton: NSButton {
    private(set) var pressedAt: TimeInterval?

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.timestamp
        super.mouseDown(with: event)
    }

    func takePressTime() -> TimeInterval? {
        defer { pressedAt = nil }
        return pressedAt
    }
}

@MainActor
private final class PermissionSetupRow: ModelLibraryLayerView {
    let kind: PermissionKind
    let button = PressTimedButton(title: "", target: nil, action: nil)
    private let badge = ModelLibraryLayerView()
    private let badgeNumber = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let title = modelLibraryLabel(size: 13, weight: .medium)
    private let explanation = modelLibraryLabel(size: 12, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private let status = modelLibraryLabel(size: 13)
    private let note = modelLibraryLabel(size: 11, color: .tertiaryLabelColor)
    private let statusColumn = NSStackView()
    private let allowed = NSStackView()
    private var shown: (PermissionRowState, Bool)?
    /// The state the row currently displays; its button acts on this, matching its label.
    var shownState: PermissionRowState? { shown?.0 }

    init(kind: PermissionKind, separator: Bool, target: AnyObject, action: Selector) {
        self.kind = kind
        super.init(frame: .zero)
        let M = PermissionMetrics.self
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        badge.radius = M.badge / 2
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setAccessibilityElement(false)
        badgeNumber.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        badgeNumber.alignment = .center
        badgeNumber.stringValue = "\(kind.step)"
        badgeNumber.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeNumber)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)

        title.stringValue = kind.title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        explanation.stringValue = kind.explanation
        explanation.toolTip = kind.explanation
        explanation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, explanation])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        let statusLine = NSStackView(views: [spinner, status])
        statusLine.spacing = 5
        statusLine.alignment = .centerY
        statusLine.detachesHiddenViews = true
        statusColumn.setViews([statusLine, note], in: .leading)
        statusColumn.orientation = .vertical
        statusColumn.alignment = .leading
        statusColumn.spacing = 1
        statusColumn.translatesAutoresizingMaskIntoConstraints = false

        button.bezelStyle = .push
        button.target = target
        button.action = action
        button.tag = kind.rawValue
        button.translatesAutoresizingMaskIntoConstraints = false

        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill",
                                               accessibilityDescription: nil) ?? NSImage())
        check.contentTintColor = .systemGreen
        check.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        let allowedLabel = modelLibraryLabel("Allowed", size: 13, weight: .medium, color: .systemGreen)
        allowed.setViews([check, allowedLabel], in: .leading)
        allowed.spacing = 5
        allowed.alignment = .centerY
        allowed.translatesAutoresizingMaskIntoConstraints = false

        let rule = ModelLibrarySeparator()
        rule.isHidden = !separator
        for view in [rule, badge, icon, text, statusColumn, button, allowed] { addSubview(view) }
        let height = heightAnchor.constraint(equalToConstant: M.rowHeight)
        height.priority = .defaultHigh - 1
        NSLayoutConstraint.activate([
            height,
            heightAnchor.constraint(greaterThanOrEqualToConstant: M.rowHeight),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),

            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.inset),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: M.badge),
            badge.heightAnchor.constraint(equalToConstant: M.badge),
            badgeNumber.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeNumber.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.textX),
            text.trailingAnchor.constraint(lessThanOrEqualTo: statusColumn.leadingAnchor, constant: -M.gap),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),

            statusColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.statusTrailing),
            statusColumn.widthAnchor.constraint(equalToConstant: M.statusWidth),
            statusColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusColumn.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),

            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.inset),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: M.buttonWidth),
            allowed.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            allowed.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ state: PermissionRowState, highlighted: Bool, appName: String) {
        let changed = shown.map { $0.0 != state || $0.1 != highlighted } ?? true
        shown = (state, highlighted)
        guard changed else { return }

        fill = highlighted ? .modelLibraryHighlight : nil
        let done = state.isDone
        badge.isHidden = done || state == .restricted
        if highlighted {
            badge.fill = .controlAccentColor
            badge.stroke = nil
            badgeNumber.textColor = .white
            badgeNumber.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        } else {
            badge.fill = nil
            badge.stroke = .tertiaryLabelColor
            badgeNumber.textColor = .tertiaryLabelColor
            badgeNumber.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        if done {
            icon.image = kind.symbol
            icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
        } else if state == .restricted {
            icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            icon.contentTintColor = .tertiaryLabelColor
        }
        icon.isHidden = !(done || state == .restricted)

        let (word, detail) = state.status(for: kind)
        statusColumn.isHidden = state == .granted
        status.stringValue = word
        status.textColor = state.statusColor
        note.stringValue = detail
        note.isHidden = detail.isEmpty
        if state.showsSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !state.showsSpinner

        allowed.isHidden = !done
        if let action = state.button(for: kind) {
            button.isHidden = false
            button.title = action.title
            button.isEnabled = action.enabled
            button.setAccessibilityLabel(accessibilityTitle(action.title, appName: appName))
        } else {
            button.isHidden = true
        }

        setAccessibilityLabel(done
            ? "\(kind.title), allowed\(state == .coveredByAccessibility ? " through Accessibility" : ""), \(kind.explanation)"
            : "\(kind.title), step \(kind.step) of 3, \(word), \(kind.explanation)")
    }

    private func accessibilityTitle(_ title: String, appName: String) -> String {
        switch title {
        case "Allow…": "Allow \(kind.title)…"
        case "Open Settings…": "Open Settings for \(kind.title)…"
        case "Try Again…": "Try Again for \(kind.title)…"
        case "Re-add…": "Re-add \(kind.title)…"
        case "Reopen": "Reopen \(appName)"
        default: title
        }
    }
}

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

/// Floats beside System Settings while a step happens there: says what to do, offers the
/// draggable app, then confirms the grant and offers the next step without leaving Settings.
@MainActor
private final class PermissionGuidePanel: NSPanel {
    enum Content: Equatable {
        case step(PermissionKind, instruction: String, tile: Bool, extra: String?)
        case success(text: String, detail: String?, button: String, enabled: Bool)
    }

    private let headerIcon = NSImageView()
    private let header = modelLibraryLabel(size: 11, color: .secondaryLabelColor)
    private let headerRow = NSStackView()
    private let instruction = NSTextField(wrappingLabelWithString: "")
    private let tile: AppBundleDragView
    private let footnote = NSTextField(wrappingLabelWithString: "")
    private let extra = NSTextField(wrappingLabelWithString: "")
    private let finder = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let successIcon = NSImageView()
    private let successText = NSTextField(wrappingLabelWithString: "")
    private let successDetail = NSTextField(wrappingLabelWithString: "")
    private let successButton = NSButton(title: "", target: nil, action: nil)
    private let successButtonRow = NSStackView()
    private let successRow = NSStackView()
    private let stack = NSStackView()
    private(set) var content: Content?
    var onReveal: (() -> Void)?
    var onSuccess: (() -> Void)?

    static let width: CGFloat = 320

    init(appName: String) {
        tile = AppBundleDragView(appURL: Bundle.main.bundleURL, appName: appName)
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "LocalVoice Setup"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false

        headerIcon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        headerIcon.contentTintColor = .secondaryLabelColor
        headerRow.setViews([headerIcon, header], in: .leading)
        headerRow.spacing = 5
        headerRow.alignment = .centerY
        instruction.font = .systemFont(ofSize: 13, weight: .medium)
        instruction.maximumNumberOfLines = 2
        for label in [footnote, extra, successDetail] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        footnote.stringValue = "macOS may ask for Touch ID or your password. Can’t drop it? Click + under the list."
        finder.isBordered = false
        finder.font = .systemFont(ofSize: 11)
        finder.contentTintColor = .linkColor
        finder.attributedTitle = NSAttributedString(string: "Show in Finder", attributes: [
            .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 11),
        ])
        finder.target = self
        finder.action = #selector(reveal)

        successIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        successIcon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        successIcon.contentTintColor = .systemGreen
        successIcon.setAccessibilityElement(false)
        successText.font = .systemFont(ofSize: 13, weight: .medium)
        successRow.setViews([successIcon, successText], in: .leading)
        successRow.spacing = 8
        successRow.alignment = .centerY
        successButton.bezelStyle = .push
        successButton.keyEquivalent = "\r"
        successButton.target = self
        successButton.action = #selector(performSuccess)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        successButtonRow.setViews([spacer, successButton], in: .leading)

        stack.orientation = .vertical
        stack.setViews([headerRow, instruction, tile, footnote, extra, finder, successRow, successDetail,
                        successButtonRow], in: .top)
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            instruction.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tile.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tile.heightAnchor.constraint(equalToConstant: 54),
            footnote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            extra.widthAnchor.constraint(equalTo: stack.widthAnchor),
            successDetail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            successButtonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            successText.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 28 - 28),
        ])
        contentView = view
        stack.setCustomSpacing(12, after: successDetail)
        stack.setCustomSpacing(12, after: successRow)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        switch content {
        case let .step(kind, text, showsTile, extraLine):
            headerIcon.image = kind.symbol
            header.stringValue = "Step \(kind.step) of 3 · \(kind.title)"
            instruction.stringValue = text
            extra.stringValue = extraLine ?? ""
            set(step: true, tile: showsTile, extra: extraLine != nil)
            instruction.setAccessibilityLabel(text)
        case let .success(text, detail, button, enabled):
            successText.stringValue = text
            successDetail.stringValue = detail ?? ""
            successButton.title = button
            successButton.isEnabled = enabled
            set(step: false, tile: false, extra: false)
            successDetail.isHidden = detail == nil
        }
        refit()
    }

    private func set(step: Bool, tile showsTile: Bool, extra showsExtra: Bool) {
        headerRow.isHidden = !step
        instruction.isHidden = !step
        tile.isHidden = !(step && showsTile)
        footnote.isHidden = !(step && showsTile)
        finder.isHidden = !(step && showsTile)
        extra.isHidden = !(step && showsExtra)
        successRow.isHidden = step
        successDetail.isHidden = step
        successButtonRow.isHidden = step
    }

    // Keep the top edge where it is when the content changes height.
    private func refit() {
        guard let view = contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: view.fittingSize.height)
        let top = frame.maxY
        setContentSize(size)
        if isVisible { setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top)) }
        if case .success = content {
            stack.setCustomSpacing(12, after: successDetail.isHidden ? successRow : successDetail)
        }
    }

    @objc private func reveal() { onReveal?() }
    @objc private func performSuccess() { onSuccess?() }

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

/// The permission window: one card in the model library's style with a numbered row per
/// permission. The first open row is highlighted and holds the only default button; the
/// status updates live while the user is in System Settings.
@MainActor
private final class PermissionChecklist: NSWindowController, NSWindowDelegate {
    private let probe: any PermissionProbe
    private let identity: BuildIdentity
    private let ledger: PermissionLedger
    private let appName = bundleDisplayName()
    private var snapshot: PermissionSnapshot
    private var rows: [PermissionSetupRow] = []
    private let heading = modelLibraryLabel(size: 17, weight: .semibold)
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let footerTitle = modelLibraryLabel(size: 13, weight: .medium)
    private let footerNote = modelLibraryLabel(size: 12, color: .secondaryLabelColor)
    private let footerButton = NSButton(title: "", target: nil, action: nil)
    private var microphonePending = false
    private var waiting: Set<PermissionKind> = []
    private var visited: Set<PermissionKind> = []
    private var returned: Set<PermissionKind> = []
    private var clearing: Set<PermissionKind> = []
    private var resetFailed: Set<PermissionKind> = []
    private var retrying: Set<PermissionKind> = []
    private var resetCompletions: [PermissionKind: (Bool) -> Void] = [:]
    private var reopenFailed = false
    private var reopening = false
    private var activation: (time: TimeInterval, shown: [PermissionRowState?])?
    private var reopenLaunched = false
    private var successKind: PermissionKind?
    private var listenDisagreement = 0
    private var resumed = false
    private var lastGranted: Set<PermissionKind>?
    private var guide: PermissionGuidePanel?
    private var guideKind: PermissionKind?
    private var guidePlacement: Task<Void, Never>?
    private var timer: Timer?
    private var fastPolling: Bool?
    private var activity: NSObjectProtocol?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    private var lastLogged: String?
    private let log = Logger(subsystem: "com.localvoice", category: "permissions")
    private var wasReady = false
    var onReady: (() -> Void)?
    var onClose: ((Bool) -> Void)?
    var onQuit: (() -> Void)?
    var serviceState: (() -> SetupServiceState)?

    init(probe: (any PermissionProbe)? = nil, identity: BuildIdentity = .current,
         ledger: PermissionLedger = .standard) {
        let probe = probe ?? LivePermissionProbe()
        self.probe = probe
        self.identity = identity
        self.ledger = ledger
        snapshot = probe.read()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 385),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "LocalVoice Permissions"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self
        buildContent(in: window)
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

    private var buildKey: String { identity.cdhash ?? "unknown" }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        let M = PermissionMetrics.self
        heading.setAccessibilityRole(.staticText)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.maximumNumberOfLines = 2

        let card = ModelLibraryLayerView()
        card.fill = .modelLibraryCard
        card.stroke = .separatorColor
        card.radius = 12
        card.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let permissionHeader = modelLibraryLabel("Permission", size: 12, color: .secondaryLabelColor)
        let statusHeader = modelLibraryLabel("Status", size: 12, color: .secondaryLabelColor)
        header.addSubview(permissionHeader)
        header.addSubview(statusHeader)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: M.headerHeight),
            permissionHeader.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: M.textX),
            permissionHeader.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusHeader.leadingAnchor.constraint(equalTo: header.trailingAnchor,
                                                  constant: -(M.statusTrailing + M.statusWidth)),
            statusHeader.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        var cardViews: [NSView] = [header, ModelLibrarySeparator()]
        for kind in PermissionKind.allCases {
            let row = PermissionSetupRow(kind: kind, separator: kind != .microphone,
                                         target: self, action: #selector(rowAction))
            rows.append(row)
            cardViews.append(row)
        }
        cardViews.append(buildFooter())

        let cardStack = NSStackView(views: cardViews)
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        for view in cardViews { view.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: M.cardWidth),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let content = NSStackView(views: [heading, subtitle, card])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.setCustomSpacing(16, after: subtitle)
        content.translatesAutoresizingMaskIntoConstraints = false
        subtitle.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let view = NSView()
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
        ])
        window.contentView = view
    }

    private func buildFooter() -> NSView {
        let M = PermissionMetrics.self
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let rule = ModelLibrarySeparator()
        footerNote.lineBreakMode = .byWordWrapping
        footerNote.maximumNumberOfLines = 2
        footerNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerButton.bezelStyle = .push
        footerButton.target = self
        footerButton.action = #selector(dismiss)
        footerButton.translatesAutoresizingMaskIntoConstraints = false
        for view in [rule, footerTitle, footerNote, footerButton] { footer.addSubview(view) }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: footer.topAnchor),
            rule.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: M.inset),
            rule.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -M.inset),
            footerTitle.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 14),
            footerTitle.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: M.inset),
            footerNote.topAnchor.constraint(equalTo: footerTitle.bottomAnchor, constant: 3),
            footerNote.leadingAnchor.constraint(equalTo: footerTitle.leadingAnchor),
            footerNote.trailingAnchor.constraint(lessThanOrEqualTo: footerButton.leadingAnchor, constant: -M.gap),
            footerNote.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -16),
            footerButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -M.inset),
            footerButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: 1),
            footerButton.widthAnchor.constraint(equalToConstant: M.buttonWidth),
        ])
        return footer
    }

    // MARK: Presentation

    func present() {
        snapshot = probe.read()
        if snapshot.listenAccess == kIOHIDAccessTypeGranted && !snapshot.inputMonitoring && listenDisagreement == 0 {
            listenDisagreement = 1
        }
        if !snapshot.allGranted {
            if !resumed && lastGranted == nil {
                resumed = ledger.resumeIsFresh && (1...2).contains(snapshot.grantedCount)
            }
            ledger.stampResume()
        }
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

    var isPresented: Bool { previousActivationPolicy != nil }

    /// The service started, became ready, stopped or failed.
    func serviceDidChange() { refresh() }

    @objc private func applicationActivated(_ notification: Notification) {
        // If this activation came from clicking a row's button, that click should act on
        // what the row showed before the activation changed it (see rowAction).
        activation = (ProcessInfo.processInfo.systemUptime, rows.map(\.shownState))
        // Back from System Settings: a step that was visited there now counts as returned.
        for kind in waiting where visited.contains(kind) { returned.insert(kind) }
        waiting.removeAll()
        visited.removeAll()
        closeGuide()
        refresh()
    }

    @objc private func workspaceActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        if app.bundleIdentifier == PermissionGuidePanel.settingsID {
            visited.formUnion(waiting)
            if let guide, guidePlacement == nil, !guide.isVisible { placeGuideWhenSettingsOpen() }
        } else {
            guide?.orderOut(nil)
        }
        refresh()
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === guide {
            guidePlacement?.cancel()
            guidePlacement = nil
            guide = nil
            guideKind = nil
            successKind = nil
            return
        }
        closeGuide()
        stopPolling()
        if !reopenLaunched { ledger.clearResume() }
        resumed = false
        lastGranted = nil
        if let previousActivationPolicy {
            self.previousActivationPolicy = nil
            NSApp.setActivationPolicy(previousActivationPolicy)
        }
        onClose?(probe.read().allGranted)
    }

    @objc private func dismiss() { close() }

    // MARK: State

    private func isOldEntry(_ kind: PermissionKind) -> Bool {
        guard identity.isAdhoc, let cdhash = identity.cdhash, !snapshot.isGranted(kind),
              let earlier = ledger.grantedBy(kind), earlier != cdhash else { return false }
        return kind != .microphone || snapshot.microphone == .denied
    }

    private func rowState(_ kind: PermissionKind) -> PermissionRowState {
        if snapshot.isGranted(kind) {
            if kind == .inputMonitoring && snapshot.accessibility && snapshot.listenAccess != kIOHIDAccessTypeGranted {
                return .coveredByAccessibility
            }
            return .granted
        }
        if kind == .microphone && snapshot.microphone == .restricted { return .restricted }
        if clearing.contains(kind) { return .clearing }
        if kind == .microphone && microphonePending { return .pending }
        if kind == .inputMonitoring && reopening { return .reopening }
        let reopened = ledger.reopenedFor == buildKey
        if kind == .inputMonitoring && snapshot.listenAccess == kIOHIDAccessTypeGranted {
            // Switched on, but not in effect for this process yet. Never a resetting state:
            // the entry is right, it only needs a relaunch (debounced; once per build).
            if listenDisagreement >= 2 && !reopened { return .relaunchDetected }
            return waiting.contains(kind) ? .waiting : .relaunchReturned
        }
        if waiting.contains(kind) { return .waiting }
        if isOldEntry(kind) { return .oldEntry }
        let listenKnown = snapshot.listenAccess != kIOHIDAccessTypeUnknown
        if kind == .inputMonitoring && returned.contains(kind) && listenKnown && !reopened { return .relaunchReturned }
        if kind == .accessibility && returned.contains(kind) { return .needsAttention }
        if kind == .inputMonitoring && listenKnown && reopened { return .needsAttention }
        if kind == .microphone && snapshot.microphone == .denied { return .off }
        if kind == .inputMonitoring && snapshot.listenAccess == kIOHIDAccessTypeDenied { return .off }
        return .notSetUp
    }

    private func refresh() {
        guard window?.isVisible == true else { return }
        snapshot = probe.read()
        if snapshot.listenAccess == kIOHIDAccessTypeGranted && !snapshot.inputMonitoring {
            listenDisagreement += 1
        } else {
            listenDisagreement = 0
        }
        let granted = Set(PermissionKind.allCases.filter(snapshot.isGranted))
        for kind in granted {
            waiting.remove(kind)
            returned.remove(kind)
            retrying.remove(kind)
            resetFailed.remove(kind)
            if let cdhash = identity.cdhash, ledger.grantedBy(kind) != cdhash { ledger.setGrantedBy(kind, cdhash) }
        }
        let logLine = "microphone=\(snapshot.microphone.rawValue) accessibility=\(snapshot.accessibility ? "granted" : "denied") inputMonitoring=\(snapshot.inputMonitoring ? "granted" : "denied")"
        if logLine != lastLogged {
            log.notice("Permission status: \(logLine, privacy: .public)")
            lastLogged = logLine
        }

        let states = PermissionKind.allCases.map(rowState)
        let ready = snapshot.allGranted
        let highlight = PermissionKind.allCases.first { states[$0.rawValue].isOpen }
        for row in rows {
            row.update(states[row.kind.rawValue], highlighted: row.kind == highlight, appName: appName)
        }
        updateText(states: states, ready: ready, highlight: highlight)
        updateDefaultButton(ready: ready, highlight: highlight)

        if let previous = lastGranted {
            for kind in PermissionKind.allCases where granted.contains(kind) && !previous.contains(kind) {
                announce(granted: kind, states: states)
            }
        }
        lastGranted = granted
        if let kind = guideKind, case .step = guide?.content,
           snapshot.isGranted(kind) || (kind == .inputMonitoring && states[kind.rawValue] == .relaunchDetected) {
            showGuideSuccess(after: kind, states: states)
        } else if let kind = successKind, case .success = guide?.content {
            showGuideSuccess(after: kind, states: states)
        }

        let newlyReady = ready && !wasReady
        wasReady = ready
        if newlyReady { onReady?() }
        fitWindow()
        updatePolling()
    }

    private func updateText(states: [PermissionRowState], ready: Bool, highlight: PermissionKind?) {
        let service = serviceState?()
        if ready {
            heading.stringValue = service == .stopped ? "Permissions Are On" : "You’re All Set"
        } else {
            heading.stringValue = states.contains(.oldEntry) ? "Set Up LocalVoice Again" : "Set Up LocalVoice"
        }

        if let message = message(states: states) {
            subtitle.stringValue = message
            subtitle.textColor = .labelColor
        } else {
            subtitle.textColor = .secondaryLabelColor
            let done = snapshot.grantedCount
            let next = highlight?.title ?? ""
            if ready {
                subtitle.stringValue = "All three permissions are on."
            } else if states.contains(.oldEntry) {
                subtitle.stringValue = "This copy of \(appName) is new to macOS, so it needs your OK again."
            } else if done == 0 {
                subtitle.stringValue = "Allow three things in macOS, one at a time. Nothing is asked until you click."
            } else {
                subtitle.stringValue = "\(resumed ? "Welcome back. " : "")\(done) of 3 done. Next: \(next)."
            }
        }

        if ready {
            switch service {
            case .needsModel:
                footer("One more step", "Choose a speech model. It runs on this Mac.", "Choose Model…")
            case let .starting(model):
                footer("Starting dictation", "Loading \(model)…", "Done")
            case .ready:
                let menuBar = ["on", "true", "1", "yes"].contains(readConfigValue("menubar")?.lowercased() ?? "on")
                footer("Ready to dictate", "Tap \(hotkeyDescription()) in any app to start."
                       + (menuBar ? " Settings are under the LocalVoice icon in the menu bar." : ""), "Done")
            case .stopped:
                footer("Dictation didn’t start", "Open Models to try again or choose another model.", "Done")
            case nil:
                footer("Permissions are on", "You can close this window.", "Done")
            }
        } else {
            footer("Dictation stays on this Mac",
                   identity.isAdhoc ? "Test builds of LocalVoice need these again after each rebuild."
                                    : "Change these anytime in System Settings › Privacy & Security.",
                   states[PermissionKind.microphone.rawValue] == .restricted ? "Close" : "Set Up Later")
        }
    }

    private func footer(_ title: String, _ note: String, _ button: String) {
        footerTitle.stringValue = title
        footerNote.stringValue = note
        footerButton.title = button
    }

    private func message(states: [PermissionRowState]) -> String? {
        let im = states[PermissionKind.inputMonitoring.rawValue]
        let ax = states[PermissionKind.accessibility.rawValue]
        if !resetFailed.isEmpty {
            return "Couldn’t remove the old entry. In System Settings, select \(appName), click −, then add it again."
        }
        if reopenFailed { return "Couldn’t reopen \(appName). Quit it from the menu bar and open it again." }
        if states[PermissionKind.microphone.rawValue] == .restricted {
            return "Your organization manages the microphone on this Mac, so \(appName) can’t dictate."
        }
        if states.contains(.clearing) { return "Removing the entry an earlier build left behind…" }
        if states.contains(.pending) { return "Choose Allow in the macOS dialog." }
        if states.contains(.waiting) { return "Waiting for you in System Settings. This window updates by itself." }
        if im == .relaunchDetected { return "Input Monitoring is on. Reopen \(appName) so it can use it." }
        if im == .relaunchReturned { return "Switched on \(appName) under Input Monitoring? Reopen to apply it." }
        if ax == .needsAttention {
            return identity.isAdhoc
                ? "Accessibility isn’t on yet. Try Again removes an old entry, then add \(appName) once more."
                : "Accessibility isn’t on yet. Add \(appName) to the list and switch it on."
        }
        if im == .needsAttention {
            return identity.isAdhoc
                ? "Input Monitoring is still off. Try Again removes an old entry, then add \(appName) once more."
                : "Input Monitoring is still off. Add \(appName) to the list and switch it on."
        }
        return nil
    }

    // Exactly one default button: the highlighted row's, or Done once everything is on.
    private func updateDefaultButton(ready: Bool, highlight: PermissionKind?) {
        for row in rows { row.button.keyEquivalent = "" }
        if ready {
            footerButton.keyEquivalent = "\r"
            return
        }
        footerButton.keyEquivalent = "\u{1b}"
        guard !microphonePending, clearing.isEmpty, let highlight else { return }
        let button = rows[highlight.rawValue].button
        if !button.isHidden && button.isEnabled { button.keyEquivalent = "\r" }
    }

    private func announce(granted kind: PermissionKind, states: [PermissionRowState]) {
        let next = PermissionKind.allCases.first { states[$0.rawValue].isOpen }
        let text = next.map { "\(kind.title) allowed. Next: \($0.title)." } ?? "All permissions are on."
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func fitWindow() {
        guard let window, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        guard abs(height - view.frame.height) > 0.5 else { return }
        var frame = window.frame
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 700, height: height))
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        let animate = window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: animate)
    }

    // MARK: Live status

    private func updatePolling() {
        guard window?.isVisible == true else { stopPolling(); return }
        let settingsFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == PermissionGuidePanel.settingsID
        let fast = !waiting.isEmpty || microphonePending || !clearing.isEmpty || settingsFront
            || guide?.isVisible == true
        if fast != fastPolling || timer == nil {
            timer?.invalidate()
            let timer = Timer(timeInterval: fast ? 0.5 : 2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            fastPolling = fast
        }
        // A background app behind System Settings would otherwise be throttled by App Nap.
        if fast && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching for permission changes")
        } else if !fast, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        fastPolling = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: Actions

    @objc private func rowAction(_ sender: NSButton) {
        guard let kind = PermissionKind(rawValue: sender.tag) else { return }
        let row = rows[kind.rawValue]
        var state = row.shownState
        // The click that brought LocalVoice forward was pressed on the label shown before
        // activation; act on that, not on what the activation refresh turned it into.
        // That click is pressed just before the activation it causes; a click pressed after
        // the activation was made on the refreshed label.
        if let pressed = row.button.takePressTime(), let activation,
           pressed - activation.time < 0.1, activation.time - pressed < 0.5,
           let before = activation.shown[kind.rawValue] {
            state = before
        }
        perform(for: kind, as: state)
    }

    private func perform(for kind: PermissionKind, as shownState: PermissionRowState? = nil) {
        snapshot = probe.read()
        reopenFailed = false
        let current = rowState(kind)
        // Act on the label the user saw. If it no longer applies (granted meanwhile), do nothing.
        let state = shownState ?? current
        if current.isDone || current == .restricted { refresh(); return }
        switch state {
        case .notSetUp where kind == .microphone:
            requestMicrophone()
        case .notSetUp, .off, .waiting:
            openSettings(kind)
        case .needsAttention:
            if identity.isAdhoc {
                reset(kind) { [weak self] _ in
                    self?.retrying.insert(kind)
                    self?.openSettings(kind)
                }
            } else {
                openSettings(kind)
            }
        case .oldEntry:
            reset(kind) { [weak self] success in
                guard let self else { return }
                if kind == .microphone {
                    if success && microphoneState() == .undetermined { self.requestMicrophone() }
                    else { self.openSettings(kind) }
                } else {
                    self.retrying.insert(kind)
                    self.openSettings(kind)
                }
            }
        case .relaunchDetected, .relaunchReturned:
            reopen()
        case .granted, .coveredByAccessibility, .restricted, .clearing, .pending, .reopening:
            break
        }
        refresh()
    }

    private func requestMicrophone() {
        guard window?.isVisible == true, !microphonePending, microphoneState() == .undetermined else { return }
        microphonePending = true
        Task { @MainActor [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            self?.microphoneRequestFinished()
        }
    }

    private func microphoneRequestFinished() {
        microphonePending = false
        // Don't reopen a dismissed checklist or steal focus from another app.
        guard let window, window.isVisible else { return }
        if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
        refresh()
    }

    private func openSettings(_ kind: PermissionKind) {
        ledger.stampResume()
        waiting.insert(kind)
        returned.remove(kind)
        visited.remove(kind)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == PermissionGuidePanel.settingsID {
            visited.insert(kind)
        }
        showGuide(for: kind)
        openPrivacyPane(kind.pane)
        placeGuideWhenSettingsOpen()
        refresh()
    }

    private func reset(_ kind: PermissionKind, then completion: @escaping (Bool) -> Void) {
        ledger.stampResume()
        let current = probe.read()
        guard identity.isAdhoc, !current.isGranted(kind), let bundle = Bundle.main.bundleIdentifier,
              !(kind == .inputMonitoring && current.listenAccess == kIOHIDAccessTypeGranted),
              resetCompletions[kind] == nil else {
            completion(false)
            return
        }
        clearing.insert(kind)
        resetFailed.remove(kind)
        resetCompletions[kind] = completion
        let service = kind.tccService
        Task.detached {
            let exited = resetPermission(service: service, bundle: bundle)
            await MainActor.run { [weak self] in self?.resetFinished(kind, exited: exited) }
        }
        refresh()
    }

    private func resetFinished(_ kind: PermissionKind, exited: Bool) {
        clearing.remove(kind)
        snapshot = probe.read()
        let cleared: Bool
        switch kind {
        case .microphone: cleared = snapshot.microphone == .undetermined
        case .accessibility: cleared = true
        case .inputMonitoring: cleared = snapshot.listenAccess == kIOHIDAccessTypeUnknown
        }
        let success = exited && cleared
        if success { ledger.setGrantedBy(kind, nil) } else { resetFailed.insert(kind) }
        let completion = resetCompletions.removeValue(forKey: kind)
        // Setup was dismissed meanwhile: don't reopen Settings or prompt.
        guard window?.isVisible == true else { return }
        completion?(success)
        refresh()
    }

    private func reopen() {
        guard !reopening else { return }
        reopening = true
        reopenFailed = false
        ledger.stampResume()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] app, error in
            let launched = error == nil && (app?.processIdentifier ?? -1) > 0
            Task { @MainActor [weak self] in self?.reopenFinished(launched) }
        }
        refresh()
    }

    private func reopenFinished(_ launched: Bool) {
        if launched {
            // Only now: the new copy exists and will read this as "already reopened once".
            // Stay in Reopening… until this copy exits (it may still be stopping its service),
            // and keep the stamp fresh: the new copy waits for our lock only while it is.
            reopenLaunched = true
            ledger.reopenedFor = buildKey
            ledger.stampResume()
            closeGuide()
            window?.orderOut(nil)
            onQuit?()
        } else {
            reopening = false
            reopenFailed = true
            refresh()
        }
    }

    // MARK: Guide panel

    private func guideInstruction(for kind: PermissionKind) -> (text: String, tile: Bool) {
        if kind == .microphone { return ("Switch on \(appName) in the list.", false) }
        if resetFailed.contains(kind) { return ("Select the old \(appName), click −, then drag this one in.", true) }
        if retrying.contains(kind) { return ("Drag \(appName) into the list again, then switch it on.", true) }
        if kind == .inputMonitoring && snapshot.listenAccess == kIOHIDAccessTypeDenied {
            return ("Find \(appName) in the list and switch it on. Not there? Drag it in.", true)
        }
        return ("Drag \(appName) into the list, then make sure its switch is on.", true)
    }

    private func showGuide(for kind: PermissionKind) {
        let panel: PermissionGuidePanel
        if let guide {
            panel = guide
        } else {
            panel = PermissionGuidePanel(appName: appName)
            panel.delegate = self
            panel.onReveal = { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            guide = panel
        }
        guideKind = kind
        panel.onSuccess = nil
        successKind = nil
        let (text, tile) = guideInstruction(for: kind)
        panel.show(.step(kind, instruction: text, tile: tile,
                         extra: kind == .inputMonitoring ? "If macOS offers Quit & Reopen, choose it." : nil))
    }

    private func showGuideSuccess(after kind: PermissionKind, states: [PermissionRowState]) {
        guard let guide else { return }
        let imState = states[PermissionKind.inputMonitoring.rawValue]
        let needsRelaunch = kind == .inputMonitoring && [.relaunchDetected, .reopening].contains(imState)
        // Switched off again: back to the step's instructions.
        guard snapshot.isGranted(kind) || needsRelaunch else {
            showGuide(for: kind)
            return
        }
        guideKind = nil
        successKind = kind
        let done = "\(kind.title) is on."
        let open = PermissionKind.allCases.filter { $0 != kind && states[$0.rawValue].isOpen }
        if needsRelaunch && open.isEmpty {
            let busy = imState == .reopening
            guide.show(.success(text: "Input Monitoring is on.", detail: "\(appName) needs to reopen to use it.",
                                button: busy ? "Reopening…" : "Reopen \(appName)", enabled: !busy))
            guide.onSuccess = { [weak self] in self?.reopen() }
            return
        }
        guard let next = open.first else {
            guide.show(.success(text: "All set. \(appName) is ready.", detail: nil, button: "Back to \(appName)",
                                enabled: true))
            guide.onSuccess = { [weak self] in self?.backToApp() }
            return
        }
        if next == .microphone && snapshot.microphone == .undetermined {
            // The microphone dialog is better asked from the window.
            guide.show(.success(text: done, detail: nil, button: "Back to \(appName)", enabled: true))
            guide.onSuccess = { [weak self] in self?.backToApp() }
            return
        }
        let nextState = states[next.rawValue]
        let title: String
        switch nextState {
        case .relaunchDetected, .relaunchReturned, .reopening: title = "Reopen \(appName)"
        case .needsAttention: title = "Try Again for \(next.title)…"
        case .oldEntry: title = "Re-add \(next.title)…"
        default: title = "Next: \(next.title)"
        }
        let enabled = ![.clearing, .pending, .reopening].contains(nextState)
        guide.show(.success(text: done, detail: nil, button: title, enabled: enabled))
        guide.onSuccess = { [weak self] in
            guard let self else { return }
            switch nextState {
            case .notSetUp, .off, .waiting: self.openSettings(next)
            default: self.perform(for: next, as: nextState)
            }
        }
    }

    private func backToApp() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        closeGuide()
    }

    private func closeGuide() {
        guidePlacement?.cancel()
        guidePlacement = nil
        guide?.close()
    }

    private func placeGuideWhenSettingsOpen() {
        guard let guide else { return }
        guidePlacement?.cancel()
        guidePlacement = Task { @MainActor [weak self, weak guide] in
            // A new Settings window may not exist yet when we open the pane.
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let guide else { return }
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == PermissionGuidePanel.settingsID,
                   let frame = PermissionGuidePanel.settingsFrame() {
                    guide.place(beside: frame)
                    guide.orderFrontRegardless()
                    self.guidePlacement = nil
                    return
                }
            }
            guard let self, let guide else { return }
            self.guidePlacement = nil
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == PermissionGuidePanel.settingsID {
                if let frame = self.window?.frame { guide.place(beside: frame) }
                guide.orderFrontRegardless()
            }
        }
    }

#if PERMISSIONS_PREVIEW
    /// Puts the window into one of the states the preview renders.
    func previewConfigure(_ scenario: String) {
        switch scenario {
        case "waiting": waiting = [.accessibility]
        case "attention": returned = [.accessibility]
        case "relaunch": listenDisagreement = 1
        case "resumed": resumed = true
        default: break
        }
    }

    func previewGuide(_ scenario: String) -> NSWindow? {
        switch scenario {
        case "panel":
            showGuide(for: .accessibility)
        case "panel-success":
            showGuide(for: .accessibility)
            showGuideSuccess(after: .accessibility, states: PermissionKind.allCases.map(rowState))
        default:
            return nil
        }
        if let guide, let frame = window?.frame { guide.place(beside: frame) }
        guide?.orderFrontRegardless()
        return guide
    }
#endif
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
    // The relaunched copy runs as the normal managed service.
    checklist.onQuit = {
        writeSetupStatus("deferred", managed: true)
        exit(1)
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
    // Swift treats "\r\n" as one Character, so split on newline scalars.
    for line in raw.components(separatedBy: .newlines) {
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
    // Follow a symlinked config (dotfiles) so the atomic write updates the
    // target instead of replacing the link with a regular file.
    let path = (localVoiceConfigPath() as NSString).resolvingSymlinksInPath
    let raw: String
    do {
        raw = try String(contentsOfFile: path, encoding: .utf8)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        raw = ""
    } catch {
        return false
    }
    // Keep the file's own line endings; edit on normalized lines.
    let newline = raw.contains("\r\n") ? "\r\n" : "\n"
    var lines = raw.isEmpty ? [] : raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

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
        try lines.joined(separator: newline).write(toFile: path, atomically: true, encoding: .utf8)
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

// MARK: - Ready screen

/// The configured hotkey as a keycap: symbol, key name and tap count (default Control ×3).
func hotkeyKeycap() -> (symbol: String, name: String, taps: Int) {
    let parts = (readConfigValue("hotkey") ?? "ctrl,3").lowercased().split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
    let keys = ["ctrl": ("⌃", "control"), "cmd": ("⌘", "command"), "alt": ("⌥", "option"), "shift": ("⇧", "shift")]
    guard parts.count == 2, let key = keys[parts[0]], let taps = Int(parts[1]), (2...4).contains(taps) else {
        return ("⌃", "control", 3)
    }
    return (key.0, key.1, taps)
}

/// A keycap drawn with layers: face, accent glow for presses, label, optional key name, ripple.
@MainActor
private final class KeycapLayers {
    let base = CALayer()
    let glow = CALayer()
    let symbol = CATextLayer()
    let name = CATextLayer()
    let ripple = CALayer()
    private let hasName: Bool

    init(symbol text: String, name keyName: String?, symbolSize: CGFloat) {
        hasName = keyName != nil
        for layer in [base, glow] {
            layer.cornerRadius = 14
            layer.cornerCurve = .continuous
        }
        base.borderWidth = 1
        base.shadowOpacity = 0.18
        base.shadowRadius = 5
        base.shadowOffset = CGSize(width: 0, height: -2)
        glow.opacity = 0
        for label in [symbol, name] {
            label.alignmentMode = .center
            label.contentsScale = 2
        }
        symbol.string = text
        symbol.font = NSFont.systemFont(ofSize: symbolSize, weight: .regular)
        symbol.fontSize = symbolSize
        name.string = keyName ?? ""
        name.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        name.fontSize = 10
        ripple.cornerRadius = 18
        ripple.cornerCurve = .continuous
        ripple.borderWidth = 2
        ripple.opacity = 0
        base.addSublayer(glow)
        base.addSublayer(symbol)
        if hasName { base.addSublayer(name) }
    }

    func layout(center: CGPoint, size: CGFloat) {
        base.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        base.position = center
        glow.frame = base.bounds
        let symbolHeight = (symbol.fontSize * 1.25).rounded()
        if hasName {
            symbol.frame = CGRect(x: 0, y: size / 2 - 8, width: size, height: symbolHeight)
            name.frame = CGRect(x: 0, y: 9, width: size, height: 14)
        } else {
            symbol.frame = CGRect(x: 0, y: (size - symbolHeight) / 2 + 1, width: size, height: symbolHeight)
        }
        ripple.bounds = CGRect(x: 0, y: 0, width: size + 8, height: size + 8)
        ripple.position = center
    }

    func applyColors(dark: Bool) {
        base.backgroundColor = (dark ? NSColor(white: 0.24, alpha: 1) : NSColor.white).cgColor
        base.borderColor = NSColor.separatorColor.cgColor
        base.shadowColor = NSColor.black.cgColor
        glow.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.35 : 0.18).cgColor
        symbol.foregroundColor = NSColor.labelColor.cgColor
        name.foregroundColor = NSColor.secondaryLabelColor.cgColor
        ripple.borderColor = NSColor.controlAccentColor.cgColor
    }

    func setScale(_ scale: CGFloat) {
        for layer in [symbol, name] { layer.contentsScale = scale }
    }
}

/// A looping scene of the whole cycle. Insert: tap the hotkey, speak (the pill shows a
/// waveform), tap it again, and the text types itself into a field. Discard: tap, speak,
/// press Esc, and the pill shakes and goes away. Captions name each step. Under Reduce
/// Motion it is a single still that shows everything at once.
@MainActor
private final class ReadyIllustrationView: NSView {
    private let keycap = hotkeyKeycap()
    private let hotkey = hotkeyDescription()
    private let still: Bool
    private let modifier: KeycapLayers
    private let escape = KeycapLayers(symbol: "esc", name: nil, symbolSize: 13)
    private let badge = CALayer()
    private let badgeText = CATextLayer()
    private let arrow = CAShapeLayer()
    private let pill = CALayer()
    private let dot = CALayer()
    private var bars: [CALayer] = []
    private let field = CALayer()
    private let fieldText = CATextLayer()
    private let fieldMask = CALayer()
    private let caret = CALayer()
    private var captions: [CATextLayer] = []
    private var animating = false

    static let size = NSSize(width: 464, height: 196)
    private static let insertedText = "See you on Friday at ten."
    private static let fieldFont = NSFont.systemFont(ofSize: 12)

    init(still: Bool) {
        self.still = still
        modifier = KeycapLayers(symbol: keycap.symbol, name: keycap.name, symbolSize: 30)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Animation: tap \(hotkey) to start, speak, tap \(hotkey) again to insert the text. "
                              + "Esc discards the recording.")
        guard let root = layer else { return }

        badge.cornerRadius = 11
        badgeText.string = "\(keycap.taps)×"
        badgeText.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        badgeText.fontSize = 12
        badgeText.alignmentMode = .center
        badge.addSublayer(badgeText)
        badge.isHidden = !still

        arrow.fillColor = nil
        arrow.lineWidth = 2
        arrow.lineCap = .round
        arrow.lineJoin = .round

        pill.cornerRadius = 20
        pill.borderWidth = 1
        pill.shadowOpacity = 0.25
        pill.shadowRadius = 8
        pill.shadowOffset = CGSize(width: 0, height: -3)
        dot.cornerRadius = 4
        pill.addSublayer(dot)
        for _ in 0..<9 {
            let bar = CALayer()
            bar.cornerRadius = 1.5
            bars.append(bar)
            pill.addSublayer(bar)
        }

        field.cornerRadius = 7
        field.cornerCurve = .continuous
        field.borderWidth = 1
        fieldText.string = Self.insertedText
        fieldText.font = Self.fieldFont
        fieldText.fontSize = 12
        fieldText.alignmentMode = .left
        fieldMask.backgroundColor = NSColor.black.cgColor
        fieldMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        fieldText.mask = fieldMask
        field.addSublayer(fieldText)
        caret.cornerRadius = 0.75
        field.addSublayer(caret)

        let captionTexts = still
            ? ["Tap \(hotkey) to start, again to insert. Esc discards."]
            : ["Tap \(hotkey) to start", "Speak…", "Tap \(hotkey) again to insert",
               "The text appears where you type", "Esc discards the recording"]
        for text in captionTexts {
            let caption = CATextLayer()
            caption.string = text
            caption.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            caption.fontSize = 12
            caption.alignmentMode = .center
            caption.opacity = still ? 1 : 0
            captions.append(caption)
        }

        for sublayer in [modifier.ripple, escape.ripple, modifier.base, escape.base, badge, arrow, field, pill]
            + captions { root.addSublayer(sublayer) }
        if still {
            pill.opacity = 1
            caret.opacity = 0
        } else {
            pill.opacity = 0
            fieldText.opacity = 0
            caret.opacity = 0
        }
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { Self.size }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        modifier.setScale(scale)
        escape.setScale(scale)
        for text in [badgeText, fieldText] + captions { text.contentsScale = scale }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            modifier.applyColors(dark: dark)
            escape.applyColors(dark: dark)
            badge.backgroundColor = NSColor.controlAccentColor.cgColor
            badgeText.foregroundColor = NSColor.white.cgColor
            arrow.strokeColor = NSColor.tertiaryLabelColor.cgColor
            pill.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
            pill.borderColor = NSColor(white: 1, alpha: dark ? 0.16 : 0.08).cgColor
            pill.shadowColor = NSColor.black.cgColor
            dot.backgroundColor = NSColor.systemRed.cgColor
            for bar in bars { bar.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor }
            field.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor.white).cgColor
            field.borderColor = NSColor.separatorColor.cgColor
            fieldText.foregroundColor = NSColor.labelColor.cgColor
            caret.backgroundColor = NSColor.controlAccentColor.cgColor
            for caption in captions { caption.foregroundColor = NSColor.secondaryLabelColor.cgColor }
        }
    }

    // Layer geometry is bottom-up (the view is not flipped).
    private struct Geometry {
        let keysLeft: CGFloat, rowY: CGFloat, columnX: CGFloat, fieldY: CGFloat
        let modifierSize: CGFloat = 70, escapeSize: CGFloat = 46, pill = CGSize(width: 136, height: 40)
        let field = CGSize(width: 204, height: 30)
    }

    private var geometry: Geometry {
        let keysWidth: CGFloat = 46 + 10 + 70, gap: CGFloat = 42, column: CGFloat = 204
        let left = (bounds.width - keysWidth - gap - column) / 2
        return Geometry(keysLeft: left, rowY: 130, columnX: left + keysWidth + gap + column / 2, fieldY: 80)
    }

    private var textWidth: CGFloat {
        ceil((Self.insertedText as NSString).size(withAttributes: [.font: Self.fieldFont]).width)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let g = geometry
        escape.layout(center: CGPoint(x: g.keysLeft + g.escapeSize / 2, y: g.rowY), size: g.escapeSize)
        let modifierCenter = CGPoint(x: g.keysLeft + g.escapeSize + 10 + g.modifierSize / 2, y: g.rowY)
        modifier.layout(center: modifierCenter, size: g.modifierSize)
        badge.bounds = CGRect(x: 0, y: 0, width: 30, height: 22)
        badge.position = CGPoint(x: modifierCenter.x + g.modifierSize / 2 - 4, y: g.rowY + g.modifierSize / 2 - 4)
        badgeText.frame = CGRect(x: 0, y: 3, width: 30, height: 16)

        let arrowStart = modifierCenter.x + g.modifierSize / 2 + 10
        let arrowEnd = g.columnX - g.pill.width / 2 - 10
        let path = CGMutablePath()
        path.move(to: CGPoint(x: arrowStart, y: g.rowY))
        path.addLine(to: CGPoint(x: arrowEnd, y: g.rowY))
        path.move(to: CGPoint(x: arrowEnd - 5, y: g.rowY + 5))
        path.addLine(to: CGPoint(x: arrowEnd, y: g.rowY))
        path.addLine(to: CGPoint(x: arrowEnd - 5, y: g.rowY - 5))
        arrow.path = path

        pill.bounds = CGRect(origin: .zero, size: g.pill)
        pill.position = CGPoint(x: g.columnX, y: g.rowY)
        dot.frame = CGRect(x: 16, y: g.pill.height / 2 - 4, width: 8, height: 8)
        for (index, bar) in bars.enumerated() {
            let height = still ? [10, 18, 26, 16, 22, 12, 20, 14, 8][index] : 22
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: CGFloat(height))
            bar.position = CGPoint(x: 38 + CGFloat(index) * 9.5, y: g.pill.height / 2)
        }

        field.bounds = CGRect(origin: .zero, size: g.field)
        field.position = CGPoint(x: g.columnX, y: g.fieldY)
        fieldText.frame = CGRect(x: 10, y: (g.field.height - 16) / 2, width: g.field.width - 20, height: 16)
        fieldMask.bounds = CGRect(x: 0, y: 0, width: still ? textWidth : 0, height: 16)
        fieldMask.position = CGPoint(x: 0, y: 8)
        caret.frame = CGRect(x: 10 + textWidth + 1, y: (g.field.height - 16) / 2, width: 1.5, height: 16)

        for caption in captions { caption.frame = CGRect(x: 0, y: 14, width: bounds.width, height: 16) }
        CATransaction.commit()
        if !still && !animating && window != nil { startAnimating() }
    }

    // Loop length, set from the timeline (it grows with the hotkey's tap count).
    private var loop = 11.4

    /// A keyframe track in seconds; holds its first and last value to the loop's ends.
    private func track(_ path: String, _ points: [(Double, Any)]) -> CAKeyframeAnimation {
        let d = loop
        var points = points
        if let first = points.first, first.0 > 0 { points.insert((0, first.1), at: 0) }
        if let last = points.last, last.0 < d { points.append((d, last.1)) }
        let animation = CAKeyframeAnimation(keyPath: path)
        animation.keyTimes = points.map { NSNumber(value: min(max($0.0 / d, 0), 1)) }
        animation.values = points.map(\.1)
        animation.duration = d
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        return animation
    }

    private func press(_ key: KeycapLayers, at times: [Double]) {
        var scale: [(Double, Any)] = [(0, 1.0)], glow: [(Double, Any)] = [(0, 0.0)]
        var rippleScale: [(Double, Any)] = [(0, 1.0)], rippleOpacity: [(Double, Any)] = [(0, 0.0)]
        for t in times {
            scale += [(t, 1.0), (t + 0.08, 0.9), (t + 0.2, 1.0)]
            glow += [(t, 0.0), (t + 0.06, 1.0), (t + 0.26, 0.0)]
            rippleScale += [(t + 0.05, 1.0), (t + 0.06, 1.0), (t + 0.34, 1.35)]
            rippleOpacity += [(t + 0.05, 0.0), (t + 0.06, 0.7), (t + 0.34, 0.0)]
        }
        key.base.add(track("transform.scale", scale), forKey: "press")
        key.glow.add(track("opacity", glow), forKey: "glow")
        let ripple = CAAnimationGroup()
        ripple.animations = [track("transform.scale", rippleScale), track("opacity", rippleOpacity)]
        ripple.duration = loop
        ripple.repeatCount = .infinity
        key.ripple.add(ripple, forKey: "ripple")
    }

    private func fade(_ layer: CALayer, visible spans: [(Double, Double)], key: String) {
        var points: [(Double, Any)] = [(0, 0.0)]
        for (start, end) in spans {
            points += [(start, 0.0), (start + 0.15, 1.0), (end - 0.15, 1.0), (end, 0.0)]
        }
        layer.add(track("opacity", points), forKey: key)
    }

    // Timeline: insert (tap, speak, tap, text types in), then discard (tap, speak, Esc), rest.
    private func startAnimating() {
        animating = true
        let taps = keycap.taps, step = 0.34
        func tapTimes(_ start: Double) -> [Double] { (0..<taps).map { start + Double($0) * step } }
        let startA = 0.5
        let pillInA = startA + Double(taps) * step + 0.1
        let stopA = pillInA + 0.3 + 1.7
        let pillOutA = stopA + Double(taps) * step + 0.05
        let typeStart = pillOutA + 0.25, typeEnd = typeStart + 0.8, textOut = typeEnd + 1.05
        let startB = textOut + 0.35
        let pillInB = startB + Double(taps) * step + 0.1
        let escapeAt = pillInB + 0.3 + 1.5
        let pillOutB = escapeAt + 0.45
        loop = pillOutB + 1.4

        press(modifier, at: tapTimes(startA) + tapTimes(stopA) + tapTimes(startB))
        press(escape, at: [escapeAt])

        let pillGroup = CAAnimationGroup()
        pillGroup.animations = [
            track("opacity", [(pillInA, 0.0), (pillInA + 0.3, 1.0), (pillOutA, 1.0), (pillOutA + 0.25, 0.0),
                              (pillInB, 0.0), (pillInB + 0.3, 1.0), (pillOutB, 1.0), (pillOutB + 0.3, 0.0)]),
            track("transform.scale", [(pillInA, 0.85), (pillInA + 0.3, 1.0), (pillOutA, 1.0), (pillOutA + 0.25, 0.9),
                                      (pillInB, 0.85), (pillInB + 0.3, 1.0), (pillOutB, 1.0), (pillOutB + 0.3, 0.8)]),
            // Esc: a short shake before the discarded pill leaves.
            track("transform.translation.x", [(escapeAt + 0.05, 0.0), (escapeAt + 0.12, -8.0), (escapeAt + 0.19, 8.0),
                                              (escapeAt + 0.26, -6.0), (escapeAt + 0.33, 5.0), (escapeAt + 0.4, 0.0)]),
        ]
        pillGroup.duration = loop
        pillGroup.repeatCount = .infinity
        pill.add(pillGroup, forKey: "pill")
        arrow.opacity = 0
        arrow.add(track("opacity", [(pillInA - 0.1, 0.0), (pillInA + 0.2, 1.0), (pillOutA, 1.0), (pillOutA + 0.25, 0.0),
                                    (pillInB - 0.1, 0.0), (pillInB + 0.2, 1.0), (pillOutB, 1.0), (pillOutB + 0.3, 0.0)]),
                  forKey: "arrow")

        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0.35
        blink.duration = 0.6
        blink.autoreverses = true
        blink.repeatCount = .infinity
        dot.add(blink, forKey: "blink")
        // Each bar moves on its own short cycle, so the waveform never visibly repeats.
        for (index, bar) in bars.enumerated() {
            let wave = CAKeyframeAnimation(keyPath: "transform.scale.y")
            let pattern: [CGFloat] = [0.35, 1, 0.55, 0.85, 0.4, 0.95, 0.5]
            wave.values = (0..<pattern.count).map { pattern[($0 + index * 3) % pattern.count] }
            wave.duration = 0.9 + Double(index % 4) * 0.13
            wave.repeatCount = .infinity
            wave.autoreverses = true
            wave.calculationMode = .cubic
            bar.add(wave, forKey: "wave")
        }

        // The text types itself into the field after the second tap, then clears for the next round.
        let width = textWidth
        fieldText.add(track("opacity", [(typeStart - 0.05, 0.0), (typeStart, 1.0), (textOut - 0.3, 1.0), (textOut, 0.0)]),
                      forKey: "text")
        fieldMask.add(track("bounds.size.width", [(typeStart, 0.0), (typeEnd, Double(width)), (textOut, Double(width)),
                                                  (textOut + 0.01, 0.0)]), forKey: "type")
        let caretX = caret.position.x
        caret.add(track("opacity", [(typeStart - 0.05, 0.0), (typeStart, 1.0), (textOut - 0.3, 1.0), (textOut, 0.0)]),
                  forKey: "caret")
        caret.add(track("position.x", [(typeStart, Double(caretX - width - 1)), (typeEnd, Double(caretX)),
                                       (textOut, Double(caretX)), (textOut + 0.01, Double(caretX - width - 1))]),
                  forKey: "caretMove")

        // Captions, in order: start, speak, insert, result, discard.
        guard captions.count == 5 else { return }
        fade(captions[0], visible: [(startA - 0.25, pillInA + 0.1), (startB - 0.25, pillInB + 0.1)], key: "c0")
        fade(captions[1], visible: [(pillInA + 0.2, stopA - 0.05), (pillInB + 0.2, escapeAt - 0.05)], key: "c1")
        fade(captions[2], visible: [(stopA - 0.05, pillOutA + 0.15)], key: "c2")
        fade(captions[3], visible: [(typeStart - 0.05, textOut + 0.1)], key: "c3")
        fade(captions[4], visible: [(escapeAt - 0.05, pillOutB + 0.6)], key: "c4")
    }
}

@MainActor
private func localVoiceTemplateIcon() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
        let unit = min(rect.width, rect.height) / 22
        let width = 4 * unit
        NSColor.black.setFill()
        for (index, height) in ([6, 18, 10] as [CGFloat]).enumerated() {
            let centerX = rect.midX + CGFloat(index - 1) * 6 * unit
            let bar = NSRect(x: centerX - width / 2, y: rect.midY - height * unit / 2,
                             width: width, height: height * unit)
            NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}

/// Shown once, when the first model is ready after setup: shows the gesture, says how to
/// insert or discard, and where Settings live.
@MainActor
private final class ReadyWindowController: NSWindowController, NSWindowDelegate {
    var onSettings: (() -> Void)?
    var onClose: (() -> Void)?
    // Offered once, pre-checked and visible, applied when the window closes.
    private let loginToggle = NSButton(checkboxWithTitle: "Open LocalVoice when I log in", target: nil, action: nil)

    init(modelName: String?, menuBar: Bool, still: Bool? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "LocalVoice"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self

        let reduceMotion = still ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scene = ModelLibraryLayerView()
        scene.fill = .modelLibraryCard
        scene.stroke = .separatorColor
        scene.radius = 14
        scene.translatesAutoresizingMaskIntoConstraints = false
        let illustration = ReadyIllustrationView(still: reduceMotion)
        scene.addSubview(illustration)

        let title = modelLibraryLabel("You’re Ready to Dictate", size: 22, weight: .semibold)
        title.alignment = .center
        let subtitle = modelLibraryLabel(
            modelName.map { "\($0) is loaded and runs entirely on this Mac." } ?? "Your speech model runs entirely on this Mac.",
            size: 13, color: .secondaryLabelColor)
        subtitle.alignment = .center

        let hotkey = hotkeyDescription()
        let steps = NSStackView(views: [
            Self.step("keyboard", "Tap **\(hotkey)** in any app to start."),
            Self.step("return", "Tap again or press **Return** to insert the text. **Esc** discards."),
            Self.step(menuBar ? localVoiceTemplateIcon() : Self.stepSymbol("gearshape"),
                      menuBar ? "Models and **Settings** are under this icon in the menu bar."
                              : "Open LocalVoice again to change models or **Settings**."),
        ])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 12
        steps.translatesAutoresizingMaskIntoConstraints = false

        let settings = NSButton(title: "Open Settings…", target: self, action: #selector(openSettings))
        settings.bezelStyle = .push
        let start = NSButton(title: "Start Dictating", target: self, action: #selector(finish))
        start.bezelStyle = .push
        start.keyEquivalent = "\r"
        let buttons = NSStackView(views: [settings, start])
        buttons.spacing = 10
        for button in [settings, start] { button.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true }

        loginToggle.state = .on
        loginToggle.isHidden = SMAppService.mainApp.status == .enabled
        let column = NSStackView(views: [scene, title, subtitle, steps, loginToggle, buttons])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        column.setCustomSpacing(24, after: scene)
        column.setCustomSpacing(22, after: subtitle)
        column.setCustomSpacing(loginToggle.isHidden ? 26 : 18, after: steps)
        column.setCustomSpacing(22, after: loginToggle)
        column.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 520),
            scene.widthAnchor.constraint(equalToConstant: 464),
            scene.heightAnchor.constraint(equalToConstant: ReadyIllustrationView.size.height),
            illustration.leadingAnchor.constraint(equalTo: scene.leadingAnchor),
            illustration.trailingAnchor.constraint(equalTo: scene.trailingAnchor),
            illustration.topAnchor.constraint(equalTo: scene.topAnchor),
            illustration.bottomAnchor.constraint(equalTo: scene.bottomAnchor),
            steps.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            column.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: content.fittingSize.height))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private static func step(_ symbol: String, _ markdown: String) -> NSView {
        step(stepSymbol(symbol), markdown)
    }

    private static func stepSymbol(_ symbol: String) -> NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil) ?? NSImage()
    }

    private static func step(_ image: NSImage, _ markdown: String) -> NSView {
        let icon = NSImageView(image: image)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        let styled = (try? NSAttributedString(markdown: markdown)) ?? NSAttributedString(string: markdown)
        let line = NSMutableAttributedString(attributedString: styled)
        let range = NSRange(location: 0, length: line.length)
        line.addAttributes([.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor], range: range)
        styled.enumerateAttribute(.inlinePresentationIntent, in: range) { value, span, _ in
            if let raw = value as? UInt, InlinePresentationIntent(rawValue: raw).contains(.stronglyEmphasized) {
                line.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: span)
            }
        }
        text.attributedStringValue = line
        let row = NSStackView(views: [icon, text])
        row.spacing = 12
        row.alignment = .centerY
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return row
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        onSettings?()
        close()
    }

    @objc private func finish() { close() }

    func windowWillClose(_ notification: Notification) {
        if !loginToggle.isHidden, loginToggle.state == .on {
            let service = SMAppService.mainApp
            do {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch {
                // The menu's Launch at Login item reports errors; nothing to block here.
            }
        }
        onClose?()
    }
}

// MARK: - Media pause permission

/// The scriptable players utils/media_pause.py pauses; keep the two lists in sync.
let mediaPlayers = [("Spotify", "com.spotify.client"), ("Music", "com.apple.Music")]

enum MediaPlayerAccess: Sendable {
    case allowed, denied, undetermined, notRunning, failed
}

/// The Automation permission to control one player. Sends no Apple Event. With `ask`,
/// macOS shows its consent dialog and the call blocks until the user answers, so never
/// call it on the main thread.
func mediaPlayerAccess(bundleID: String, ask: Bool) -> MediaPlayerAccess {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
    let status = withExtendedLifetime(target) {
        Int(AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask))
    }
    if status == Int(noErr) { return .allowed }
    if status == Int(errAEEventNotPermitted) { return .denied }
    if status == Int(errAEEventWouldRequireUserConsent) { return .undetermined }
    if status == Int(procNotFound) { return .notRunning }
    return .failed
}

func runningMediaPlayers() -> [(name: String, bundleID: String)] {
    mediaPlayers.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.1).isEmpty }
        .map { (name: $0.0, bundleID: $0.1) }
}

// MARK: - Settings window

/// What the Settings header says dictation is doing right now.
struct SettingsStatus {
    enum Level { case ready, busy, attention, off }
    let text: String
    let level: Level
}

/// Launch at Login, for the menu bar item and the Settings switch. Only ever runs from a
/// click: LocalVoice never enables login launch on its own.
@MainActor
func toggleLaunchAtLogin() {
    let service = SMAppService.mainApp
    do {
        if service.status == .enabled {
            try service.unregister()
        } else if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            try service.register()
            if service.status == .requiresApproval {
                // Registered, but macOS wants the user to allow it.
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    } catch {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Could not change Launch at Login"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

func openConfigFile() {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-t", localVoiceConfigPath()]
    try? open.run()
}

// Layout shared by every Settings row, so tiles, text and controls line up across cards.
private enum SettingsMetrics {
    static let sidebarWidth: CGFloat = 210
    /// The section beside the sidebar; wide enough for the Models table.
    static let width: CGFloat = 700
    /// From the toolbar to the first card, in every section and in the sidebar.
    static let top: CGFloat = 12
    static let margin: CGFloat = 24
    static let cardWidth = width - margin * 2
    static let inset: CGFloat = 14
    static let tile: CGFloat = 28
    static let gap: CGFloat = 12
    static let textLeading = inset + tile + gap
    static let rowHeight: CGFloat = 52
}

/// The coloured rounded square with a white symbol that leads a row, as in System Settings.
private final class SettingsTile: NSView {
    private let tint: NSColor

    init(symbol: String, fallback: String, tint: NSColor, size: CGFloat = SettingsMetrics.tile,
         pointSize: CGFloat = 13) {
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil) ?? NSImage()
        let glyph = NSImageView(image: image)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleNone
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let base = tint.usingColorSpace(.sRGB) ?? tint
        let top = base.blended(withFraction: 0.24, of: .white) ?? base
        let radius = bounds.width / 4
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGradient(starting: top, ending: base)?.draw(in: path, angle: -90)
    }
}

/// The chosen gesture as keys: ⌘ ⌘ for Command twice. Right-aligned in a fixed width, so the
/// pickers beside it stay put when the tap count changes.
private final class SettingsKeycaps: NSView {
    private static let cap: CGFloat = 24
    private static let spacing: CGFloat = 4
    private static let most = 4
    private static let glyphs = ["ctrl": "⌃", "cmd": "⌘", "alt": "⌥", "shift": "⇧"]
    private static let names = ["ctrl": "Control", "cmd": "Command", "alt": "Option", "shift": "Shift"]
    private static let counts = [2: "twice", 3: "three times", 4: "four times"]
    private var glyph = "⌃"
    private var count = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { nil }

    func show(modifier: String, count: Int) {
        glyph = Self.glyphs[modifier] ?? "⌃"
        self.count = min(max(count, 2), Self.most)
        setAccessibilityLabel("Gesture: \(Self.names[modifier] ?? "Control") \(Self.counts[self.count] ?? "")")
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(Self.most) * Self.cap + CGFloat(Self.most - 1) * Self.spacing, height: Self.cap + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let lip = dark ? NSColor(white: 0, alpha: 0.55) : NSColor(white: 0, alpha: 0.20)
        let edge = dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.13)
        let face = dark
            ? NSGradient(starting: NSColor(white: 0.30, alpha: 1), ending: NSColor(white: 0.23, alpha: 1))
            : NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.955, alpha: 1))
        let text = NSAttributedString(string: glyph, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85),
        ])
        let textSize = text.size()
        for index in 0..<count {
            let fromRight = CGFloat(count - index)
            let x = bounds.maxX - fromRight * Self.cap - (fromRight - 1) * Self.spacing
            let key = NSRect(x: x, y: bounds.minY + 2, width: Self.cap, height: Self.cap)
            // The darker lip under the key is what makes it read as a key and not a badge.
            lip.setFill()
            NSBezierPath(roundedRect: key.offsetBy(dx: 0, dy: -1.5), xRadius: 6, yRadius: 6).fill()
            let path = NSBezierPath(roundedRect: key, xRadius: 6, yRadius: 6)
            face?.draw(in: path, angle: -90)
            edge.setStroke()
            let outline = NSBezierPath(roundedRect: key.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
            outline.lineWidth = 1
            outline.stroke()
            text.draw(at: NSPoint(x: key.midX - textSize.width / 2, y: key.midY - textSize.height / 2))
        }
    }
}

/// One Settings row: coloured tile, title over a one-line explanation, the control on the
/// right, and optionally a full-width field underneath.
@MainActor
private final class SettingsRow: NSView {
    let detail = NSTextField(wrappingLabelWithString: "")
    private let tile: SettingsTile
    private let titleLabel: NSTextField

    /// `reserve` is the widest the control can get, when that is more than it needs now.
    init(symbol: String, fallback: String = "circle.fill", tint: NSColor, title: String, detail text: String,
         accessory: NSView? = nil, reserve: CGFloat = 0, below: NSView? = nil, separator: Bool = true) {
        tile = SettingsTile(symbol: symbol, fallback: fallback, tint: tint)
        titleLabel = modelLibraryLabel(title, size: 13, weight: .medium)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        detail.stringValue = text
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        var textWidth = SettingsMetrics.cardWidth - SettingsMetrics.textLeading - SettingsMetrics.inset
        if let accessory {
            textWidth -= max(accessory.fittingSize.width, reserve) + SettingsMetrics.gap
        }
        detail.preferredMaxLayoutWidth = textWidth
        let labels = NSStackView(views: [titleLabel, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        // Inset like System Settings: the rule starts where the text does.
        let rule = ModelLibrarySeparator()
        rule.isHidden = !separator
        for view in [rule, tile, labels] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsMetrics.rowHeight),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.textLeading),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.inset),
            tile.centerYAnchor.constraint(equalTo: labels.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.textLeading),
            labels.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 9),
            labels.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth),
        ])
        if let accessory {
            // VoiceOver reads the explanation with the control, not as a stray line of text.
            if !text.isEmpty { (accessory as? NSControl)?.setAccessibilityHelp(text) }
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.inset),
                accessory.centerYAnchor.constraint(equalTo: labels.centerYAnchor),
            ])
        }
        if let below {
            below.translatesAutoresizingMaskIntoConstraints = false
            addSubview(below)
            NSLayoutConstraint.activate([
                labels.topAnchor.constraint(equalTo: topAnchor, constant: 9),
                below.topAnchor.constraint(equalTo: labels.bottomAnchor, constant: 9),
                below.leadingAnchor.constraint(equalTo: labels.leadingAnchor),
                below.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.inset),
                below.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            ])
        } else {
            NSLayoutConstraint.activate([
                labels.centerYAnchor.constraint(equalTo: centerYAnchor),
                labels.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -9),
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Replaces the explanation, optionally led by a small coloured status symbol.
    func setDetail(_ text: String, symbol: String? = nil, tint: NSColor = .secondaryLabelColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let line = NSMutableAttributedString()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, tint]))
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
            line.append(NSAttributedString(attachment: attachment))
            line.append(NSAttributedString(string: " ", attributes: attributes))
        }
        line.append(NSAttributedString(string: text, attributes: attributes))
        detail.attributedStringValue = line
        detail.setAccessibilityValue(text)
    }

    /// Greys the row out for a setting that does not apply right now. Its control is
    /// disabled separately, and keeps its value for when the setting applies again.
    func setDimmed(_ dimmed: Bool) {
        tile.alphaValue = dimmed ? 0.4 : 1
        titleLabel.textColor = dimmed ? .tertiaryLabelColor : .labelColor
    }
}

private final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

/// The sections of the Settings window, in sidebar order.
private enum SettingsPage: Int, CaseIterable {
    case general, dictation, recording, models

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .recording: "Recording"
        case .models: "Models"
        case .general: "General"
        }
    }

    @MainActor
    var tile: (symbol: String, fallback: String, tint: NSColor) {
        switch self {
        case .dictation: ("waveform", "waveform", .systemBlue)
        case .recording: ("record.circle.fill", "record.circle", .systemRed)
        case .models: ("square.stack.3d.up.fill", "square.stack.3d.up", .systemPurple)
        case .general: ("gearshape.fill", "gearshape", .systemGray)
        }
    }
}

/// The Settings sidebar: the app and what dictation is doing, then the sections.
@MainActor
private final class SettingsSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((SettingsPage) -> Void)?
    private let table = NSTableView()
    private let statusDot = ModelLibraryLayerView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var selecting = false

    override func loadView() {
        let icon = NSImageView(image: Bundle.main.url(forResource: "LocalVoice", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        let name = modelLibraryLabel(bundleDisplayName(), size: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusDot.radius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.setAccessibilityElement(false)
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, name, statusDot, statusLabel] { header.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            icon.topAnchor.constraint(equalTo: header.topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
            header.bottomAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            name.bottomAnchor.constraint(equalTo: icon.centerYAnchor, constant: 1),
            statusDot.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            statusDot.centerYAnchor.constraint(equalTo: statusLabel.firstBaselineAnchor, constant: -3.5),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 5),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            header.bottomAnchor.constraint(greaterThanOrEqualTo: statusLabel.bottomAnchor),
        ])
        // Only as tall as its content; the sections get the rest.
        let hug = header.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        hug.isActive = true
        statusLabel.preferredMaxLayoutWidth = SettingsMetrics.sidebarWidth - 18 - 12 - 34 - 8 - 12

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .custom
        // A little larger than System Settings: four sections should not look lost in the column.
        table.rowHeight = 38
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Settings Sections")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let config = NSButton(title: "Open Config File…", target: self, action: #selector(openConfig))
        config.isBordered = false
        config.attributedTitle = NSAttributedString(string: "Open Config File…", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.linkColor,
        ])
        config.toolTip = "Every setting is a line in \((localVoiceConfigPath() as NSString).abbreviatingWithTildeInPath)."
        config.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(config)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: SettingsMetrics.top),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: config.topAnchor, constant: -8),
            config.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            config.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            config.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SettingsPage.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = SettingsPage.allCases[row]
        let cell = NSTableCellView()
        let tile = SettingsTile(symbol: page.tile.symbol, fallback: page.tile.fallback, tint: page.tile.tint,
                                size: 26, pointSize: 13)
        let label = NSTextField(labelWithString: page.title)
        label.font = .systemFont(ofSize: 14)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tile)
        cell.addSubview(label)
        // As the cell's text field, the label turns white on the selection.
        cell.textField = label
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tile.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, SettingsPage.allCases.indices.contains(table.selectedRow) else { return }
        onSelect?(SettingsPage.allCases[table.selectedRow])
    }

    /// Shows `page` as selected without reporting it back.
    func select(_ page: SettingsPage) {
        _ = view
        selecting = true
        table.selectRowIndexes(IndexSet(integer: page.rawValue), byExtendingSelection: false)
        selecting = false
    }

    func focus() { view.window?.makeFirstResponder(table) }

    @objc private func openConfig() { openConfigFile() }

    func show(status: SettingsStatus) {
        _ = view
        // "Whisper Large V3 Turbo · Ready" wraps before the model's last word, not before the dot.
        statusLabel.stringValue = status.text.replacingOccurrences(of: " · ", with: "\u{00A0}·\u{00A0}")
        statusLabel.setAccessibilityValue(status.text)
        switch status.level {
        case .ready: statusDot.fill = .systemGreen
        case .busy: statusDot.fill = .systemOrange
        case .attention: statusDot.fill = .systemOrange
        case .off: statusDot.fill = .tertiaryLabelColor
        }
    }
}

/// The Settings window's content: the sections in a sidebar, the chosen one beside it.
@MainActor
private final class SettingsSplitViewController: NSSplitViewController, NSToolbarDelegate {
    let settings: SettingsViewController
    private let sidebar = SettingsSidebarViewController()

    init(settings: SettingsViewController) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebar.onSelect = { [weak self] page in self?.settings.show(page) }
        settings.onPageChange = { [weak self] page in
            guard let self else { return }
            sidebar.select(page)
            view.window?.title = page.title
            // "Choose Model…" was focused and is now out of sight; carry on from the sidebar.
            if (view.window?.firstResponder as? NSView)?.isHiddenOrHasHiddenAncestor == true { sidebar.focus() }
        }
        settings.onStatus = { [weak self] status in self?.sidebar.show(status: status) }
        settings.onContentChange = { [weak self] in self?.fitWindow() }
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.canCollapse = false
        side.minimumThickness = SettingsMetrics.sidebarWidth
        side.maximumThickness = SettingsMetrics.sidebarWidth
        let detail = NSSplitViewItem(viewController: settings)
        detail.minimumThickness = SettingsMetrics.width
        addSplitViewItem(side)
        addSplitViewItem(detail)
        sidebar.select(settings.page)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Arrow keys move between sections; Tab goes on into the section.
        sidebar.focus()
    }

    /// A unified toolbar whose title names the section, at a size that fits the tallest one.
    func configure(_ window: NSWindow) {
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        let toolbar = NSToolbar(identifier: "LocalVoiceSettings")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.title = settings.page.title
        fitWindow()
    }

    func show(_ page: SettingsPage) { settings.show(page) }

    /// Fits the window to the tallest section, so switching sections never resizes it,
    /// or to the screen if that is less. Keeps the top edge where it is.
    func fitWindow() {
        guard isViewLoaded, let window = view.window else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min((settings.fittedHeight + chrome).rounded(), max(360, screen - 40))
        let width = SettingsMetrics.sidebarWidth + splitView.dividerThickness + SettingsMetrics.width
        guard abs(window.frame.height - height) > 0.5 || abs(window.frame.width - width) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true)
    }

    // The tracking separator puts the title over the section rather than over the sidebar.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
}

@MainActor
private final class SettingsViewController: NSViewController, NSTokenFieldDelegate {
    /// The sidebar's state line; the app supplies the running model.
    var status: (() -> SettingsStatus)?
    /// The Models section. Set before the view loads.
    var models: ModelLibraryViewController?
    /// Every model the library lists, to name them in explanations.
    var modelEntries: (() -> [ModelLibraryEntry])?
    /// The model dictation uses or is loading; nil when there is none.
    var selectedModel: (() -> String?)?
    var onStatus: ((SettingsStatus) -> Void)?
    var onPageChange: ((SettingsPage) -> Void)?
    /// Something changed height; the window may need to grow.
    var onContentChange: (() -> Void)?
    private(set) var page: SettingsPage = .dictation

    private let modifier = NSPopUpButton()
    private let taps = NSPopUpButton()
    private let keycaps = SettingsKeycaps()
    private let microphone = NSPopUpButton()
    private let vocabulary = NSTokenField()
    private var vocabularyHeight: NSLayoutConstraint?
    private var vocabularySave: DispatchWorkItem?
    private let preview = NSSwitch()
    private let standby = NSSwitch()
    private let pauseMedia = NSSwitch()
    private let menuBar = NSSwitch()
    private let login = NSSwitch()
    private var pauseRow: SettingsRow?
    private var loginRow: SettingsRow?
    private var vocabularyRow: SettingsRow?
    private let vocabularyAction = NSButton(title: "Choose Model…", target: nil, action: nil)
    private var vocabularySupported = true
    private let pauseAction = NSButton(title: "", target: nil, action: nil)
    private var pauseActionOpensSettings = false
    private var askingPlayers: [String] = []
    private var pauseNoteRevision = 0
    // Only a failed save says anything; saving as you go needs no explanation. It sits
    // under the card of whichever section is showing.
    private let message = modelLibraryLabel(size: 11.5, color: .systemRed)
    private var pageViews: [SettingsPage: NSView] = [:]
    private var pageStacks: [SettingsPage: NSStackView] = [:]
    private var liveTimer: Timer?

    private static let vocabularyWidth = SettingsMetrics.cardWidth - SettingsMetrics.textLeading - SettingsMetrics.inset
    private static let vocabularyHelp = "Names and jargon to spell correctly, separated by commas."

    override func loadView() {
        configure(modifier, label: "Hotkey Modifier", action: #selector(changeHotkey))
        configure(taps, label: "Hotkey Tap Count", action: #selector(changeHotkey))
        configure(microphone, label: "Microphone", action: #selector(changeMicrophone))
        setItems([("Control", "ctrl"), ("Command", "cmd"), ("Option", "alt"), ("Shift", "shift")], on: modifier)
        setItems((2...4).map { ("\($0) taps", "\($0)") }, on: taps)
        setItems([("Built-in Microphone", "built-in"), ("System Default", "system")], on: microphone)
        microphone.widthAnchor.constraint(equalToConstant: 220).isActive = true
        // Sized for the longest title, so the row does not shift when the choice changes.
        modifier.widthAnchor.constraint(equalToConstant: modifier.fittingSize.width).isActive = true

        let toggles: [(NSSwitch, String, String)] = [
            (preview, "live-preview", "Live Preview"), (standby, "mic-standby", "Microphone Standby"),
            (pauseMedia, "pause-media", "Pause Media"), (menuBar, "menubar", "Show in Menu Bar"),
            (login, "", "Launch at Login"),
        ]
        for (control, key, label) in toggles {
            control.identifier = NSUserInterfaceItemIdentifier(key)
            control.controlSize = .small
            control.target = self
            control.action = control === login ? #selector(changeLogin) : #selector(changeToggle)
            control.setAccessibilityLabel(label)
        }

        let hotkey = NSStackView(views: [keycaps, modifier, taps])
        hotkey.spacing = 6
        hotkey.setCustomSpacing(12, after: keycaps)

        vocabulary.delegate = self
        vocabulary.tokenStyle = .rounded
        vocabulary.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
        vocabulary.placeholderString = "Ada, MLX, LocalVoice"
        vocabulary.font = .systemFont(ofSize: 12)
        vocabulary.cell?.wraps = true
        vocabulary.cell?.isScrollable = false
        vocabulary.setAccessibilityLabel("Vocabulary")
        vocabulary.setAccessibilityHelp(Self.vocabularyHelp)
        vocabularyHeight = vocabulary.heightAnchor.constraint(equalToConstant: 24)
        vocabularyHeight?.isActive = true

        // Pausing Spotify or Music needs macOS's Automation permission. The row's own
        // explanation says where that stands, and the button beside the switch settles it.
        pauseAction.bezelStyle = .push
        pauseAction.controlSize = .small
        pauseAction.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pauseAction.target = self
        pauseAction.action = #selector(performPauseAction)
        pauseAction.isHidden = true
        let pauseControls = NSStackView(views: [pauseAction, pauseMedia])
        pauseControls.spacing = 10
        pauseControls.detachesHiddenViews = true

        // Only some models read the vocabulary; with another one, this leads to the Models section.
        vocabularyAction.bezelStyle = .push
        vocabularyAction.controlSize = .small
        vocabularyAction.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        vocabularyAction.target = self
        vocabularyAction.action = #selector(chooseModel)
        vocabularyAction.isHidden = true

        let microphoneRow = SettingsRow(
            symbol: "mic.fill", tint: .systemRed, title: "Microphone",
            detail: "Built-in keeps AirPods in high-quality playback.", accessory: microphone)
        let vocabularyRow = SettingsRow(
            symbol: "character.book.closed.fill", fallback: "text.book.closed.fill", tint: .systemIndigo,
            title: "Vocabulary", detail: Self.vocabularyHelp, accessory: vocabularyAction, below: vocabulary)
        self.vocabularyRow = vocabularyRow
        let pause = SettingsRow(
            symbol: "playpause.fill", tint: .systemPink, title: "Pause Media", detail: "",
            accessory: pauseControls, reserve: 150)
        pauseRow = pause
        let loginItem = SettingsRow(
            symbol: "power", tint: .systemGreen, title: "Launch at Login", detail: "", accessory: login,
            reserve: 40)
        loginRow = loginItem

        let dictation = card("Dictation", [
            SettingsRow(symbol: "keyboard.fill", fallback: "keyboard", tint: .systemGray, title: "Hotkey",
                        detail: "Starts and stops dictation in any app.", accessory: hotkey, separator: false),
            microphoneRow,
            vocabularyRow,
        ])
        let recording = card("Recording", [
            SettingsRow(symbol: "captions.bubble.fill", fallback: "text.bubble.fill", tint: .systemBlue,
                        title: "Live Preview", detail: "Shows your words in the pill as you speak.",
                        accessory: preview, separator: false),
            SettingsRow(symbol: "bolt.fill", tint: .systemOrange, title: "Microphone Standby",
                        detail: "Recording starts instantly. The microphone indicator stays on.",
                        accessory: standby),
            pause,
        ])
        let general = card("General", [
            SettingsRow(symbol: "menubar.rectangle", tint: .systemTeal, title: "Show in Menu Bar",
                        detail: "When hidden, open LocalVoice again to come back here.",
                        accessory: menuBar, separator: false),
            loginItem,
        ])

        message.isHidden = true
        message.setAccessibilityRole(.staticText)

        pageViews[.dictation] = makePage(.dictation, dictation)
        pageViews[.recording] = makePage(.recording, recording)
        pageViews[.general] = makePage(.general, general)
        if let models {
            addChild(models)
            pageViews[.models] = models.view
            var modelCount = 0
            models.onRefresh = { [weak self] in
                guard let self else { return }
                updateVocabularyAvailability()
                // The catalog arrives after the window opens; the Models section may need more room.
                let count = modelEntries?().count ?? 0
                if count != modelCount {
                    modelCount = count
                    onContentChange?()
                }
            }
        }
        // Below the toolbar, so nothing scrolls under it.
        let root = NSView()
        for pageView in pageViews.values {
            pageView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(pageView)
            NSLayoutConstraint.activate([
                pageView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
                pageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                pageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                pageView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        show(page)
        refresh()
    }

    /// A scrolling section: its card, then the error line while it is showing.
    private func makePage(_ page: SettingsPage, _ card: NSView) -> NSView {
        let stack = NSStackView(views: [card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        pageStacks[page] = stack
        let document = SettingsDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalToConstant: SettingsMetrics.width),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: SettingsMetrics.top),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: SettingsMetrics.margin),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Self.pageInset),
        ])
        return scroll
    }

    private static let pageInset: CGFloat = 20

    func show(_ page: SettingsPage) {
        self.page = page
        guard isViewLoaded else { return }
        for (key, pageView) in pageViews { pageView.isHidden = key != page }
        if let stack = pageStacks[page], message.superview !== stack {
            (message.superview as? NSStackView)?.removeArrangedSubview(message)
            message.removeFromSuperview()
            stack.addArrangedSubview(message)
        }
        onPageChange?(page)
    }

    /// The height that shows the tallest section whole.
    var fittedHeight: CGFloat {
        guard isViewLoaded else { return 480 }
        view.layoutSubtreeIfNeeded()
        var height: CGFloat = 0
        for stack in pageStacks.values {
            height = max(height, stack.fittingSize.height + SettingsMetrics.top + Self.pageInset)
        }
        if models != nil {
            // Six until the catalog has loaded: every model the store lists, available or not.
            let count = modelEntries?().count ?? 0
            height = max(height, ModelLibraryViewController.preferredSize(
                modelCount: count == 0 ? 6 : count, top: SettingsMetrics.top).height)
        }
        return height
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The model and the login item change outside this window; keep those lines true.
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLive() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        liveTimer?.invalidate()
        liveTimer = nil
        saveVocabulary()
    }

    /// The inset card holding a section's rows. The toolbar names the section.
    private func card(_ title: String, _ rows: [NSView]) -> NSView {
        let card = ModelLibraryLayerView()
        card.fill = .modelLibraryCard
        card.stroke = .separatorColor
        card.radius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(title)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: SettingsMetrics.cardWidth),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    private static func isOn(_ key: String, default fallback: Bool = false) -> Bool {
        guard let value = readConfigValue(key)?.lowercased() else { return fallback }
        return ["1", "on", "true", "yes"].contains(value)
    }

    private static func words(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func refresh() {
        guard isViewLoaded else { return }
        let key = (readConfigValue("hotkey") ?? "").lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        select(key.count == 2 ? key[0] : "ctrl", fallback: "ctrl", on: modifier)
        select(key.count == 2 ? key[1] : "3", fallback: "3", on: taps)
        showGesture()

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
        // Leave a list that is being typed alone.
        if vocabulary.currentEditor() == nil {
            vocabulary.objectValue = Self.words(readConfigValue("vocabulary") ?? "")
            fitVocabulary()
        }
        for button in [preview, standby, pauseMedia] { button.state = Self.isOn(button.identifier!.rawValue) ? .on : .off }
        // The menu bar icon is on unless the config says otherwise.
        menuBar.state = Self.isOn("menubar", default: true) ? .on : .off
        refreshLive()
        updatePauseNote()
    }

    private func refreshLive() {
        guard isViewLoaded else { return }
        onStatus?(status?() ?? SettingsStatus(text: "Dictation is off", level: .off))
        updateVocabularyAvailability()
        let service = SMAppService.mainApp.status
        login.state = service == .enabled ? .on : .off
        if service == .requiresApproval {
            loginRow?.setDetail("Waiting for your approval in System Settings › Login Items.",
                                symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
        } else {
            loginRow?.setDetail("Starts LocalVoice when you log in to your Mac.")
        }
        login.setAccessibilityHelp(loginRow?.detail.stringValue)
    }

    private func showGesture() {
        keycaps.show(modifier: modifier.selectedItem?.representedObject as? String ?? "ctrl",
                     count: Int(taps.selectedItem?.representedObject as? String ?? "") ?? 3)
    }

    // MARK: Vocabulary

    private func fitVocabulary() {
        let bounds = NSRect(x: 0, y: 0, width: Self.vocabularyWidth, height: 10_000)
        let height = vocabulary.cell?.cellSize(forBounds: bounds).height ?? 24
        let fitted = min(max(height.rounded(.up), 24), 112)
        guard fitted != vocabularyHeight?.constant else { return }
        vocabularyHeight?.constant = fitted
        onContentChange?()
    }

    /// Greys the vocabulary out while the model in use ignores it, and says which ones read it.
    /// The words stay saved for when such a model is in use again.
    private func updateVocabularyAvailability() {
        guard isViewLoaded else { return }
        let entries = modelEntries?() ?? []
        let model = selectedModel?()
        let supported = model.map(DictationVocabulary.isSupported(by:)) ?? true
        if !supported, vocabulary.currentEditor() != nil {
            saveVocabulary()
            view.window?.makeFirstResponder(nil)
        }
        let text = supported ? Self.vocabularyHelp : Self.vocabularyUnsupported(model: model ?? "", entries: entries)
        guard supported != vocabularySupported || vocabularyRow?.detail.stringValue != text else { return }
        vocabularySupported = supported
        vocabulary.isEnabled = supported
        vocabularyRow?.setDimmed(!supported)
        vocabularyAction.isHidden = supported
        if supported {
            vocabularyRow?.setDetail(text)
        } else {
            vocabularyRow?.setDetail(text, symbol: "info.circle.fill", tint: .systemOrange)
        }
        vocabulary.setAccessibilityHelp(text)
        vocabularyAction.setAccessibilityHelp(text)
        onContentChange?()
    }

    /// "Parakeet V3 doesn't support custom vocabulary." and one model to choose instead:
    /// a downloaded one if there is one, otherwise one that can be downloaded.
    static func vocabularyUnsupported(model: String, entries: [ModelLibraryEntry]) -> String {
        let name = entries.first { $0.id == model }?.name ?? "The selected model"
        let candidates = entries.filter { DictationVocabulary.isSupported(by: $0.id) }
        let installed = candidates.first { if case .installed = $0.state { true } else { false } }
        let offered = candidates.first { if case .unavailable = $0.state { false } else { true } }
        let example = (installed ?? offered)?.name ?? "Whisper Large V3 Turbo"
        return "\(name) doesn't support custom vocabulary. Select a model that does, for example \(example)."
    }

    @objc private func chooseModel() { show(.models) }

    private func saveVocabulary() {
        vocabularySave?.cancel()
        vocabularySave = nil
        guard isViewLoaded else { return }
        let tokens = (vocabulary.objectValue as? [Any] ?? []).compactMap { $0 as? String }
        let value = Self.words(tokens.joined(separator: ",")).joined(separator: ", ")
        // An untouched, empty list should not add a line to the config.
        if value != Self.words(readConfigValue("vocabulary") ?? "").joined(separator: ", ") {
            save("vocabulary", value)
        }
        fitVocabulary()
    }

    func controlTextDidChange(_ notification: Notification) {
        // Typing saves after a short pause, so a half-typed word is not written on every key.
        vocabularySave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveVocabulary() }
        vocabularySave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        saveVocabulary()
    }

    func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
        tokens.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: Pause Media

    private func showPauseNote(_ text: String, symbol: String? = nil, tint: NSColor = .secondaryLabelColor,
                               action: String? = nil, opensSettings: Bool = false) {
        pauseRow?.setDetail(text, symbol: symbol, tint: tint)
        pauseMedia.setAccessibilityHelp(text)
        pauseAction.isHidden = action == nil
        pauseAction.title = action ?? ""
        pauseActionOpensSettings = opensSettings
        onContentChange?()
    }

    // Reads the Automation state of the running players without asking, then explains it.
    private func updatePauseNote() {
        pauseNoteRevision += 1
        let revision = pauseNoteRevision
        guard pauseMedia.state == .on else {
            showPauseNote("Pauses Spotify and Music while you dictate. macOS asks once.")
            return
        }
        if !askingPlayers.isEmpty {
            showPauseNote("Answer the macOS dialog to let LocalVoice pause \(askingPlayers.joined(separator: " and ")).")
            return
        }
        let players = runningMediaPlayers()
        guard !players.isEmpty else {
            showPauseNote("Pauses Spotify and Music. macOS asks once, when one is open.")
            return
        }
        Task.detached {
            var results: [(String, MediaPlayerAccess)] = []
            for player in players { results.append((player.name, mediaPlayerAccess(bundleID: player.bundleID, ask: false))) }
            let answers = results
            await MainActor.run { [weak self] in
                guard let self, revision == self.pauseNoteRevision else { return }
                self.explain(answers)
            }
        }
    }

    private func explain(_ answers: [(String, MediaPlayerAccess)]) {
        let denied = answers.filter { $0.1 == .denied }.map(\.0)
        let pending = answers.filter { $0.1 == .undetermined }.map(\.0)
        let allowed = answers.filter { $0.1 == .allowed }.map(\.0)
        if !denied.isEmpty {
            showPauseNote("Not allowed for \(denied.joined(separator: " and ")). Turn on LocalVoice under "
                          + "Privacy & Security › Automation.", symbol: "exclamationmark.triangle.fill",
                          tint: .systemOrange, action: "Open Settings…", opensSettings: true)
        } else if !pending.isEmpty {
            showPauseNote("LocalVoice needs your OK to pause \(pending.joined(separator: " and ")).",
                          symbol: "exclamationmark.circle.fill", tint: .systemOrange, action: "Allow…")
        } else if !allowed.isEmpty {
            showPauseNote("Pauses media while you dictate. Allowed for \(allowed.joined(separator: " and ")).",
                          symbol: "checkmark.circle.fill", tint: .systemGreen)
        } else {
            showPauseNote("Pauses Spotify and Music while you dictate. macOS asks once.")
        }
    }

    // Shows macOS's consent dialog now, while the user is looking at this option.
    private func askRunningPlayers() {
        let players = runningMediaPlayers()
        guard !players.isEmpty, askingPlayers.isEmpty else { updatePauseNote(); return }
        askingPlayers = players.map(\.name)
        updatePauseNote()
        Task.detached {
            for player in players { _ = mediaPlayerAccess(bundleID: player.bundleID, ask: true) }
            await MainActor.run { [weak self] in
                self?.askingPlayers = []
                self?.updatePauseNote()
            }
        }
    }

#if SETTINGS_PREVIEW
    func previewPauseNote(_ scenario: String) {
        pauseNoteRevision += 1
        switch scenario {
        case "denied":
            pauseMedia.state = .on
            explain([("Spotify", .denied)])
        case "allowed":
            pauseMedia.state = .on
            explain([("Spotify", .allowed)])
        case "pending":
            pauseMedia.state = .on
            explain([("Spotify", .undetermined)])
        default:
            pauseMedia.state = .off
            showPauseNote("Pauses Spotify and Music while you dictate. macOS asks once.")
        }
    }
#endif

    @objc private func performPauseAction() {
        if pauseActionOpensSettings {
            openPrivacyPane("Privacy_Automation")
        } else {
            askRunningPlayers()
        }
    }

    // MARK: Controls

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
        let written = writeConfigValue(key, value)
        if !written { refresh() }
        message.stringValue = written ? "" : "Could not save the setting."
        message.isHidden = written
        onContentChange?()
    }

    @objc private func changeHotkey() {
        guard let key = modifier.selectedItem?.representedObject as? String,
              let count = taps.selectedItem?.representedObject as? String else { return }
        showGesture()
        save("hotkey", "\(key),\(count)")
    }

    @objc private func changeMicrophone() {
        if let device = microphone.selectedItem?.representedObject as? String { save("microphone", device) }
    }

    @objc private func changeToggle(_ sender: NSSwitch) {
        if let key = sender.identifier?.rawValue { save(key, sender.state == .on ? "on" : "off") }
        if sender === pauseMedia {
            if pauseMedia.state == .on { askRunningPlayers() } else { updatePauseNote() }
        }
    }

    @objc private func changeLogin() {
        toggleLaunchAtLogin()
        // The switch shows what macOS registered, not what was clicked.
        refreshLive()
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
    /// A read-only line at the top of the menu, e.g. "Whisper … · Ready".
    var status: (() -> String?)?

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
                button.image = localVoiceTemplateIcon()
                button.toolTip = "LocalVoice"
                button.setAccessibilityLabel("LocalVoice")
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

        if let line = status?() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

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
            let granted = microphoneState() == .granted && accessibilityState() == .granted
                && inputMonitoringState() == .granted
            menu.addItem(actionItem(title: granted ? "Permissions…" : "Finish Setup…",
                                    selector: #selector(openPermissions)))
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

    @objc private func openConfig() { openConfigFile() }

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

    @objc private func toggleLogin() { toggleLaunchAtLogin() }
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
    private var settingsWindow: NSWindow?
    private var menuTimer: Timer?
    private var child: Process?
    private var childModel: String?
    private var runningModel: String?
    private var readyTimer: Timer?
    private var gate: Int32 = -1
    private var pending: Switch?
    private var nextModel: String?
    private var stopping = false
    private var permissionChecklist: PermissionChecklist?
    private var readyWindow: ReadyWindowController?
    // Set when the permissions were completed in this run; the first ready model then
    // gets the ready screen (as does the very first ready model of an install).
    private var setupCompletedThisRun = false
    private var presentingReady = false
    private static let readyShownKey = "onboarding.readyShown"
    private var waitingForPermissions = false
    private var mayRetry = true
    // When the running child became ready, to re-arm crash recovery.
    private var readySince: TimeInterval?
    // Write end of the child's stdin. The child exits on EOF, so it cannot
    // outlive the app even if the app crashes or is force-quit.
    private var lifeline: FileHandle?

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
         "nemotron-streaming", "qwen3-asr-1.7b"].contains(id)
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
        menuBar.status = { [weak self] in self?.statusLine }
        menuBar.installApplicationMenu()
        applyMenuVisibility()
        menuTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyMenuVisibility() }
        }
        if permissionsGranted {
            start(savedModel ?? Self.defaultModel)
            // Relaunched mid-setup (Quit & Reopen): finish on the setup window, which
            // opens Models on Done if no model is chosen yet.
            if PermissionLedger.standard.resumeIsFresh {
                setupPermissions()
            } else if savedModel == nil {
                showModels()
            }
        } else {
            setupPermissions()
        }
    }

    // System Settings' Quit & Reopen terminates through AppKit; stop the child first so
    // the relaunched copy doesn't run beside an orphaned service.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quit()
        return .terminateLater
    }

    private var setupServiceState: SetupServiceState {
        if savedModel == nil { return .needsModel }
        if runningModel != nil { return .ready }
        if let childModel {
            return .starting(library?.models.first { $0.id == childModel }?.name ?? "the speech model")
        }
        return .stopped
    }

    private func modelName(_ id: String) -> String {
        library?.models.first(where: { $0.id == id })?.name ?? id
    }

    /// One line for the top of the menu: what dictation will use right now.
    private var statusLine: String { settingsStatus.text }

    /// The same line with how it should be coloured, for the Settings header.
    private var settingsStatus: SettingsStatus {
        if let runningModel { return SettingsStatus(text: "\(modelName(runningModel)) · Ready", level: .ready) }
        if let childModel { return SettingsStatus(text: "Loading \(modelName(childModel))…", level: .busy) }
        if !permissionsGranted { return SettingsStatus(text: "Waiting for permissions", level: .attention) }
        return SettingsStatus(text: "Dictation is off", level: .off)
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
            // The section last shown, or Models while no model is chosen.
            showSettings(savedModel == nil ? .models : nil)
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if waitingForPermissions && permissionChecklist?.isPresented != true && permissionsGranted {
            permissionsBecameReady()
        }
    }

    private func showModels() { showSettings(.models) }

    /// Opens Settings at `page`, or at the section it showed last.
    private func showSettings(_ page: SettingsPage? = nil) {
        library?.refresh()
        if settingsWindow == nil {
            let controller = SettingsViewController()
            controller.status = { [weak self] in
                self?.settingsStatus ?? SettingsStatus(text: "Dictation is off", level: .off)
            }
            if let library {
                controller.models = ModelLibraryViewController(
                    backend: library,
                    notice: "Models run locally. Language changes apply to the next dictation.",
                    readLanguage: { id in
                        DictationLanguage(rawValue: readConfigValue("language.\(id)")?.lowercased() ?? "") ?? .auto
                    },
                    saveLanguage: { id, language in
                        DictationLanguage.canSelect(for: id) && writeConfigValue("language.\(id)", language.rawValue)
                    },
                    readyDetail: { [weak self] in
                        // The ready screen says all this when it is up.
                        if self?.presentingReady == true { return nil }
                        let menuBar = ["on", "true", "1", "yes"].contains(readConfigValue("menubar")?.lowercased() ?? "on")
                        return "Tap \(hotkeyDescription()) in any app to start, and again to insert the text. Esc discards."
                            + (menuBar ? " Settings stay under the LocalVoice icon in the menu bar." : "")
                    },
                    embedded: true, top: SettingsMetrics.top
                )
                controller.modelEntries = { [weak library] in library?.models ?? [] }
            }
            // What the next dictation will run: the model starting or running, else the saved choice.
            controller.selectedModel = { [weak self] in self?.childModel ?? self?.savedModel }
            let split = SettingsSplitViewController(settings: controller)
            let window = NSWindow(contentViewController: split)
            window.isReleasedWhenClosed = false
            split.configure(window)
            window.center()
            // Buttons come and go; keep Tab order in step with them.
            window.autorecalculatesKeyViewLoop = true
            settingsWindow = window
        }
        let split = settingsWindow?.contentViewController as? SettingsSplitViewController
        if let page { split?.show(page) }
        split?.settings.refresh()
        split?.fitWindow()
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
            checklist.onQuit = { [weak self] in self?.quit() }
            checklist.serviceState = { [weak self] in self?.setupServiceState ?? .stopped }
            permissionChecklist = checklist
        }
        waitingForPermissions = !permissionsGranted
        permissionChecklist?.present()
    }

    private func permissionsBecameReady() {
        waitingForPermissions = false
        setupCompletedThisRun = true
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
                // While quitting, the child may already be detached from
                // `self.child`; it still has to go before the app exits.
                guard let self, let process, process.isRunning,
                      self.stopping || self.child === process else { return }
                // Process starts the child in its own group; take the mic
                // worker and overlay helpers down with it.
                let pid = process.processIdentifier
                if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
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
        environment["LOCALVOICE_LIFELINE"] = "stdin"
        process.environment = environment
        let pipe = Pipe()
        process.standardInput = pipe.fileHandleForReading
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
        try? pipe.fileHandleForReading.close()
        try? lifeline?.close()
        lifeline = pipe.fileHandleForWriting
        child = process
        childModel = model
        permissionChecklist?.serviceDidChange()
        // Uptime does not advance while the Mac sleeps, so closing the lid
        // during a model load does not count against the deadline.
        let deadline = ProcessInfo.processInfo.systemUptime + 150
        readyTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak process] _ in
            DispatchQueue.main.async { [weak self, weak process] in
                guard let self, let process, self.child === process,
                      self.nextModel == nil, !self.stopping else { return }
                if process.isRunning,
                   (try? String(contentsOf: ready, encoding: .utf8)) == "\(process.processIdentifier)\n" {
                    self.becameReady(model)
                } else if ProcessInfo.processInfo.systemUptime > deadline {
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
        readySince = ProcessInfo.processInfo.systemUptime
        // Decide before the library updates, so its own "ready" note stays quiet.
        let showReady = setupCompletedThisRun || !UserDefaults.standard.bool(forKey: Self.readyShownKey)
        if showReady { presentingReady = true }
        library?.setActiveModel(model)
        library?.setLoadingModel(nil)
        if let operation = pending {
            pending = nil
            operation.complete(!operation.recovering)
        }
        releaseGate()
        permissionChecklist?.serviceDidChange()
        if showReady { presentReady(model) }
    }

    private func presentReady(_ model: String) {
        setupCompletedThisRun = false
        UserDefaults.standard.set(true, forKey: Self.readyShownKey)
        // The setup window has done its job; the ready screen takes over.
        if permissionChecklist?.isPresented == true { permissionChecklist?.close() }
        let menuBar = ["on", "true", "1", "yes"].contains(readConfigValue("menubar")?.lowercased() ?? "on")
        let name = library?.models.first { $0.id == model }?.name
        let ready = ReadyWindowController(modelName: name, menuBar: menuBar)
        ready.onSettings = { [weak self] in self?.showSettings() }
        ready.onClose = { [weak self] in
            self?.presentingReady = false
            self?.readyWindow = nil
        }
        readyWindow?.close()
        readyWindow = ready
        ready.present()
    }

    private func ended(_ process: Process, model: String) {
        guard child === process else { return }
        let wasReady = runningModel == model
        // A child that ran for a while before crashing earns a fresh retry;
        // only back-to-back crashes give up.
        if let readySince, ProcessInfo.processInfo.systemUptime - readySince > 300 { mayRetry = true }
        readySince = nil
        child = nil
        childModel = nil
        readyTimer?.invalidate()
        readyTimer = nil
        runningModel = nil
        try? lifeline?.close()
        lifeline = nil
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
        permissionChecklist?.serviceDidChange()
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
        library?.refresh(error: "LocalVoice could not start \(modelName(model)). Click Use to try again.")
        showModels()
        permissionChecklist?.serviceDidChange()
    }

    func quit() {
        guard !stopping else { return }
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
    // Check in with LaunchServices first: the old copy's openApplication completion (and
    // with it the old copy's exit, which frees the lock) waits for this.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var instance: ManagedService?
    // After Quit & Reopen or the setup window's Reopen, the old copy may still be
    // stopping its service; wait for its lock instead of exiting (setup stamp only).
    let deadline = Date().addingTimeInterval(12)
    while instance == nil {
        do {
            instance = try ManagedService(config: config, arguments: arguments)
        } catch let error as POSIXError where error.code == .EWOULDBLOCK {
            guard PermissionLedger.standard.resumeIsFresh, Date() < deadline else { exit(0) }
            usleep(100_000)
        } catch {
            fail("Could not create service state: \(error.localizedDescription)", code: 74)
        }
    }
    guard let managed = instance else { exit(0) }
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

enum LocalVoiceLauncher {
    @MainActor
    static func run() {
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

#if PERMISSIONS_PREVIEW
// Renders the permission window offscreen. Nothing here reads or changes real permissions:
//   PERMISSIONS_PREVIEW_SCENARIO = fresh | resumed | waiting | attention | relaunch | oldentry |
//                                  restricted | complete | covered | complete-model | panel | panel-success
//   PERMISSIONS_PREVIEW_SNAPSHOT = <path without .png>   (omit to keep the window open)
//   PERMISSIONS_PREVIEW_APPEARANCE = light | dark
@MainActor
private final class PreviewPermissionProbe: PermissionProbe {
    let snapshot: PermissionSnapshot
    init(_ snapshot: PermissionSnapshot) { self.snapshot = snapshot }
    func read() -> PermissionSnapshot { snapshot }
}

@MainActor
private enum PermissionPreview {
    static func run() {
        let environment = ProcessInfo.processInfo.environment
        let scenario = environment["PERMISSIONS_PREVIEW_SCENARIO"] ?? "fresh"
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if let appearance = environment["PERMISSIONS_PREVIEW_APPEARANCE"] {
            app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        let none = PermissionSnapshot(microphone: .undetermined, accessibility: false, inputMonitoring: false,
                                      listenAccess: kIOHIDAccessTypeUnknown)
        var snapshot = none
        switch scenario {
        case "resumed", "waiting", "attention", "panel":
            snapshot.microphone = .granted
        case "panel-success":
            snapshot.microphone = .granted
            snapshot.accessibility = true
        case "relaunch":
            snapshot.microphone = .granted
            snapshot.accessibility = true
            snapshot.listenAccess = kIOHIDAccessTypeGranted
        case "oldentry":
            snapshot.microphone = .denied
            snapshot.listenAccess = kIOHIDAccessTypeDenied
        case "restricted":
            snapshot.microphone = .restricted
        case "covered":
            snapshot = PermissionSnapshot(microphone: .granted, accessibility: true, inputMonitoring: true,
                                          listenAccess: kIOHIDAccessTypeUnknown)
        case "complete", "complete-model":
            snapshot = PermissionSnapshot(microphone: .granted, accessibility: true, inputMonitoring: true,
                                          listenAccess: kIOHIDAccessTypeGranted)
        default:
            break
        }
        if scenario.hasPrefix("ready") {
            let ready = ReadyWindowController(modelName: "Whisper Large V3 Turbo", menuBar: true,
                                              still: scenario == "ready-still")
            ready.present()
            if let path = environment["PERMISSIONS_PREVIEW_SNAPSHOT"] {
                let delay = Double(environment["PERMISSIONS_PREVIEW_DELAY"] ?? "") ?? 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    // Render the layer tree as it is on screen right now (mid-animation).
                    guard let view = ready.window?.contentView, let layer = view.layer else { exit(1) }
                    let scale = ready.window?.backingScaleFactor ?? 2
                    let size = view.bounds.size
                    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                     pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                          let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
                    rep.size = size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    ready.window?.effectiveAppearance.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill()
                        NSRect(origin: .zero, size: size).fill()
                    }
                    context.cgContext.scaleBy(x: scale, y: scale)
                    (layer.presentation() ?? layer).render(in: context.cgContext)
                    NSGraphicsContext.restoreGraphicsState()
                    let data = rep.representation(using: .png, properties: [:])
                    exit((try? data?.write(to: URL(fileURLWithPath: "\(path).png"))) == nil ? 1 : 0)
                }
            }
            withExtendedLifetime(ready) { app.run() }
            return
        }
        let ledger = PermissionLedger(store: UserDefaults(suiteName: "localvoice.permissions.preview") ?? .standard)
        ledger.store.removePersistentDomain(forName: "localvoice.permissions.preview")
        if scenario == "oldentry" {
            for kind in PermissionKind.allCases { ledger.setGrantedBy(kind, "earlier-build") }
        }
        let checklist = PermissionChecklist(probe: PreviewPermissionProbe(snapshot),
                                            identity: BuildIdentity(cdhash: "preview", isAdhoc: true),
                                            ledger: ledger)
        if scenario == "complete" || scenario == "covered" { checklist.serviceState = { .ready } }
        if scenario == "complete-model" { checklist.serviceState = { .needsModel } }
        checklist.previewConfigure(scenario)
        checklist.present()
        let panel = checklist.previewGuide(scenario)
        if let path = environment["PERMISSIONS_PREVIEW_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let window = panel ?? checklist.window, let frameView = window.contentView?.superview
                else { exit(1) }
                frameView.layoutSubtreeIfNeeded()
                let bounds = frameView.bounds
                guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { exit(1) }
                frameView.cacheDisplay(in: bounds, to: rep)
                let data = rep.representation(using: .png, properties: [:])
                exit((try? data?.write(to: URL(fileURLWithPath: "\(path).png"))) == nil ? 1 : 0)
            }
        }
        withExtendedLifetime(checklist) { app.run() }
    }
}
#endif

#if SETTINGS_PREVIEW
// Renders the Settings window without launching LocalVoice or opening the microphone:
//   SETTINGS_PREVIEW_SNAPSHOT = <path without .png>   (omit to keep the window open)
//   SETTINGS_PREVIEW_APPEARANCE = light | dark
//   SETTINGS_PREVIEW_SCENARIO = off | pending | denied | allowed   (the Pause Media line)
//   SETTINGS_PREVIEW_STATUS = ready | loading | permissions | off  (the sidebar's state line)
//   SETTINGS_PREVIEW_PAGE = general | dictation | recording | models
//   SETTINGS_PREVIEW_MODEL = <model id in use>   (e.g. parakeet-v3; the demo library's models)
//   SETTINGS_PREVIEW_ICON = <image for the header>    (the preview has no app bundle)
//   LOCALVOICE_CONFIG_DIR = <directory holding `config`>
// Without LOCALVOICE_CONFIG_DIR the preview makes an empty temporary one, so it never
// reads or writes ~/.config/localvoice/config.
// Controls draw their inactive look in a window that is not key, and the snapshot never
// shows its window. Claiming key status gives the picture the colours a user sees.
private final class SettingsPreviewWindow: NSWindow {
    var claimsKey = false
    override var isKeyWindow: Bool { claimsKey || super.isKeyWindow }
    override var isMainWindow: Bool { claimsKey || super.isMainWindow }
    // AppKit asks the window this, not isKeyWindow, when it picks a control's colours.
    @objc(hasKeyAppearance) var previewKeyAppearance: Bool { claimsKey }
}

@MainActor
private enum SettingsPreview {
    static func run() {
        if getenv("LOCALVOICE_CONFIG_DIR") == nil {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("localvoice-settings-preview-\(getpid())").path
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            setenv("LOCALVOICE_CONFIG_DIR", directory, 1)
        }
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["LOCALVOICE_CONFIG_DIR"], localVoiceConfigPath() == directory + "/config"
        else {
            FileHandle.standardError.write(Data("Settings preview: LOCALVOICE_CONFIG_DIR is not in effect.\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if let appearance = environment["SETTINGS_PREVIEW_APPEARANCE"] {
            app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let icon = environment["SETTINGS_PREVIEW_ICON"].flatMap({ NSImage(contentsOfFile: $0) }) {
            app.applicationIconImage = icon
        }
        let backend = DemoModelLibraryBackend(active: environment["SETTINGS_PREVIEW_MODEL"])
        let active = backend.models.first { if case .active = $0.state { true } else { false } }
        let status: SettingsStatus
        switch environment["SETTINGS_PREVIEW_STATUS"] ?? "ready" {
        case "loading": status = SettingsStatus(text: "Loading \(active?.name ?? "Whisper")…", level: .busy)
        case "permissions": status = SettingsStatus(text: "Waiting for permissions", level: .attention)
        case "off": status = SettingsStatus(text: "Dictation is off", level: .off)
        default: status = SettingsStatus(text: "\(active?.name ?? "Whisper") · Ready", level: .ready)
        }
        let controller = SettingsViewController()
        controller.status = { status }
        controller.models = ModelLibraryViewController(
            backend: backend, notice: "Models run locally. Demo only: actions are simulated.",
            readLanguage: { _ in .auto }, saveLanguage: { _, _ in true }, embedded: true,
            top: SettingsMetrics.top)
        controller.modelEntries = { backend.models }
        controller.selectedModel = {
            backend.models.first { if case .active = $0.state { true } else { false } }?.id
        }
        let split = SettingsSplitViewController(settings: controller)
        let window = SettingsPreviewWindow(contentViewController: split)
        window.claimsKey = environment["SETTINGS_PREVIEW_SNAPSHOT"] != nil
        split.configure(window)
        if let name = environment["SETTINGS_PREVIEW_PAGE"],
           let page = SettingsPage.allCases.first(where: { $0.title.lowercased() == name.lowercased() }) {
            split.show(page)
        }
        controller.previewPauseNote(environment["SETTINGS_PREVIEW_SCENARIO"] ?? "off")
        split.fitWindow()
        window.center()
        if let path = environment["SETTINGS_PREVIEW_SNAPSHOT"] {
            // Offscreen: the window is never ordered in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let frameView = window.contentView?.superview else { exit(1) }
                frameView.layoutSubtreeIfNeeded()
                let bounds = frameView.bounds
                guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { exit(1) }
                frameView.cacheDisplay(in: bounds, to: rep)
                let data = rep.representation(using: .png, properties: [:])
                exit((try? data?.write(to: URL(fileURLWithPath: "\(path).png"))) == nil ? 1 : 0)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
        withExtendedLifetime((backend, split, window)) { app.run() }
    }
}
#endif

#if SETTINGS_PREVIEW
@main
struct SettingsPreviewMain {
    @MainActor
    static func main() { SettingsPreview.run() }
}
#elseif PERMISSIONS_PREVIEW
@main
struct PermissionPreviewMain {
    @MainActor
    static func main() { PermissionPreview.run() }
}
#else
@main
struct LocalVoiceMain {
    @MainActor
    static func main() { LocalVoiceLauncher.run() }
}
#endif
