import AppKit

enum OverlayMode: String {
    case recording
    case processing
    case success
    case empty
    case language
}

final class RecorderHUDView: NSView {
    var onLanguageToggle: ((String) -> Void)?

    private(set) var mode: OverlayMode = .recording
    private var targetLevel: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var phase: CGFloat = 0
    private var recordingStartedAt = Date()
    private var animationTimer: Timer?
    private var languageCode = "DE"

    private var languageBadgeRect: NSRect {
        NSRect(x: 289, y: bounds.midY - 11, width: 58, height: 22)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let timer = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        animationTimer?.invalidate()
    }

    func setMode(_ newMode: OverlayMode) {
        mode = newMode
        if newMode == .recording {
            recordingStartedAt = Date()
        }
        needsDisplay = true
    }

    func setLevel(_ newLevel: Double) {
        targetLevel = CGFloat(max(0, min(1, newLevel)))
    }

    func setLanguage(_ language: String) {
        languageCode = language.uppercased() == "EN" ? "EN" : "DE"
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if mode == .recording {
            addCursorRect(languageBadgeRect, cursor: .pointingHand)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .recording else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard languageBadgeRect.contains(point) else { return }

        let newLanguage = languageCode == "DE" ? "EN" : "DE"
        setLanguage(newLanguage)
        onLanguageToggle?(newLanguage.lowercased())
    }

    @objc private func tick() {
        phase += 0.13
        displayedLevel += (targetLevel - displayedLevel) * 0.24
        targetLevel *= 0.94
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        switch mode {
        case .recording:
            drawRecording()
        case .processing:
            drawProcessing()
        case .success:
            drawResult(
                title: "Text inserted",
                color: NSColor(calibratedRed: 0.30, green: 0.88, blue: 0.57, alpha: 1),
                symbol: "checkmark"
            )
        case .empty:
            drawResult(
                title: "No speech detected",
                color: NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.28, alpha: 1),
                symbol: "exclamationmark"
            )
        case .language:
            drawLanguageSelection()
        }
    }

    private func drawRecording() {
        let centerY = bounds.midY

        // Soft pulse plus crisp live dot.
        let pulse = (sin(phase * 0.72) + 1) / 2
        let haloRadius = 5.5 + pulse * 2.5
        let haloRect = NSRect(x: 21 - haloRadius, y: centerY - haloRadius, width: haloRadius * 2, height: haloRadius * 2)
        NSColor(calibratedRed: 1, green: 0.25, blue: 0.30, alpha: 0.10 + pulse * 0.10).setFill()
        NSBezierPath(ovalIn: haloRect).fill()

        NSColor(calibratedRed: 1, green: 0.27, blue: 0.31, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: centerY - 3, width: 6, height: 6)).fill()

