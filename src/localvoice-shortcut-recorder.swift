import AppKit

// The shortcut recorder in Settings, modelled on Raycast's: a field that shows the
// dictation shortcut as keys and, when clicked, a popover that shows the keys you
// press as you press them. Whatever was pressed last is the candidate: a key
// combination (⌥Space), modifiers pressed together and released (⌃⌘), or a modifier
// tapped two to four times (⌃⌃⌃). Return saves it, Esc closes. Global shortcuts
// pause while the popover is open, so pressing the current shortcut records it
// instead of starting dictation.

// MARK: - Keycaps

/// A row of keys in the style of the Settings keycaps: a face with a darker lip under
/// it. Symbols for modifiers and named keys, text for the rest, and an R badge on a
/// right-side modifier.
final class KeycapRowView: NSView {
    var keycaps: [Keycap] = [] { didSet { changed() } }
    /// Shown, dimmed, when there are no keys.
    var placeholder: String? { didSet { changed() } }
    /// Tints the labels (accent while recording, red for a refused shortcut).
    var labelColor: NSColor? { didSet { needsDisplay = true } }
    var alignment: NSTextAlignment = .center { didSet { needsDisplay = true } }
    private let capHeight: CGFloat
    private var spacing: CGFloat { (capHeight / 6).rounded() }

    init(capHeight: CGFloat) {
        self.capHeight = capHeight
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    private func changed() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var fontSize: CGFloat { (capHeight * 0.5).rounded() }

    private func width(of keycap: Keycap) -> CGFloat {
        if keycap.symbol == "space" { return (capHeight * 1.9).rounded() }
        if keycap.symbol != nil { return capHeight }
        let text = NSAttributedString(string: keycap.text, attributes: [.font: font(for: keycap)])
        return max(capHeight, (text.size().width + capHeight * 0.6).rounded(.up))
    }

    private func font(for keycap: Keycap) -> NSFont {
        // Words ("Space", "F12") read smaller than one glyph.
        let size = keycap.text.count > 2 ? fontSize * 0.72 : fontSize
        return .systemFont(ofSize: size, weight: .medium)
    }

    override var intrinsicContentSize: NSSize {
        if keycaps.isEmpty {
            let text = NSAttributedString(string: placeholder ?? "", attributes: [.font: NSFont.systemFont(ofSize: 12)])
            return NSSize(width: text.size().width, height: capHeight + 2)
        }
        let total = keycaps.map(width(of:)).reduce(0, +) + CGFloat(keycaps.count - 1) * spacing
        return NSSize(width: total, height: capHeight + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !keycaps.isEmpty else {
            let text = NSAttributedString(string: placeholder ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: originX(for: size.width), y: bounds.midY - size.height / 2))
            return
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let lip = dark ? NSColor(white: 0, alpha: 0.55) : NSColor(white: 0, alpha: 0.20)
        let edge = dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.13)
        let face = dark
            ? NSGradient(starting: NSColor(white: 0.30, alpha: 1), ending: NSColor(white: 0.23, alpha: 1))
            : NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.955, alpha: 1))
        let ink = labelColor ?? NSColor.labelColor.withAlphaComponent(0.85)
        let radius = (capHeight / 4).rounded()
        var x = originX(for: intrinsicContentSize.width)
        for keycap in keycaps {
            let key = NSRect(x: x, y: bounds.midY - capHeight / 2 + 1, width: width(of: keycap), height: capHeight)
            x += key.width + spacing
            lip.setFill()
            NSBezierPath(roundedRect: key.offsetBy(dx: 0, dy: -1.5), xRadius: radius, yRadius: radius).fill()
            face?.draw(in: NSBezierPath(roundedRect: key, xRadius: radius, yRadius: radius), angle: -90)
            edge.setStroke()
            let outline = NSBezierPath(roundedRect: key.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5,
                                       yRadius: radius - 0.5)
            outline.lineWidth = 1
            outline.stroke()
            if let name = keycap.symbol,
               let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: fontSize * 0.86, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))) {
                let size = image.size
                image.draw(in: NSRect(x: key.midX - size.width / 2, y: key.midY - size.height / 2,
                                      width: size.width, height: size.height))
            } else {
                let text = NSAttributedString(string: keycap.text, attributes: [
                    .font: font(for: keycap), .foregroundColor: ink,
                ])
                let size = text.size()
                text.draw(at: NSPoint(x: key.midX - size.width / 2, y: key.midY - size.height / 2))
            }
            if keycap.rightSide {
                let badge = NSAttributedString(string: "R", attributes: [
                    .font: NSFont.systemFont(ofSize: max(7, capHeight * 0.22), weight: .bold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                let size = badge.size()
                badge.draw(at: NSPoint(x: key.maxX - size.width - capHeight * 0.1,
                                       y: key.maxY - size.height - capHeight * 0.06))
            }
        }
    }

    private func originX(for width: CGFloat) -> CGFloat {
        switch alignment {
        case .right: bounds.maxX - width
        case .left: bounds.minX
        default: (bounds.midX - width / 2).rounded()
        }
    }
}

