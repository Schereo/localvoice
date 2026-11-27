import AppKit

/// Corner radius for a capsule of the given height. Half the height up to
/// the 56 pt status pill — the classic capsule — but capped beyond that: the
/// recording pill grown around a live transcript reads as a rounded card,
/// not a lozenge.
func capsuleRadius(forHeight height: CGFloat) -> CGFloat {
    min(height / 2, 28)
}

enum OverlayMode: String {
    // On screen the moment the hotkey fires, while the microphone opens: a
    // small circle that grows into the recording pill once capture is live.
    case arming
    case recording
    case processing
    case success
    case empty
    case permission
    case download
    case cancelled
    case clipboard
    case error
    case failed
}

final class RecorderHUDView: NSView {
    // Faded in while the capsule grows from the arming circle into the pill,
    // so dot, waveform and timer never show squeezed into a narrow capsule.
    var contentAlpha: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

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

    // Progress is nil while the total download size is still unknown, which
    // makes the bar fall back to an indeterminate sweep. The displayed value
    // eases toward the target: Hugging Face's Xet backend materialises the
    // file in large chunk batches, so raw measurements arrive as jumps that
    // would make the bar stutter.
    private var progressFraction: CGFloat?
    private var displayedProgress: CGFloat = 0
    private var detailText = ""

    // The live transcript, split into what is settled and what may still
    // change: confirmed text is every phrase the model has finished, the
    // partial is its current guess at the phrase being spoken. Only the
    // recording state draws them; the capsule grows to fit up to two lines.
    private var finalTranscript = ""
    private var partialTranscript = ""
    private var transcriptCacheKey = ""
    private var transcriptCache: (text: NSAttributedString, lines: Int)?

    // Recording chrome (dot, waveform, timer) lives in the bottom
    // 44 pt band. With no transcript the capsule *is* that band; with text
    // the capsule grows upward while the band — and so the chrome — stays
    // put on screen.
    private static let controlBandHeight: CGFloat = 44
    private var controlBandMidY: CGFloat { RecorderHUDView.controlBandHeight / 2 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        startAnimating()
    }

