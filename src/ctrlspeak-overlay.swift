import AppKit

enum OverlayMode: String {
    case recording
    case processing
    case success
    case empty
    case language
    case permission
    case download
    case cancelled
    case clipboard
}

final class RecorderHUDView: NSView {
    var onLanguageToggle: ((String) -> Void)?

    // The native dictation HUD is light frost with dark ink in light mode and
    // the inverse in dark mode. All chrome colors derive from these two.
    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
    }

    private var ink: NSColor {
        isDarkAppearance ? .white : NSColor(calibratedWhite: 0.16, alpha: 1)
    }

    private var accent: NSColor {
        isDarkAppearance
            ? NSColor(calibratedRed: 0.46, green: 0.70, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.09, green: 0.36, blue: 0.87, alpha: 1)
    }

    private(set) var mode: OverlayMode = .recording
    private var targetLevel: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var phase: CGFloat = 0
    private var recordingStartedAt = Date()
    private var animationTimer: Timer?
    private var languageCode = "DE"

    // Progress is nil while the total download size is still unknown, which
    // makes the bar fall back to an indeterminate sweep. The displayed value
    // eases toward the target: Hugging Face's Xet backend materialises the
    // file in large chunk batches, so raw measurements arrive as jumps that
    // would make the bar stutter.
    private var progressFraction: CGFloat?
    private var displayedProgress: CGFloat = 0
    private var detailText = ""

    // Right-aligned with the same 18 pt margin the recording dot gets on the
    // left, independent of the panel width the launch mode chose.
    private var languageBadgeRect: NSRect {
        NSRect(x: bounds.width - 68, y: bounds.midY - 11, width: 50, height: 22)
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

    static let languageCycle = ["DE", "EN", "AUTO"]

    func setLanguage(_ language: String) {
        let requested = language.uppercased()
        languageCode = RecorderHUDView.languageCycle.contains(requested) ? requested : "DE"
        needsDisplay = true
    }

    static func resultTitle(_ mode: OverlayMode) -> String? {
        switch mode {
        case .success: return "Text inserted"
        case .empty: return "No speech detected"
        case .cancelled: return "Recording discarded"
        case .clipboard: return "Copied to clipboard"
        default: return nil
        }
    }

    /// The panel size this state wants: single-line states sit in a flatter
    /// capsule, result states shrink to their text instead of trailing a
    /// stretch of empty pill. nil keeps whatever the panel currently has.
    func desiredSize() -> NSSize? {
        switch mode {
        case .recording, .processing:
            return NSSize(width: 300, height: 44)
        case .permission, .download:
            return NSSize(width: 358, height: 56)
        case .language:
            return nil
        default:
            guard let title = RecorderHUDView.resultTitle(mode) else { return nil }
            let twoLines = !detailText.isEmpty
            let titleFont = NSFont.systemFont(ofSize: twoLines ? 13 : 14, weight: .semibold)
            let titleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
            let detailWidth = twoLines
                ? (detailText as NSString).size(
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium)]
                ).width
                : 0
            let width = max(200, 50 + ceil(max(titleWidth, detailWidth)) + 20)
            return NSSize(width: width, height: twoLines ? 56 : 44)
        }
    }

    func setProgress(_ newProgress: Double?) {
        if let newProgress, newProgress >= 0 {
            progressFraction = CGFloat(max(0, min(1, newProgress)))
        } else {
            progressFraction = nil
        }
        needsDisplay = true
    }

    func setDetail(_ text: String) {
        detailText = text
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

        let cycle = RecorderHUDView.languageCycle
        let next = cycle[((cycle.firstIndex(of: languageCode) ?? 0) + 1) % cycle.count]
        setLanguage(next)
        onLanguageToggle?(next.lowercased())
    }

    @objc private func tick() {
        phase += 0.13
        displayedLevel += (targetLevel - displayedLevel) * 0.24
        targetLevel *= 0.94
        if let target = progressFraction {
            displayedProgress += (target - displayedProgress) * 0.08
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawGlassRim()

        switch mode {
        case .recording:
            drawRecording()
        case .processing:
            drawProcessing()
        case .success:
            drawResult(
                title: RecorderHUDView.resultTitle(mode)!,
                color: NSColor(calibratedRed: 0.24, green: 0.78, blue: 0.50, alpha: 1),
                symbol: "checkmark"
            )
        case .empty:
            drawResult(
                title: RecorderHUDView.resultTitle(mode)!,
                color: NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.15, alpha: 1),
                symbol: "exclamationmark"
            )
        case .cancelled:
            drawResult(
                title: RecorderHUDView.resultTitle(mode)!,
                color: NSColor(calibratedRed: 0.94, green: 0.42, blue: 0.30, alpha: 1),
                symbol: "xmark"
            )
        case .clipboard:
            drawResult(title: RecorderHUDView.resultTitle(mode)!, color: accent, symbol: "checkmark")
        case .language:
            drawLanguageSelection()
        case .permission:
            drawPermission()
        case .download:
            drawDownload()
        }
    }

    // The pulsing red dot alone marks the live recording; a "RECORDING"
    // label would say the same thing again and cost 90 pt of pill width.
    private func drawRecording() {
        let centerY = bounds.midY

        // Soft pulse plus crisp live dot.
        let pulse = (sin(phase * 0.72) + 1) / 2
        let haloRadius = 5.5 + pulse * 2.5
        let haloRect = NSRect(x: 24 - haloRadius, y: centerY - haloRadius, width: haloRadius * 2, height: haloRadius * 2)
        NSColor(calibratedRed: 1, green: 0.25, blue: 0.30, alpha: 0.10 + pulse * 0.10).setFill()
        NSBezierPath(ovalIn: haloRect).fill()

        NSColor(calibratedRed: 1, green: 0.27, blue: 0.31, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 21, y: centerY - 3, width: 6, height: 6)).fill()

        // One shared gap between every neighbour pair — measured to the
        // timer's glyphs, not its layout box, or the right-aligned digits
        // would sit visually farther from the waveform than the dot does.
        let gap: CGFloat = 16
        let dotRightEdge: CGFloat = 27
        let badge = languageBadgeRect

        let seconds = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
        let elapsed = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        let timerFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let timerWidth = ceil((elapsed as NSString).size(withAttributes: [.font: timerFont]).width)
        let timerX = badge.minX - gap - timerWidth

        drawWaveform(in: NSRect(
            x: dotRightEdge + gap,
            y: 8,
            width: timerX - gap - (dotRightEdge + gap),
            height: bounds.height - 16
        ))

        drawText(
            elapsed,
            in: NSRect(x: timerX, y: centerY - 8, width: timerWidth, height: 16),
            font: timerFont,
            color: ink.withAlphaComponent(0.58),
            alignment: .right
        )

        drawLanguageBadge(in: badge)
    }

    // Apple's glass edge is not a uniform outline. The rim reads as the edge
    // of a curved lens: bright where it catches the light along the top,
    // nearly vanishing at the sides, with a fainter counter-glint along the
    // bottom. Layered here as a wide soft glow for thickness, a crisp
    // hairline carrying that dual-glint gradient, and a faint sheen across
    // the upper face of the capsule.
    private func drawGlassRim() {
        let radius = bounds.height / 2

        func ring(_ outerInset: CGFloat, _ innerInset: CGFloat) -> NSBezierPath {
            let outerRect = bounds.insetBy(dx: outerInset, dy: outerInset)
            let innerRect = bounds.insetBy(dx: innerInset, dy: innerInset)
            let path = NSBezierPath(
                roundedRect: outerRect,
                xRadius: radius - outerInset,
                yRadius: radius - outerInset
            )
            path.append(NSBezierPath(
                roundedRect: innerRect,
                xRadius: radius - innerInset,
                yRadius: radius - innerInset
            ))
            path.windingRule = .evenOdd
            return path
        }

        // In light mode the white glints sit on light frost, so a soft dark
        // hairline supplies the definition the highlights cannot.
        if !isDarkAppearance {
            NSGraphicsContext.saveGraphicsState()
            ring(0.5, 1.5).addClip()
            NSColor.black.withAlphaComponent(0.13).setFill()
            bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Wide, soft glow: the apparent thickness of the glass edge.
        NSGraphicsContext.saveGraphicsState()
        ring(0.5, 4.0).addClip()
        NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(0.15), 0.0),
            (NSColor.white.withAlphaComponent(0.02), 0.45),
            (NSColor.white.withAlphaComponent(0.08), 1.0)
        )?.draw(in: bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Crisp hairline: bright top arc, near-invisible sides, faint
        // counter-glint at the bottom.
        NSGraphicsContext.saveGraphicsState()
        ring(0.5, 1.8).addClip()
        NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(0.62), 0.0),
            (NSColor.white.withAlphaComponent(0.11), 0.38),
            (NSColor.white.withAlphaComponent(0.05), 0.66),
            (NSColor.white.withAlphaComponent(0.30), 1.0)
        )?.draw(in: bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Faint sheen on the upper half sells the convex surface.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            xRadius: radius - 1.5,
            yRadius: radius - 1.5
        ).addClip()
        NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(0.08), 0.0),
            (NSColor.white.withAlphaComponent(0.02), 0.35),
            (NSColor.white.withAlphaComponent(0.0), 0.55)
        )?.draw(in: bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
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

            ink.withAlphaComponent(0.30 + 0.55 * energy).setFill()
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
            color: ink.withAlphaComponent(0.88),
            alignment: .left
        )

        // Anchored to the right edge so the row fits the compact panel too.
        let step: CGFloat = 14
        let startX = bounds.width - 24 - 4 * step
        for index in 0..<5 {
            let wave = (sin(phase * 1.45 - CGFloat(index) * 0.72) + 1) / 2
            let radius: CGFloat = 2.2 + wave * 1.35
            let x = startX + CGFloat(index) * step
            accent.withAlphaComponent(0.32 + wave * 0.60).setFill()
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
            accent.withAlphaComponent(alpha).setFill()
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
        } else if symbol == "xmark" {
            mark.move(to: NSPoint(x: 23, y: centerY - 4))
            mark.line(to: NSPoint(x: 31, y: centerY + 4))
            mark.move(to: NSPoint(x: 31, y: centerY - 4))
            mark.line(to: NSPoint(x: 23, y: centerY + 4))
        } else {
            mark.move(to: NSPoint(x: 27, y: centerY + 5))
            mark.line(to: NSPoint(x: 27, y: centerY - 2))
            mark.move(to: NSPoint(x: 27, y: centerY - 6))
            mark.line(to: NSPoint(x: 27, y: centerY - 6.2))
        }
        mark.stroke()

        // Automatic mode reports the language it picked, which needs a second
        // line; without it the title stays vertically centred as before.
        let textWidth = bounds.width - 66

        guard !detailText.isEmpty else {
            drawText(
                title,
                in: NSRect(x: 50, y: centerY - 11, width: textWidth, height: 22),
                font: .systemFont(ofSize: 14, weight: .semibold),
                color: ink.withAlphaComponent(0.92),
                alignment: .left
            )
            return
        }

        drawText(
            title,
            in: NSRect(x: 50, y: 30, width: textWidth, height: 18),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: ink.withAlphaComponent(0.92),
            alignment: .left
        )

        drawText(
            detailText,
            in: NSRect(x: 50, y: 11, width: textWidth, height: 15),
            font: .systemFont(ofSize: 10.5, weight: .medium),
            color: color.withAlphaComponent(0.80),
            alignment: .left
        )
    }

    private func drawLanguageSelection() {
        let centerY = bounds.midY
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

        let languageName: String
        switch languageCode {
        case "EN": languageName = "English"
        case "AUTO": languageName = "Automatic"
        default: languageName = "German"
        }
        drawText(
            "Language: \(languageName)",
            in: NSRect(x: 50, y: centerY - 11, width: 215, height: 22),
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: ink.withAlphaComponent(0.92),
            alignment: .left
        )

        drawLanguageBadge(in: NSRect(x: bounds.width - 68, y: centerY - 11, width: 50, height: 22))
    }

    private func drawPermission() {
        let centerY = bounds.midY
        let amber = NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.28, alpha: 1)

        amber.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: centerY - 11, width: 22, height: 22)).fill()

        // A soft breathing halo keeps the pill readable as a "needs you" state.
        let pulse = (sin(phase * 0.9) + 1) / 2
        amber.withAlphaComponent(0.10 + pulse * 0.12).setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: centerY - 15, width: 30, height: 30)).fill()

        amber.setStroke()
        let mark = NSBezierPath()
        mark.lineWidth = 2
        mark.lineCapStyle = .round
        mark.move(to: NSPoint(x: 27, y: centerY + 6))
        mark.line(to: NSPoint(x: 27, y: centerY - 1))
        mark.move(to: NSPoint(x: 27, y: centerY - 5))
        mark.line(to: NSPoint(x: 27, y: centerY - 5.2))
        mark.stroke()

        drawText(
            "Permissions required",
            in: NSRect(x: 50, y: 30, width: 292, height: 16),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: ink.withAlphaComponent(0.92),
            alignment: .left
        )

        drawText(
            detailText.isEmpty ? "Open System Settings to grant access" : detailText,
            in: NSRect(x: 50, y: 10, width: 292, height: 15),
            font: .systemFont(ofSize: 10.5, weight: .medium),
            color: amber.withAlphaComponent(0.80),
            alignment: .left
        )
    }

    private func drawDownload() {
        let centerY = bounds.midY
        accent.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: centerY - 11, width: 22, height: 22)).fill()

        // Downward arrow, nudged by a slow bob so the pill never looks frozen.
        let bob = sin(phase * 1.15) * 1.2
        accent.setStroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = 1.8
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 27, y: centerY + 5 + bob))
        arrow.line(to: NSPoint(x: 27, y: centerY - 3 + bob))
        arrow.move(to: NSPoint(x: 23, y: centerY + 0.5 + bob))
        arrow.line(to: NSPoint(x: 27, y: centerY - 3.5 + bob))
        arrow.line(to: NSPoint(x: 31, y: centerY + 0.5 + bob))
        arrow.stroke()

        accent.withAlphaComponent(0.55).setStroke()
        let tray = NSBezierPath()
        tray.lineWidth = 1.8
        tray.lineCapStyle = .round
        tray.move(to: NSPoint(x: 22, y: centerY - 6))
        tray.line(to: NSPoint(x: 32, y: centerY - 6))
        tray.stroke()

        drawText(
            "Downloading model",
            in: NSRect(x: 50, y: 32, width: 200, height: 16),
            font: .systemFont(ofSize: 12.5, weight: .semibold),
            color: ink.withAlphaComponent(0.90),
            alignment: .left
        )

        if progressFraction != nil {
            drawText(
                "\(Int((displayedProgress * 100).rounded()))%",
                in: NSRect(x: 252, y: 32, width: 90, height: 16),
                font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                color: ink.withAlphaComponent(0.62),
                alignment: .right
            )
        }

        drawProgressBar(in: NSRect(x: 50, y: 24, width: 292, height: 5))

        if !detailText.isEmpty {
            drawText(
                detailText,
                in: NSRect(x: 50, y: 7, width: 292, height: 14),
                font: .systemFont(ofSize: 10, weight: .regular),
                color: ink.withAlphaComponent(0.55),
                alignment: .left
            )
        }
    }

    private func drawProgressBar(in rect: NSRect) {
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        ink.withAlphaComponent(0.12).setFill()
        track.fill()

        NSGraphicsContext.saveGraphicsState()
        track.addClip()

        let accent = self.accent.withAlphaComponent(0.95)

        if progressFraction != nil {
            let fraction = max(0, min(1, displayedProgress))
            accent.setFill()
            NSBezierPath(rect: NSRect(
                x: rect.minX,
                y: rect.minY,
                width: max(rect.height, rect.width * fraction),
                height: rect.height
            )).fill()

            // Highlight riding the leading edge, so slow downloads still move.
            let shimmer = (sin(phase * 1.6) + 1) / 2
            accent.withAlphaComponent(0.35 + shimmer * 0.4).setFill()
            NSBezierPath(rect: NSRect(
                x: max(rect.minX, rect.minX + rect.width * fraction - 26),
                y: rect.minY,
                width: 26,
                height: rect.height
            )).fill()
        } else {
            let segmentWidth = rect.width * 0.32
            let travel = rect.width + segmentWidth
            let offset = CGFloat(fmod(Double(phase) * 26.0, Double(travel)))
            accent.withAlphaComponent(0.85).setFill()
            NSBezierPath(rect: NSRect(
                x: rect.minX - segmentWidth + offset,
                y: rect.minY,
                width: segmentWidth,
                height: rect.height
            )).fill()
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLanguageBadge(in rect: NSRect) {
        accent.withAlphaComponent(isDarkAppearance ? 0.16 : 0.10).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()

        drawText(
            languageCode,
            in: NSRect(x: rect.minX, y: rect.midY - 7, width: rect.width, height: 15),
            font: .systemFont(ofSize: 10, weight: .bold),
            color: accent.withAlphaComponent(0.96),
            alignment: .center,
            kern: 0.5
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

        // Recording sessions carry only dot, waveform, timer and badge and
        // sit in the flatter capsule; status modes keep the taller panel
        // their two text lines need.
        let compact = launchMode == "recording" || launchMode == "preview"
        let panelSize = compact
            ? NSSize(width: 300, height: 44)
            : NSSize(width: 358, height: launchMode == "language" ? 44 : 56)
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

        // With .behindWindow blending the material is composited by the window
        // server, outside this view's Core Animation layer. A layer mask
        // therefore does not clip it: the blur bleeds into the four corners
        // and reads as white over light backgrounds. maskImage is the shape
        // the window server itself honours.
        visualEffect.maskImage = OverlayController.capsuleMask(size: panelSize)

        // The frosted look comes from the material itself: a faint white lift
        // instead of the old near-black tint, so the backdrop shows through
        // the blur the way the native dictation HUD lets it. The rim is drawn
        // by the HUD view as a lit glass edge instead of a flat layer border.
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = panelSize.height / 2
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.07).cgColor

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
            // Status modes must paint immediately; waiting for the first
            // command would flash the recording UI for a frame.
            if let initialMode = OverlayMode(rawValue: launchMode) {
                hudView.setMode(initialMode)
                if initialMode == .download {
                    hudView.setProgress(nil)
                }
            }
            startReadingCommands()
        }
    }

    /// Capsule the window server can use to clip the blur material.
    ///
    /// The cap insets preserve the rounded ends while the straight middle
    /// stretches, so the same mask stays clean while the panel animates to a
    /// different width. Height changes need a fresh mask (the radius is tied
    /// to it), which resizePanel takes care of.
    private static func capsuleMask(size: NSSize) -> NSImage {
        let mask = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: rect.height / 2,
                yRadius: rect.height / 2
            ).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(
            top: 0,
            left: size.height / 2 + 1,
            bottom: 0,
            right: size.height / 2 + 1
        )
        mask.resizingMode = .stretch
        return mask
    }

    /// Morph the panel to the size the current state wants, keeping it
    /// horizontally centred and anchored to the bottom edge.
    private func syncPanelSize() {
        guard let wanted = hudView.desiredSize() else { return }

        var frame = panel.frame
        guard abs(frame.width - wanted.width) > 1 || abs(frame.height - wanted.height) > 1 else {
            return
        }

        if abs(frame.height - wanted.height) > 1,
           let visualEffect = panel.contentView as? NSVisualEffectView {
            visualEffect.maskImage = OverlayController.capsuleMask(size: wanted)
            visualEffect.layer?.cornerRadius = wanted.height / 2
        }

        frame.origin.x += (frame.width - wanted.width) / 2
        frame.size.width = wanted.width
        frame.size.height = wanted.height
        panel.setFrame(frame, display: true, animate: true)
        panel.invalidateShadow()
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
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            // The shadow shape is derived from the rendered alpha and cached,
            // so it has to be recomputed once the capsule is fully opaque.
            self?.panel.invalidateShadow()
        })
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
            syncPanelSize()

            switch newMode {
            case .success:
                close(after: 1.35)
            case .empty:
                close(after: 1.8)
            case .cancelled:
                close(after: 1.2)
            case .clipboard:
                close(after: 1.8)
            default:
                break
            }
        case "progress":
            // "progress" without a value, or a negative one, means indeterminate.
            hudView.setProgress(parts.count == 2 ? Double(parts[1]) : nil)
        case "detail":
            hudView.setDetail(parts.count == 2 ? parts[1] : "")
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
                self.syncPanelSize()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    self.hudView.setMode(.success)
                    self.syncPanelSize()
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