// MARK: - Saving

extension DictationShortcut {
    /// Writes the shortcut to the config file and applies it at once. A tap gesture
    /// also goes to `hotkey`, which the service's own listener reads when it runs
    /// without the app.
    @MainActor
    static func save(_ shortcut: Shortcut) -> Bool {
        var values = [(configKey, shortcut.configValue)]
        if case let .taps(taps) = shortcut { values.append(("hotkey", taps.configValue)) }
        // One replacement of the file: never a new dictate beside a stale hotkey.
        guard writeConfigValues(values) else { return false }
        NotificationCenter.default.post(name: .localVoiceShortcutsChanged, object: nil)
        return true
    }
}

// MARK: - Recorder popover

@MainActor
final class ShortcutRecorderViewController: NSViewController {
    var onCommit: ((Shortcut) -> Void)?
    var onClose: (() -> Void)?
    private let current: Shortcut
    private let keys = KeycapRowView(capHeight: 44)
    private let message = NSTextField(labelWithString: "")
    private var monitor: Any?

    /// What Return would save; nil until something valid was pressed.
    private var candidate: Shortcut?
    // Modifiers held now, which of them are the right-hand key, and every modifier
    // held since they were last all up.
    private var held: KeyModifiers = []
    private var heldRight: KeyModifiers = []
    private var peak: KeyModifiers = []
    private var peakRight: KeyModifiers = []
    // A key was pressed while these modifiers were held: the combination, not the
    // modifiers, is what was meant.
    private var keyPressed = false
    // `peak` was held all at once at some point, not only in turns.
    private var peakTogether = false
    // When the current press began: taps are timed by their presses, as the
    // live gesture counts them.
    private var pressTime: TimeInterval = 0
    private var tapModifier: ModifierTapHotkey.Modifier?
    private var tapCount = 0
    private var lastTap: TimeInterval = 0

    private static let tapWindow: TimeInterval = 0.5
    private static let hint = "Press any key combination and hit Return."