    /// The 30 Hz animation clock. A standby pill waits hidden, possibly for
    /// hours, and must not wake the CPU thirty times a second meanwhile.
    func startAnimating() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        animationTimer?.invalidate()
    }

    func setMode(_ newMode: OverlayMode) {
        // The check continues the spinner's stroke, so it needs to know where
        // the arc was when the text landed.
        spinnerExit = mode == .processing && newMode == .success
            ? (head: spinnerHead, length: spinnerLength)
            : nil
        mode = newMode
        modeChangedAt = Date()
        if newMode == .recording {
            recordingStartedAt = Date()
        }
        needsDisplay = true
    }

    private var modeChangedAt = Date()
    private var spinnerExit: (head: CGFloat, length: CGFloat)?

    // The transcribing arc: about one turn a second, clockwise, its length
    // breathing a little so it never reads as a stuck system spinner.
    private static let spinnerRadius: CGFloat = 12.5
    private var spinnerHead: CGFloat { -phase * 1.6 }
    private var spinnerLength: CGFloat { 1.5 + 0.45 * sin(phase * 0.7) }

    func setLevel(_ newLevel: Double) {
        targetLevel = CGFloat(max(0, min(1, newLevel)))
    }

    /// Update one half of the live transcript; nil leaves that half alone.
    func setTranscript(final: String?, partial: String?) {
        if let final { finalTranscript = final }
        if let partial { partialTranscript = partial }
        transcriptCache = nil
        transcriptCacheKey = ""
        needsDisplay = true
    }

    private var hasTranscript: Bool {
        !finalTranscript.isEmpty || !partialTranscript.isEmpty
    }

    private static let transcriptFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)

    private var transcriptLineHeight: CGFloat {
        let font = RecorderHUDView.transcriptFont
        return ceil(font.ascender - font.descender + font.leading) + 1
    }

    /// The suffix of the transcript that fits `maxLines` at `width`, with the
    /// confirmed part in full ink and the live guess dimmed. Old words fall
    /// off the front (marked by an ellipsis) so the newest are always visible.
    private func fittedTranscript(width: CGFloat, maxLines: Int) -> (text: NSAttributedString, lines: Int)? {
        guard hasTranscript, width > 40 else { return nil }

        let cacheKey = "\(width)|\(isDarkAppearance)|\(finalTranscript)\u{1}\(partialTranscript)"
        if cacheKey == transcriptCacheKey, let cached = transcriptCache {
            return cached
        }

        var words: [(text: Substring, isFinal: Bool)] = []
        words.append(contentsOf: finalTranscript.split(separator: " ").map { ($0, true) })
        words.append(contentsOf: partialTranscript.split(separator: " ").map { ($0, false) })
        guard !words.isEmpty else { return nil }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping

        func attributed(droppingFirst dropped: Int) -> NSAttributedString {
            let visible = words[dropped...]
            let result = NSMutableAttributedString()
            for (index, word) in visible.enumerated() {
                var piece = index == 0 && dropped > 0 ? "…" + word.text : String(word.text)
                if index < visible.count - 1 { piece += " " }
                result.append(NSAttributedString(string: piece, attributes: [
                    .font: RecorderHUDView.transcriptFont,
                    .foregroundColor: ink.withAlphaComponent(word.isFinal ? 0.90 : 0.42),
                    .paragraphStyle: paragraph,
                ]))
            }
            return result
        }

        func lineCount(_ text: NSAttributedString) -> Int {
            let bounds = text.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            )
            return max(1, Int((bounds.height / transcriptLineHeight).rounded()))
        }

        // Binary search for the fewest dropped words that still fit: the
        // transcript of a long dictation is measured O(log n) times per
        // update instead of once per word.
        var low = 0
        var high = words.count - 1
        while low < high {
            let middle = (low + high) / 2
            if lineCount(attributed(droppingFirst: middle)) <= maxLines {
                high = middle
            } else {
                low = middle + 1
            }
        }

        let text = attributed(droppingFirst: low)
        let fitted = (text: text, lines: min(maxLines, lineCount(text)))
        transcriptCacheKey = cacheKey
        transcriptCache = fitted
        return fitted
    }

    static func resultTitle(_ mode: OverlayMode) -> String? {
        switch mode {
        case .success: return "Text inserted"
        case .empty: return "No speech detected"
        case .failed: return "Transcription failed"
        case .cancelled: return "Recording discarded"
        case .clipboard: return "Copied"
        case .error: return "LocalVoice is restarting"
        default: return nil
        }
    }

    // The transient pills' shared layout contract, used by desiredSize()
    // (which measures) and the draw functions (which render) — one source,
    // so the capsule can never measure with one font and draw with another.
    static let processingCapsuleWidth: CGFloat = 120
    static let quietTextX: CGFloat = 46
    static let quietRightMargin: CGFloat = 16
    static let quietDetailFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    static func quietTitleFont(twoLines: Bool) -> NSFont {
        .systemFont(ofSize: twoLines ? 12 : 12.5, weight: .regular)
    }

    /// The panel size this state wants: single-line states sit in a flatter
    /// capsule, result states shrink to their text instead of trailing a
    /// stretch of empty pill. nil keeps whatever the panel currently has.
    func desiredSize() -> NSSize? {
        switch mode {
        case .recording:
            guard hasTranscript else {
                return NSSize(width: 240, height: 44)
            }
            // With live text the capsule widens for a readable line and grows
            // upward: 44 pt control band + text lines + 10 pt top inset.
            let width: CGFloat = 340
            let lines = fittedTranscript(width: width - 48, maxLines: 2)?.lines ?? 1
            return NSSize(
                width: width,
                height: RecorderHUDView.controlBandHeight + CGFloat(lines) * transcriptLineHeight + 10
            )
        case .permission, .download:
            return NSSize(width: 358, height: 56)
        case .arming, .processing, .success, .cancelled:
            // Circles: the controller sizes them itself, centred on the band.
            return nil
        default:
            guard let title = RecorderHUDView.resultTitle(mode) else { return nil }
            let twoLines = !detailText.isEmpty
            let titleFont = RecorderHUDView.quietTitleFont(twoLines: twoLines)
            let titleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
            let detailWidth = twoLines
                ? (detailText as NSString).size(
                    withAttributes: [.font: RecorderHUDView.quietDetailFont]
                ).width
                : 0
            // Hug the text: a fixed floor left the leftover width as dead
            // space on the right of short titles. The processing width as the
            // floor keeps the result from dipping below the capsule it
            // morphs out of.
            let width = max(
                RecorderHUDView.processingCapsuleWidth,
                RecorderHUDView.quietTextX
                    + ceil(max(titleWidth, detailWidth))
                    + RecorderHUDView.quietRightMargin
            )
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

        let context = NSGraphicsContext.current?.cgContext
        let faded = contentAlpha < 1
        if faded {
            context?.saveGState()
            context?.setAlpha(max(0, contentAlpha))
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer {
            if faded {
                context?.endTransparencyLayer()
                context?.restoreGState()
            }
        }

        switch mode {
        case .arming:
            drawArming()
        case .recording:
            drawRecording()
        case .processing:
            drawProcessing()
        case .success:
            drawOutcomeMark(.check)
        case .empty, .failed:
            drawResult(
                title: RecorderHUDView.resultTitle(mode)!,
                color: NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.15, alpha: 1),
                symbol: "exclamationmark"
            )
        case .cancelled:
            drawOutcomeMark(.cross)
        case .clipboard:
            drawResult(title: RecorderHUDView.resultTitle(mode)!, color: accent, symbol: "checkmark")
        case .error:
            drawResult(
                title: RecorderHUDView.resultTitle(mode)!,
                color: NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.15, alpha: 1),
                symbol: "exclamationmark"
            )
        case .permission:
            drawPermission()
        case .download:
            drawDownload()
        }
    }

    // The microphone is not open yet, so this is deliberately not the red
    // recording dot: a quiet breathing point says "heard you, getting ready".
    private func drawArming() {
        let pulse = 0.5 + 0.5 * sin(phase * 0.9)
        let radius: CGFloat = 3.2 + 0.9 * pulse
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        ink.withAlphaComponent(0.32 + 0.30 * pulse).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )).fill()
    }

    // The pulsing red dot alone marks the live recording; a "RECORDING"
    // label would say the same thing again and cost 90 pt of pill width.
    // Chrome sits in the bottom control band; the live transcript, when
    // there is one, fills the space the capsule grew above it.
    private func drawRecording() {
        let centerY = controlBandMidY

        if hasTranscript {
            let textRect = NSRect(
                x: 24,
                y: RecorderHUDView.controlBandHeight,
                width: bounds.width - 48,
                height: bounds.height - RecorderHUDView.controlBandHeight - 10
            )
            fittedTranscript(width: textRect.width, maxLines: 2)?.text.draw(in: textRect)
        }

        // Soft pulse plus crisp live dot, anchored on the control band's
        // left edge with the same margin the result icons use.
        let pulse = (sin(phase * 0.72) + 1) / 2
        let haloRadius = 5.5 + pulse * 2.5
        let haloRect = NSRect(x: 27 - haloRadius, y: centerY - haloRadius, width: haloRadius * 2, height: haloRadius * 2)
        NSColor(calibratedRed: 1, green: 0.25, blue: 0.30, alpha: 0.10 + pulse * 0.10).setFill()
        NSBezierPath(ovalIn: haloRect).fill()

        NSColor(calibratedRed: 1, green: 0.27, blue: 0.31, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 24, y: centerY - 3, width: 6, height: 6)).fill()

        // One shared gap between every neighbour pair — measured to the
        // timer's glyphs, not its layout box, or the right-aligned digits
        // would sit visually farther from the waveform than the dot does.
        let gap: CGFloat = 16
        let dotRightEdge: CGFloat = 30

        let seconds = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
        let elapsed = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        let timerFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let timerWidth = ceil((elapsed as NSString).size(withAttributes: [.font: timerFont]).width)
        // The same 18 pt margin on the right as the recording dot's on the left.
        let timerX = bounds.width - 18 - timerWidth

        drawWaveform(in: NSRect(
            x: dotRightEdge + gap,
            y: 8,
            width: timerX - gap - (dotRightEdge + gap),
            height: RecorderHUDView.controlBandHeight - 16
        ))

        drawCenteredText(
            elapsed,
            centeredIn: NSRect(x: timerX, y: centerY - 8, width: timerWidth, height: 16),
            font: timerFont,
            color: ink.withAlphaComponent(0.58),
            alignment: .right
        )
    }

    // Apple's glass edge is not a uniform outline. The rim reads as the edge
    // of a curved lens: bright where it catches the light along the top,
    // nearly vanishing at the sides, with a fainter counter-glint along the
    // bottom. Layered here as a wide soft glow for thickness, a crisp
    // hairline carrying that dual-glint gradient, and a faint sheen across
    // the upper face of the capsule.
    private func drawGlassRim() {
        let radius = capsuleRadius(forHeight: bounds.height)

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

    // One animation, nothing else: the pulsing dot row, centred. A spinner
    // plus a label plus the dots said "loading" three times over, for a state
    // that lasts about a second.
    // Transcribing: the pill has folded into a circle and a neutral arc runs
    // round it. Waiting is neither good nor bad news, so it has no colour.
    private func drawProcessing() {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        strokeArc(center: center, radius: RecorderHUDView.spinnerRadius,
                  head: spinnerHead, length: spinnerLength,
                  color: ink.withAlphaComponent(0.55), width: 2.2)
    }

    /// An arc whose leading end is `head` (radians, travelling clockwise)
    /// and which trails `length` radians behind it.
    private func strokeArc(center: NSPoint, radius: CGFloat, head: CGFloat, length: CGFloat,
                           color: NSColor, width: CGFloat) {
        guard length > 0.01 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: head * 180 / .pi, endAngle: (head + length) * 180 / .pi,
                      clockwise: false)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    enum OutcomeMark { case check, cross }

    // Outcomes the user expected need no words: the pill folds into a circle
    // and a mark draws itself in, straight on the glass like the dots and the
    // waveform: inserted is a green check, discarded (Esc) a red cross.
    // Outcomes that differ from what the user expected keep their label.
    private func drawOutcomeMark(_ kind: OutcomeMark) {
        let color = kind == .check
            ? emphasized(NSColor(calibratedRed: 0.24, green: 0.78, blue: 0.50, alpha: 1))
            : emphasized(NSColor(calibratedRed: 0.94, green: 0.42, blue: 0.30, alpha: 1))
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let elapsed = Date().timeIntervalSince(modeChangedAt)

        // Coming from the spinner, the arc spirals inward, turns green and
        // lands where the check starts; the check then carries on from that
        // point, so the two read as one stroke.
        var markDelay = 0.06
        if kind == .check, let exit = spinnerExit {
            let handoff = 0.26
            markDelay = handoff * 0.8
            let u = CGFloat(min(1, elapsed / handoff))
            if u < 1 {
                let e = u * u * (3 - 2 * u)
                // Clockwise to the check's start at 180°, at least a third of a turn on.
                var travel = (exit.head - .pi).truncatingRemainder(dividingBy: 2 * .pi)
                if travel < 0 { travel += 2 * .pi }
                if travel < 2.1 { travel += 2 * .pi }
                let start = ink.withAlphaComponent(0.55)
                strokeArc(center: center,
                          radius: RecorderHUDView.spinnerRadius + (6.6 - RecorderHUDView.spinnerRadius) * e,
                          head: exit.head - travel * e,
                          length: exit.length * (1 - e),
                          color: start.blended(withFraction: e, of: color) ?? color,
                          width: 2.2 + 0.4 * e)
            }
        }

        // Stroke the mark progressively over 0.28 s.
        let t = CGFloat(max(0, min(1, (elapsed - markDelay) / 0.28)))
        let progress = 1 - pow(1 - t, 3)
        // The check is about 15 x 11 pt, optically centred (the long stroke
        // pulls right). The cross is two 10 pt strokes, drawn one after the other.
        let points: [NSPoint]
        let segments: [(Int, Int)]
        switch kind {
        case .check:
            points = [
                NSPoint(x: center.x - 6.6, y: center.y),
                NSPoint(x: center.x - 1.9, y: center.y - 4.6),
                NSPoint(x: center.x + 7.0, y: center.y + 5.6),
            ]
            segments = [(0, 1), (1, 2)]
        case .cross:
            points = [
                NSPoint(x: center.x - 5, y: center.y + 5),
                NSPoint(x: center.x + 5, y: center.y - 5),
                NSPoint(x: center.x + 5, y: center.y + 5),
                NSPoint(x: center.x - 5, y: center.y - 5),
            ]
            segments = [(0, 1), (2, 3)]
        }
        let lengths = segments.map { hypot(points[$0.1].x - points[$0.0].x, points[$0.1].y - points[$0.0].y) }
        var remaining = lengths.reduce(0, +) * progress
        guard remaining > 0 else { return }

        let mark = NSBezierPath()
        mark.lineWidth = kind == .check ? 2.6 : 2.2
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        for (index, segment) in segments.enumerated() {
            let from = points[segment.0], to = points[segment.1]
            let step = min(remaining, lengths[index])
            let fraction = step / lengths[index]
            // A polyline continues from where it is; a new stroke starts fresh.
            if index == 0 || segment.0 != segments[index - 1].1 {
                mark.move(to: from)
            }
            mark.line(to: NSPoint(x: from.x + (to.x - from.x) * fraction,
                                  y: from.y + (to.y - from.y) * fraction))
            remaining -= step
            if remaining <= 0 { break }
        }
        color.setStroke()
        mark.stroke()
    }

    private func drawResult(title: String, color rawColor: NSColor, symbol: String) {
        let centerY = bounds.midY
        let color = emphasized(rawColor)
        color.withAlphaComponent(0.20).setFill()
        NSBezierPath(ovalIn: NSRect(x: 17, y: centerY - 9, width: 18, height: 18)).fill()

        color.setStroke()
        let mark = NSBezierPath()
        mark.lineWidth = 1.7
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round

        if symbol == "checkmark" {
            mark.move(to: NSPoint(x: 22, y: centerY))
            mark.line(to: NSPoint(x: 25.2, y: centerY - 3.2))
            mark.line(to: NSPoint(x: 30.8, y: centerY + 4))
        } else if symbol == "xmark" {
            mark.move(to: NSPoint(x: 22.8, y: centerY - 3.2))
            mark.line(to: NSPoint(x: 29.2, y: centerY + 3.2))
            mark.move(to: NSPoint(x: 29.2, y: centerY - 3.2))
            mark.line(to: NSPoint(x: 22.8, y: centerY + 3.2))
        } else {
            mark.move(to: NSPoint(x: 26, y: centerY + 4))
            mark.line(to: NSPoint(x: 26, y: centerY - 1.5))
            mark.move(to: NSPoint(x: 26, y: centerY - 4.6))
            mark.line(to: NSPoint(x: 26, y: centerY - 4.8))
        }
        mark.stroke()

        // Automatic mode reports the language it picked, which needs a second
        // line; without it the title stays vertically centred as before.
        let textX = RecorderHUDView.quietTextX
        let textWidth = bounds.width - textX - RecorderHUDView.quietRightMargin

        guard !detailText.isEmpty else {
            drawCenteredText(
                title,
                centeredIn: NSRect(x: textX, y: centerY - 10, width: textWidth, height: 20),
                font: RecorderHUDView.quietTitleFont(twoLines: false),
                color: ink.withAlphaComponent(0.90),
                alignment: .left
            )
            return
        }

        drawText(
            title,
            in: NSRect(x: textX, y: 30, width: textWidth, height: 17),
            font: RecorderHUDView.quietTitleFont(twoLines: true),
            color: ink.withAlphaComponent(0.90),
            alignment: .left
        )

        drawText(
            detailText,
            in: NSRect(x: textX, y: 11, width: textWidth, height: 15),
            font: RecorderHUDView.quietDetailFont,
            color: emphasized(color),
            alignment: .left
        )
    }

    /// Semantic colors tuned per appearance: darkened on light frost, where
    /// the pastel variants lose almost all contrast.
    private func emphasized(_ color: NSColor) -> NSColor {
        isDarkAppearance
            ? color
            : color.blended(withFraction: 0.38, of: .black) ?? color
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
            in: NSRect(x: 50, y: 30, width: 290, height: 18),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: ink.withAlphaComponent(0.92),
            alignment: .left
        )

        drawText(
            detailText.isEmpty ? "Open System Settings to grant access" : detailText,
            in: NSRect(x: 50, y: 11, width: 290, height: 15),
            font: .systemFont(ofSize: 10.5, weight: .medium),
            color: emphasized(amber).withAlphaComponent(0.90),
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
            in: NSRect(x: 50, y: 31, width: 200, height: 17),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: ink.withAlphaComponent(0.92),
            alignment: .left
        )

        if progressFraction != nil {
            // Box top chosen so the digits share the title's baseline.
            drawText(
                "\(Int((displayedProgress * 100).rounded()))%",
                in: NSRect(x: bounds.width - 108, y: 30.5, width: 90, height: 16),
                font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                color: ink.withAlphaComponent(0.62),
                alignment: .right
            )
        }

        drawProgressBar(in: NSRect(x: 50, y: 24, width: bounds.width - 68, height: 5))

        if !detailText.isEmpty {
            drawText(
                detailText,
                in: NSRect(x: 50, y: 8, width: bounds.width - 68, height: 15),
                font: .systemFont(ofSize: 10.5, weight: .medium),
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

    /// Draw one line with its cap-height block optically centred on the
    /// rect's vertical middle. draw(in:) lays text out from the box top, so
    /// naive boxes leave caps-only labels (DE, AUTO, digits) sitting high.
    private func drawCenteredText(
        _ text: String,
        centeredIn rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .center,
        kern: CGFloat = 0
    ) {
        let baseline = rect.midY - font.capHeight / 2
        let boxTop = baseline + font.ascender
        let boxHeight = ceil(font.ascender - font.descender) + 2
        drawText(
            text,
            in: NSRect(x: rect.minX, y: boxTop - boxHeight, width: rect.width, height: boxHeight),
            font: font,
            color: color,
            alignment: alignment,
            kern: kern
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

/// Full-window container that leaves room for the drop shadow but only
/// accepts clicks on the capsule itself, so the transparent margin never
/// swallows clicks meant for windows beneath.
final class ShadowContainerView: NSView {
    var interactiveFrame = NSRect.zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return interactiveFrame.contains(local) ? super.hitTest(point) : nil
    }
}

final class OverlayController: NSObject {
    // Transparent margin around the capsule reserved for the shadow blur.
    private static let shadowMargin: CGFloat = 28

    private let application: NSApplication
    private let panel: NSPanel
    private let hudView: RecorderHUDView
    private let effectView: NSVisualEffectView
    private let containerView: ShadowContainerView
    private var inputBuffer = Data()
    // The size the capsule is at or animating to. Mid-morph the frame reports
    // an in-between size, so it cannot tell whether a new request differs from
    // where the capsule is already heading, nor whether the mask still fits.
    private var capsuleTarget: NSSize
    private var isClosing = false
    private var isStandby = false
    private var isArmed = false
    private var previewTimer: Timer?

    // The grow animation is stepped by hand: the blur is clipped by the
    // window server through maskImage, which cannot follow an animator or a
    // layer transform, so every frame sets frame, mask and shadow together.
    private var growTimer: Timer?
    private var growTargetSize = NSSize.zero
    private var growCompletion: (() -> Void)?

    private static let seedDiameter: CGFloat = 12
    // The pill's own height: circle and pill are one shape, only the
    // width changes between them.
    private static let armDiameter: CGFloat = 44
    private static let controlBandHeight: CGFloat = 44

    init(application: NSApplication, launchMode: String) {
        self.application = application

        // Recording sessions carry only dot, waveform and timer and sit in
        // the flatter capsule; status modes keep the taller panel their two
        // text lines need.
        // A standby pill becomes a recording pill when it is shown.
        let recordingCapsule = launchMode == "recording" || launchMode == "preview" || launchMode == "standby"
        let capsuleSize: NSSize
        if recordingCapsule {
            capsuleSize = NSSize(width: 240, height: 44)
        } else {
            capsuleSize = NSSize(width: 358, height: 56)
        }
        capsuleTarget = capsuleSize
        let margin = OverlayController.shadowMargin
        let panelSize = NSSize(
            width: capsuleSize.width + margin * 2,
            height: capsuleSize.height + margin * 2
        )
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        containerView = ShadowContainerView(frame: NSRect(origin: .zero, size: panelSize))
        containerView.wantsLayer = true

        let visualEffect = NSVisualEffectView(
            frame: NSRect(x: margin, y: margin, width: capsuleSize.width, height: capsuleSize.height)
        )
        // .popover adapts to the system appearance (light frost in light
        // mode, dark in dark mode) and is opaque enough that text contrast
        // no longer depends on whatever happens to sit behind the pill —
        // .hudWindow is dark-only and washed out over bright windows.
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active

        // With .behindWindow blending the material is composited by the window
        // server, outside this view's Core Animation layer. A layer mask
        // therefore does not clip it: the blur bleeds into the four corners
        // and reads as white over light backgrounds. maskImage is the shape
        // the window server itself honours.
        visualEffect.maskImage = OverlayController.capsuleMask(size: capsuleSize)

        // The frosted look comes from the material itself: a faint white lift
        // instead of the old near-black tint, so the backdrop shows through
        // the blur the way the native dictation HUD lets it. The rim is drawn
        // by the HUD view as a lit glass edge instead of a flat layer border.
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = capsuleRadius(forHeight: capsuleSize.height)
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.07).cgColor
        effectView = visualEffect

        hudView = RecorderHUDView(frame: visualEffect.bounds)
        hudView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hudView)

        super.init()

        containerView.addSubview(visualEffect)
        containerView.interactiveFrame = visualEffect.frame

        // The separation the old outline used to provide now comes from a
        // soft drop shadow. The system window shadow is disabled in favour
        // of this one, whose path always matches the capsule.
        containerView.layer?.masksToBounds = false
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.32
        containerView.layer?.shadowRadius = 15
        containerView.layer?.shadowOffset = CGSize(width: 0, height: -5)
        containerView.layer?.shadowPath = CGPath(
            roundedRect: visualEffect.frame,
            cornerWidth: capsuleRadius(forHeight: capsuleSize.height),
            cornerHeight: capsuleRadius(forHeight: capsuleSize.height),
            transform: nil
        )

        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = containerView

        positionPanel(panelSize: panelSize)

        if launchMode == "standby" {
            // Started ahead of the hotkey: AppKit, the window and the blur
            // are ready, so "show" puts the pill on screen within a frame
            // instead of after a process launch (~0.15-0.25 s).
            isStandby = true
            hudView.stopAnimating()
            startReadingCommands()
            return
        }
        showPanel()

        if launchMode == "preview" {
            startPreview()
        } else if launchMode == "error" {
            // Shown by the watchdog just before it hard-exits, so this mode
            // never reads stdin: the writer is gone a moment later, and EOF
            // would dismiss the pill before it could be read.
            hudView.setMode(.error)
            hudView.setDetail("Audio stopped responding — back in a moment")
            syncPanelSize()
            close(after: 4.5)
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
        let radius = capsuleRadius(forHeight: size.height)
        let mask = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: radius,
                yRadius: radius
            ).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(
            top: 0,
            left: radius + 1,
            bottom: 0,
            right: radius + 1
        )
        mask.resizingMode = .stretch
        return mask
    }

    private static let morphDuration: TimeInterval = 0.22

    /// A capsule mask drawn at exactly `size`, for the frames of the grow
    /// animation. Below twice the cap insets a stretchable mask would break.
    private static func exactMask(size: NSSize) -> NSImage {
        let radius = capsuleRadius(forHeight: size.height)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }

    /// Where a capsule of `size` sits in the panel: centred horizontally,
    /// and a circle smaller than the control band centred on that band, so
    /// it grows out from the spot the pill's middle will occupy.
    private func capsuleRect(size: NSSize) -> NSRect {
        let margin = OverlayController.shadowMargin
        let width = containerView.bounds.width
        let lift = max(0, (OverlayController.controlBandHeight - size.height) / 2)
        return NSRect(
            x: (width - size.width) / 2,
            y: margin + lift,
            width: size.width,
            height: size.height
        )
    }

    private func applyCapsule(_ rect: NSRect, settled: Bool) {
        let radius = capsuleRadius(forHeight: rect.height)
        effectView.frame = rect
        // The stretchable mask needs room for both end caps; circles get an
        // exact one.
        let stretchable = settled && rect.width >= rect.height + 4
        effectView.maskImage = stretchable
            ? OverlayController.capsuleMask(size: rect.size)
            : OverlayController.exactMask(size: rect.size)
        effectView.layer?.cornerRadius = radius
        containerView.interactiveFrame = rect

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerView.layer?.removeAnimation(forKey: "shadowPath")
        containerView.layer?.shadowPath = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        CATransaction.commit()
    }

    /// Grow (or shrink) the capsule from where it is to `size` on a spring:
    /// a fast start and one small overshoot in width, so the pill reads as
    /// expanding out of the circle rather than fading in.
    private func grow(
        to size: NSSize,
        duration: CFTimeInterval,
        fadeInContent: Bool = false,
        collapse: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        growTimer?.invalidate()
        let start = effectView.frame.size
        let startedAt = CACurrentMediaTime()
        growTargetSize = size
        growCompletion = completion
        if fadeInContent {
            hudView.contentAlpha = 0
        }

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let t = min(1, (CACurrentMediaTime() - startedAt) / duration)
            guard t < 1 else {
                self.finishGrow()
                return
            }
            // Underdamped spring: about 4 % overshoot, settled by t = 1. A
            // collapse instead accelerates into nothing (ease-in cubic).
            let spring = collapse ? CGFloat(t * t * t) : CGFloat(1 - exp(-6 * t) * cos(6 * t))
            let width = start.width + (size.width - start.width) * spring
            // The height must not overshoot: the chrome sits on a fixed band.
            let height = start.height + (size.height - start.height) * min(spring, 1)
            self.applyCapsule(self.capsuleRect(size: NSSize(width: width, height: height)), settled: false)
            if fadeInContent {
                let x = max(0, min(1, (t - 0.28) / 0.45))
                self.hudView.contentAlpha = CGFloat(x * x * (3 - 2 * x))
            }
            if collapse {
                // Content leaves first, so nothing shows squeezed; the
                // capsule itself goes transparent only at the very end.
                self.hudView.contentAlpha = CGFloat(max(0, 1 - t / 0.35))
                self.panel.alphaValue = CGFloat(max(0, min(1, (1 - t) / 0.3)))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        growTimer = timer
    }

    /// Jump a running grow to its end, before anything else resizes the pill.
    private func finishGrow() {
        guard let timer = growTimer else { return }
        timer.invalidate()
        growTimer = nil
        applyCapsule(capsuleRect(size: growTargetSize), settled: true)
        if !isClosing {
            hudView.contentAlpha = 1
        }
        let completion = growCompletion
        growCompletion = nil
        completion?()
    }

    /// Resize for the mode just set: the transcribing and outcome circles
    /// grow (or shrink) into place on the spring, everything else morphs as
    /// before.
    private func fitToMode() {
        guard [.processing, .success, .cancelled].contains(hudView.mode) else {
            syncPanelSize()
            return
        }
        finishGrow()
        let circle = NSSize(width: OverlayController.armDiameter, height: OverlayController.armDiameter)
        capsuleTarget = circle
        grow(to: circle, duration: 0.42)
    }

    private var seedSize: NSSize {
        NSSize(width: OverlayController.seedDiameter, height: OverlayController.seedDiameter)
    }

    /// Put the hidden standby pill on screen as a small circle.
    private func revealSeed() {
        positionPanel(panelSize: panel.frame.size)
        applyCapsule(capsuleRect(size: seedSize), settled: false)
        showPanel()
    }

    /// Morph the panel to the capsule size the current state wants, keeping
    /// it horizontally centred and anchored to the bottom edge.
    ///
    /// Capsule, window and shadow move as one motion. The capsule used to be
    /// set to its final size synchronously while only the window animated —
    /// on every stop that read as a snap, a sideways slide, then another
    /// jump into the result size.
    ///
    /// A request can land mid-morph — typically live text growing the
    /// capsule just as the stop turns it into the processing dots. Every
    /// comparison is therefore made against the target, and the shadow
    /// starts from where it is on screen, not where it was headed.
    private func syncPanelSize() {
        finishGrow()
        guard let wanted = hudView.desiredSize() else { return }

        let previous = capsuleTarget
        guard abs(previous.width - wanted.width) > 1 || abs(previous.height - wanted.height) > 1 else {
            return
        }
        capsuleTarget = wanted

        let radius = capsuleRadius(forHeight: wanted.height)
        // Always a fresh stretchable mask: coming out of a circle, the exact
        // circle mask would otherwise stretch into an ellipse.
        effectView.maskImage = OverlayController.capsuleMask(size: wanted)
        effectView.layer?.cornerRadius = radius

        let margin = OverlayController.shadowMargin
        var frame = panel.frame
        frame.origin.x += (frame.width - (wanted.width + margin * 2)) / 2
        frame.size.width = wanted.width + margin * 2
        frame.size.height = wanted.height + margin * 2

        let effectFrame = NSRect(x: margin, y: margin, width: wanted.width, height: wanted.height)
        containerView.interactiveFrame = effectFrame

        // shadowPath does not follow the animator; give it its own matching
        // animation, then commit the final value. It starts from the shadow
        // on screen: the model value is the previous morph's target, so an
        // interrupted grow left a shadow far larger than the capsule, cut off
        // square by the window edge — a grey box around the shrinking pill.
        let shadowPath = CGPath(
            roundedRect: effectFrame,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        if let layer = containerView.layer {
            let shadowAnimation = CABasicAnimation(keyPath: "shadowPath")
            shadowAnimation.fromValue = layer.presentation()?.shadowPath ?? layer.shadowPath
            shadowAnimation.toValue = shadowPath
            shadowAnimation.duration = OverlayController.morphDuration
            shadowAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(shadowAnimation, forKey: "shadowPath")
            layer.shadowPath = shadowPath
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = OverlayController.morphDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            effectView.animator().frame = effectFrame
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func positionPanel(panelSize: NSSize) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        // The window carries a transparent shadow margin; subtract it so the
        // visible capsule, not the window, floats 24 pt above the bottom.
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.minY + 24 - OverlayController.shadowMargin
            )
        )
    }

    private func showPanel() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            // Short: the pill is the answer to the hotkey and should read as
            // instant; a longer fade made the start feel sluggish.
            context.duration = 0.08
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
        case "arm":
            // The hotkey fired; the microphone is still opening. Answer at
            // once with a circle that becomes the pill when "show" arrives.
            guard isStandby, !isArmed else { return }
            isArmed = true
            hudView.setMode(.arming)
            hudView.startAnimating()
            // The active screen may have changed while the pill waited.
            revealSeed()
            let arm = OverlayController.armDiameter
            grow(to: NSSize(width: arm, height: arm), duration: 0.34)
        case "disarm":
            // The start failed after all: fold the circle away and wait again.
            guard isStandby, isArmed else { return }
            isArmed = false
            grow(to: seedSize, duration: 0.16) { [weak self] in
                guard let self else { return }
                self.panel.orderOut(nil)
                self.hudView.stopAnimating()
                self.applyCapsule(self.capsuleRect(size: self.capsuleTarget), settled: true)
            }
        case "show":
            guard isStandby else { return }
            isStandby = false
            let wasArmed = isArmed
            isArmed = false
            hudView.setMode(.recording)
            hudView.startAnimating()
            if !wasArmed {
                revealSeed()
            }
            grow(to: capsuleTarget, duration: 0.46, fadeInContent: true)
        case "level" where parts.count == 2:
            if let value = Double(parts[1]) {
                hudView.setLevel(value)
            }
        case "state" where parts.count == 2:
            guard let newMode = OverlayMode(rawValue: parts[1]) else { return }
            hudView.setMode(newMode)
            fitToMode()

            switch newMode {
            case .success:
                close(after: 1.0)
            case .empty, .failed:
                close(after: 1.8)
            case .cancelled:
                close(after: 0.9)
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
        case "final":
            hudView.setTranscript(final: parts.count == 2 ? parts[1] : "", partial: nil)
            syncPanelSize()
        case "partial":
            hudView.setTranscript(final: nil, partial: parts.count == 2 ? parts[1] : "")
            syncPanelSize()
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
                    self.fitToMode()
                    self.close(after: 1.0)
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
        // The way it came: the capsule folds back into a point and is gone,
        // starting from wherever a running grow has got to.
        growTimer?.invalidate()
        growTimer = nil
        grow(to: seedSize, duration: 0.26, collapse: true) { [weak self] in
            self?.panel.alphaValue = 0
            self?.application.terminate(nil)
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()

let arguments = Array(CommandLine.arguments.dropFirst())
// Callers still pass a language as the second argument (and after "show");
// the pill no longer shows one, so it is ignored.
let launchMode = arguments.first ?? "recording"
let controller = OverlayController(application: application, launchMode: launchMode)
withExtendedLifetime(controller) {
    application.run()
}