        drawText(
            "RECORDING",
            in: NSRect(x: 34, y: centerY - 8, width: 76, height: 16),
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.72),
            alignment: .left,
            kern: 0.8
        )

        drawWaveform(in: NSRect(x: 108, y: 10, width: 119, height: 36))

        let seconds = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
        let elapsed = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        drawText(
            elapsed,
            in: NSRect(x: 235, y: centerY - 8, width: 47, height: 16),
            font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            color: NSColor.white.withAlphaComponent(0.58),
            alignment: .right
        )

        drawLanguageBadge(in: languageBadgeRect)
    }

    private func drawWaveform(in rect: NSRect) {
        let barCount = 19
        let barWidth: CGFloat = 3
        let gap = (rect.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)
        let energy = max(0.07, min(1, displayedLevel))

        for index in 0..<barCount {
            let normalizedIndex = CGFloat(index) / CGFloat(barCount - 1)
            let centerEnvelope = 0.52 + 0.48 * sin(normalizedIndex * .pi)
            let motion = 0.44 + 0.56 * abs(sin(phase * 1.28 + CGFloat(index) * 0.71))
            let secondaryMotion = 0.72 + 0.28 * abs(cos(phase * 0.83 - CGFloat(index) * 0.39))
            let height = max(3, 3 + (rect.height - 3) * energy * centerEnvelope * motion * secondaryMotion)
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let y = rect.midY - height / 2

            let accent = 0.56 + 0.38 * energy
            NSColor(calibratedRed: accent, green: 0.74 + energy * 0.16, blue: 1, alpha: 0.82).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barWidth, height: height),
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            ).fill()
        }
    }

    private func drawProcessing() {
        let centerY = bounds.midY
        drawSpinner(center: NSPoint(x: 27, y: centerY))

        drawText(
            "Transcribing",
            in: NSRect(x: 46, y: centerY - 10, width: 142, height: 20),
            font: .systemFont(ofSize: 13.5, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.88),
            alignment: .left
        )

        let startX: CGFloat = 223
        for index in 0..<5 {
            let wave = (sin(phase * 1.45 - CGFloat(index) * 0.72) + 1) / 2
            let radius: CGFloat = 2.2 + wave * 1.35
            let x = startX + CGFloat(index) * 15
            NSColor(calibratedRed: 0.46, green: 0.70, blue: 1, alpha: 0.32 + wave * 0.60).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - radius, y: centerY - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }

    private func drawSpinner(center: NSPoint) {
        let segmentCount = 9
        for index in 0..<segmentCount {
            let angle = (CGFloat(index) / CGFloat(segmentCount)) * .pi * 2
            let animatedHead = Int(phase * 2.3) % segmentCount
            let distance = (index - animatedHead + segmentCount) % segmentCount
            let alpha = max(0.16, 1 - CGFloat(distance) / CGFloat(segmentCount))
            let radius: CGFloat = 7
            let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            NSColor(calibratedRed: 0.47, green: 0.71, blue: 1, alpha: alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 1.4, y: point.y - 1.4, width: 2.8, height: 2.8)).fill()
        }
    }

    private func drawResult(title: String, color: NSColor, symbol: String) {
        let centerY = bounds.midY
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: centerY - 11, width: 22, height: 22)).fill()

        color.setStroke()
        let mark = NSBezierPath()
        mark.lineWidth = 2
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round

        if symbol == "checkmark" {
            mark.move(to: NSPoint(x: 22, y: centerY))
            mark.line(to: NSPoint(x: 26, y: centerY - 4))
            mark.line(to: NSPoint(x: 33, y: centerY + 5))
        } else {
            mark.move(to: NSPoint(x: 27, y: centerY + 5))
            mark.line(to: NSPoint(x: 27, y: centerY - 2))
            mark.move(to: NSPoint(x: 27, y: centerY - 6))
            mark.line(to: NSPoint(x: 27, y: centerY - 6.2))
        }
        mark.stroke()

        drawText(
            title,
            in: NSRect(x: 50, y: centerY - 11, width: 260, height: 22),
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.90),
            alignment: .left
        )
    }

    private func drawLanguageSelection() {
        let centerY = bounds.midY
        let accent = NSColor(calibratedRed: 0.46, green: 0.70, blue: 1, alpha: 1)

        accent.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: centerY - 11, width: 22, height: 22)).fill()

        accent.setStroke()
        let globe = NSBezierPath(ovalIn: NSRect(x: 21, y: centerY - 6, width: 12, height: 12))
        globe.lineWidth = 1.3
        globe.stroke()

        let meridian = NSBezierPath()
        meridian.move(to: NSPoint(x: 27, y: centerY - 6))
        meridian.curve(
            to: NSPoint(x: 27, y: centerY + 6),
            controlPoint1: NSPoint(x: 23.5, y: centerY - 2),
            controlPoint2: NSPoint(x: 23.5, y: centerY + 2)
        )
        meridian.stroke()

        let languageName = languageCode == "EN" ? "English" : "German"
        drawText(
            "Language: \(languageName)",
            in: NSRect(x: 50, y: centerY - 11, width: 215, height: 22),
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.90),
            alignment: .left
        )

        drawLanguageBadge(in: NSRect(x: 299, y: centerY - 10, width: 42, height: 20))
    }

    private func drawLanguageBadge(in rect: NSRect) {
        NSColor(calibratedRed: 0.46, green: 0.70, blue: 1, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()

        drawText(
            languageCode == "EN" ? "🇬🇧  EN" : "🇩🇪  DE",
            in: NSRect(x: rect.minX, y: rect.midY - 7, width: rect.width, height: 15),
            font: .systemFont(ofSize: 10, weight: .bold),
            color: NSColor(calibratedRed: 0.64, green: 0.80, blue: 1, alpha: 0.96),
            alignment: .center,
            kern: 0
        )
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        kern: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: kern,
        ]
        NSAttributedString(string: text, attributes: attributes).draw(in: rect)
    }
}