    init(current: Shortcut) {
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        message.font = .systemFont(ofSize: 12)
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 2
        message.preferredMaxLayoutWidth = 280
        message.setAccessibilityRole(.staticText)

        let icon = NSImageView(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        let name = Self.footerLabel("Start/Stop Dictation", weight: .medium)
        let save = Self.footerLabel("Save")
        let returnKey = KeycapRowView(capHeight: 18)
        returnKey.keycaps = [Keycap(text: "↩", symbol: "return")]
        let close = Self.footerLabel("Close")
        let escape = KeycapRowView(capHeight: 18)
        escape.keycaps = [Keycap(text: "esc")]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [icon, name, spacer, save, returnKey, close, escape])
        footer.spacing = 6
        footer.setCustomSpacing(12, after: returnKey)

        let rule = NSBox()
        rule.boxType = .separator

        let root = NSView()
        for view in [keys, message, rule, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 360),
            keys.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            keys.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            keys.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            keys.heightAnchor.constraint(equalToConstant: 48),
            message.topAnchor.constraint(equalTo: keys.bottomAnchor, constant: 14),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            message.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            rule.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 16),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),
        ])
        view = root
        show(current.keycaps)
    }

    private static func footerLabel(_ text: String, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: weight)
        label.textColor = .secondaryLabelColor
        return label
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        NotificationCenter.default.post(name: .localVoiceShortcutRecording, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown { self.recordKey(event) } else { self.recordModifiers(event) }
            return nil
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.post(name: .localVoiceShortcutRecording, object: false)
    }

    // MARK: Display

    /// Keys always in the normal key colour; only a refusal turns the line red.
    private func show(_ caps: [Keycap], problem: String? = nil) {
        keys.keycaps = caps
        message.stringValue = problem ?? Self.hint
        message.textColor = problem == nil ? .secondaryLabelColor : .systemRed
        NSAccessibility.post(element: message, notification: .valueChanged)
    }

    private func caps(_ modifiers: KeyModifiers, right: KeyModifiers) -> [Keycap] {
        KeyModifiers.all.filter { modifiers.contains($0.0) }.map {
            Keycap(text: $0.2, symbol: $0.4, rightSide: right.contains($0.0))
        }
    }

    /// Makes `shortcut` what Return saves, or says why it cannot be used.
    private func propose(_ shortcut: Shortcut) {
        if let problem = DictationShortcut.problem(with: shortcut) {
            candidate = nil
            show(shortcut.keycaps, problem: problem)
        } else {
            candidate = shortcut
            show(shortcut.keycaps)
        }
    }

    // MARK: Events

    private static func modifier(for keyCode: UInt16) -> (ModifierTapHotkey.Modifier, right: Bool)? {
        for modifier in ModifierTapHotkey.Modifier.allCases {
            if let index = modifier.keyCodes.firstIndex(of: Int64(keyCode)) { return (modifier, index == 1) }
        }
        return nil
    }

    private func recordModifiers(_ event: NSEvent) {
        guard let (modifier, right) = Self.modifier(for: event.keyCode) else { return }
        let now = KeyModifiers(eventFlags: event.modifierFlags)
        let flag = modifier.modifiers
        if now.contains(flag) && !held.contains(flag) {
            if held.isEmpty {
                // A fresh press: what was pressed before is no longer being built on.
                peak = []
                peakRight = []
                keyPressed = false
                pressTime = ProcessInfo.processInfo.systemUptime
            }
            if right { heldRight.insert(flag) } else { heldRight.remove(flag) }
            peakRight.formUnion(heldRight.intersection(flag))
        } else if !now.contains(flag) {
            heldRight.remove(flag)
        }
        held = now
        let before = peak
        peak.formUnion(now)
        if now == peak {
            peakTogether = true
        } else if peak != before {
            peakTogether = false
        }

        if !held.isEmpty {
            if !keyPressed { show(caps(peak, right: peakRight)) }
            return
        }
        // All modifiers are up again.
        guard !keyPressed else { return }
        if peak.count >= 2 {
            resetTaps()
            if peakTogether {
                propose(.chord(peak))
            } else {
                candidate = nil
                show(caps(peak, right: peakRight), problem: "Hold them all at once.")
            }
        } else if let single = ModifierTapHotkey.Modifier.allCases.first(where: { $0.modifiers == peak }) {
            tapped(single)
        }
    }

    private func tapped(_ modifier: ModifierTapHotkey.Modifier) {
        let time = pressTime
        if tapModifier == modifier && time - lastTap <= Self.tapWindow {
            tapCount += 1
        } else {
            tapModifier = modifier
            tapCount = 1
        }
        lastTap = time
        switch tapCount {
        case 2...4: propose(.taps(ModifierTapHotkey(modifier: modifier, taps: tapCount)))
        case 1:
            candidate = nil
            show(caps(modifier.modifiers, right: peakRight),
                 problem: "Tap it 2–4 times, or press it with another key.")
        default:
            candidate = nil
            show(Shortcut.taps(ModifierTapHotkey(modifier: modifier, taps: 4)).keycaps,
                 problem: "Tap at most four times.")
        }
    }

    private func resetTaps() {
        tapModifier = nil
        tapCount = 0
    }

    private func recordKey(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let modifiers = KeyModifiers(eventFlags: event.modifierFlags)
        if modifiers.isEmpty && event.keyCode == UInt16(KeyCombo.escape.keyCode) {
            dismiss(nil)
            return
        }
        if modifiers.isEmpty && event.keyCode == UInt16(KeyCombo.returnKey.keyCode) {
            if let candidate {
                onCommit?(candidate)
                dismiss(nil)
            } else {
                NSSound.beep()
            }
            return
        }
        resetTaps()
        keyPressed = true
        propose(.combo(KeyCombo(keyCode: Int64(event.keyCode), modifiers: modifiers)))
    }

    #if SETTINGS_PREVIEW
    /// What the popover shows after `shortcut` is pressed, without saving it.
    func previewPress(_ shortcut: Shortcut) {
        _ = view
        propose(shortcut)
    }
    #endif

    override func dismiss(_ sender: Any?) {
        if presentingViewController != nil { super.dismiss(sender) }
        onClose?()
    }
}

// MARK: - Field

/// The control in the Settings row: the shortcut as keys in a rounded field. Click it
/// (or press Space with it focused) to record a new one; the reset button brings back
/// the default.
@MainActor
final class ShortcutRecorderField: NSView, NSPopoverDelegate {
    var onChange: ((Shortcut) -> Void)?
    var shortcut = DictationShortcut.standard {
        didSet { update() }
    }
    private let keys = KeycapRowView(capHeight: 20)
    private let reset = NSButton()
    private var popover: NSPopover?
    private var hovering = false
    private var recording: Bool { popover != nil }

    static let width: CGFloat = 176

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        reset.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset to Default")
        reset.isBordered = false
        reset.imagePosition = .imageOnly
        reset.contentTintColor = .secondaryLabelColor
        reset.target = self
        reset.action = #selector(resetToDefault)
        reset.toolTip = "Reset to \(DictationShortcut.standard.displayName)"
        keys.alignment = .left
        keys.placeholder = "Record Shortcut"
        for view in [keys, reset] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: 28),
            keys.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
            keys.trailingAnchor.constraint(lessThanOrEqualTo: reset.leadingAnchor, constant: -4),
            reset.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            reset.centerYAnchor.constraint(equalTo: centerYAnchor),
            reset.widthAnchor.constraint(equalToConstant: 16),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Dictation shortcut")
        update()
    }

    required init?(coder: NSCoder) { nil }

    private func update() {
        keys.keycaps = shortcut.keycaps
        reset.isHidden = shortcut == DictationShortcut.standard
        setAccessibilityValue(shortcut.spokenName)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // A well, a shade off the card, like the popup buttons beside it.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let shade: CGFloat = (hovering || recording ? 1.6 : 1) * (dark ? 0.07 : 0.045)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        (dark ? NSColor(white: 1, alpha: shade) : NSColor(white: 0, alpha: shade)).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { record() }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityPerformPress() -> Bool { record(); return true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { record() } else { super.keyDown(with: event) }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    private func record() {
        guard popover == nil else { return }
        let recorder = ShortcutRecorderViewController(current: shortcut)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = recorder
        popover.delegate = self
        recorder.onCommit = { [weak self] shortcut in
            guard let self else { return }
            self.shortcut = shortcut
            self.onChange?(shortcut)
        }
        recorder.onClose = { [weak popover] in popover?.performClose(nil) }
        self.popover = popover
        needsDisplay = true
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        needsDisplay = true
    }

    @objc private func resetToDefault() {
        shortcut = DictationShortcut.standard
        onChange?(shortcut)
    }
}