final class OverlayController: NSObject {
    private let application: NSApplication
    private let panel: NSPanel
    private let hudView: RecorderHUDView
    private var inputBuffer = Data()
    private var isClosing = false
    private var previewTimer: Timer?

    init(application: NSApplication, launchMode: String, language: String) {
        self.application = application

        let panelSize = NSSize(width: 358, height: 56)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = panelSize.height / 2
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 0.74).cgColor
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        visualEffect.layer?.borderWidth = 0.7

        hudView = RecorderHUDView(frame: visualEffect.bounds)
        hudView.setLanguage(language)
        hudView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hudView)

        super.init()

        hudView.onLanguageToggle = { language in
            FileHandle.standardOutput.write(Data("language \(language)\n".utf8))
        }

        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = visualEffect

        positionPanel(panelSize: panelSize)
        showPanel()

        if launchMode == "preview" {
            startPreview()
        } else if launchMode == "language" {
            hudView.setMode(.language)
            close(after: 1.5)
        } else {
            startReadingCommands()
        }
    }

    private func positionPanel(panelSize: NSSize) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.minY + 24
            )
        )
    }

    private func showPanel() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func startReadingCommands() {
        let input = FileHandle.standardInput
        input.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                DispatchQueue.main.async {
                    self?.close()
                }
                return
            }

            DispatchQueue.main.async {
                self?.consume(data)
            }
        }
    }

    private func consume(_ data: Data) {
        inputBuffer.append(data)

        while let newline = inputBuffer.firstIndex(of: 0x0A) {
            let lineData = inputBuffer[..<newline]
            inputBuffer.removeSubrange(...newline)

            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handle(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func handle(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let action = parts.first else { return }

        switch action {
        case "level" where parts.count == 2:
            if let value = Double(parts[1]) {
                hudView.setLevel(value)
            }
        case "state" where parts.count == 2:
            guard let newMode = OverlayMode(rawValue: parts[1]) else { return }
            hudView.setMode(newMode)

            if newMode == .success {
                close(after: 1.35)
            } else if newMode == .empty {
                close(after: 1.8)
            }
        case "quit":
            close()
        default:
            break
        }
    }

    private func startPreview() {
        let startedAt = Date()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            let simulated = 0.18 + 0.68 * abs(sin(elapsed * 3.1)) * (0.65 + 0.35 * abs(cos(elapsed * 1.7)))
            self.hudView.setLevel(simulated)

            if elapsed > 3.5 {
                timer.invalidate()
                self.hudView.setMode(.processing)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    self.hudView.setMode(.success)
                    self.close(after: 1.35)
                }
            }
        }
    }

    private func close(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.close()
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        FileHandle.standardInput.readabilityHandler = nil
        previewTimer?.invalidate()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.application.terminate(nil)
        })
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()

let arguments = Array(CommandLine.arguments.dropFirst())
let launchMode = arguments.first ?? "recording"
let language = arguments.count > 1 ? arguments[1] : "de"
let controller = OverlayController(
    application: application,
    launchMode: launchMode,
    language: language
)
withExtendedLifetime(controller) {
    application.run()
}
