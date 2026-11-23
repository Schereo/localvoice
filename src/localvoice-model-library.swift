import AppKit

struct ModelLibraryEntry {
    enum State {
        // Download progress is a fraction from 0 to 1.
        case notInstalled, downloading(Double), installed, active, unavailable(String)
    }

    let id: String
    let name: String
    let size: String
    let source: String
    var state: State
    var removable = true
    // Total download size, for "71 of 886 MB" while downloading.
    var bytes: Int64? = nil
    // Found in the Hugging Face cache: used in place, never removed by LocalVoice.
    var shared = false
}

enum DictationLanguage: String, CaseIterable {
    case auto, de, en

    var title: String {
        switch self {
        case .auto: "Detect Automatically"
        case .de: "Deutsch"
        case .en: "English"
        }
    }

    static func canSelect(for model: String) -> Bool {
        ["whisper-turbo-fp16", "whisper-turbo-q4", "nemotron-streaming"].contains(model)
    }
}

// What the library says about a model beyond the store's catalog. Only facts the
// code relies on: which languages can be chosen, how the model runs, its size.
private struct ModelLibraryDetails {
    let summary: String
    let languages: String

    static func of(_ id: String) -> ModelLibraryDetails {
        switch id {
        case "whisper-turbo-fp16":
            ModelLibraryDetails(summary: "Full precision. Runs on the GPU.", languages: "German, English")
        case "whisper-turbo-q4":
            ModelLibraryDetails(summary: "4-bit version. Under a third the size.",
                                languages: "German, English")
        case "parakeet-v3":
            ModelLibraryDetails(summary: "NVIDIA, on the Neural Engine. Fast.", languages: "Detected automatically")
        case "parakeet-ultra":
            ModelLibraryDetails(summary: "The larger Parakeet, on the Neural Engine.",
                                languages: "Detected automatically")
        case "parakeet-redux":
            ModelLibraryDetails(summary: "The smallest Parakeet download.",
                                languages: "Detected automatically")
        case "nemotron-streaming":
            ModelLibraryDetails(summary: "Transcribes while you speak.", languages: "German, English")
        default:
            ModelLibraryDetails(summary: "", languages: "")
        }
    }
}

private final class ModelLibraryDocument: NSView {
    override var isFlipped: Bool { true }
}

enum ModelLibraryAction {
    case download, cancel, use, remove
}

@MainActor
protocol ModelLibraryBackend: AnyObject {
    var models: [ModelLibraryEntry] { get }
    var message: String? { get }
    // Publish the new snapshot before calling this on the main actor.
    var onChange: (() -> Void)? { get set }
    func allows(_ action: ModelLibraryAction, modelID: String) -> Bool
    func perform(_ action: ModelLibraryAction, modelID: String)
}

extension ModelLibraryBackend {
    var message: String? { nil }
    func allows(_ action: ModelLibraryAction, modelID: String) -> Bool { true }
}

// Layout shared by the header and every row, so the columns line up.
private enum ModelLibraryMetrics {
    static let inset: CGFloat = 20
    static let languageWidth: CGFloat = 156
    static let sizeWidth: CGFloat = 72
    static let actionWidth: CGFloat = 132
    static let buttonWidth: CGFloat = 104
    static let gap: CGFloat = 16
    static let headerHeight: CGFloat = 38
    static let rowHeight: CGFloat = 58
    static let cornerRadius: CGFloat = 12
}

// Layer-backed views that pick their colours up again when the appearance changes.
// Shared with the permission window in the launcher.
class ModelLibraryLayerView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fill?.cgColor
        layer.borderColor = stroke?.cgColor
        layer.borderWidth = stroke == nil ? 0 : 1
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.masksToBounds = radius > 0
    }
}

final class ModelLibrarySeparator: ModelLibraryLayerView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        fill = .separatorColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
}

extension NSColor {
    static let modelLibraryCard = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 1, alpha: 1)
    }
    static let modelLibraryReady = NSColor(name: nil) { appearance in
        NSColor.systemGreen.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.16 : 0.10)
    }
    static let modelLibraryReadyStroke = NSColor(name: nil) { appearance in
        NSColor.systemGreen.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.35 : 0.30)
    }
    static let modelLibraryHighlight = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.035)
    }
}

@MainActor
func modelLibraryLabel(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular,
                               color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

@MainActor
final class ModelLibraryViewController: NSViewController {
    private let backend: any ModelLibraryBackend
    private let notice: String?
    private let readLanguage: ((String) -> DictationLanguage)?
    private let saveLanguage: ((String, DictationLanguage) -> Bool)?
    private let rows = NSStackView()
    private let content = NSStackView()
    private let heading = modelLibraryLabel("Speech Recognition Model", size: 17, weight: .semibold)
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let languageFooter = NSView()
    private let languageNote = modelLibraryLabel(size: 12, color: .secondaryLabelColor)
    private let languagePopUp = NSPopUpButton()
    private var languageModel: String?
    private var modelIDs: [String] = []
    private let readyDetail: (() -> String)?
    private let readyBanner = ModelLibraryLayerView()
    private let readyText = NSTextField(wrappingLabelWithString: "")
    // The active model as of the last refresh with a loaded catalog; nil until then.
    private var lastActive: String??

    init(backend: any ModelLibraryBackend, notice: String? = nil,
         readLanguage: ((String) -> DictationLanguage)? = nil,
         saveLanguage: ((String, DictationLanguage) -> Bool)? = nil,
         readyDetail: (() -> String)? = nil) {
        self.backend = backend
        self.notice = notice
        self.readLanguage = readLanguage
        self.saveLanguage = saveLanguage
        self.readyDetail = readyDetail
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let M = ModelLibraryMetrics.self
        heading.setAccessibilityRole(.staticText)

        // The subtitle shows the notice, or the library's current message in its
        // place, so progress and errors stay in view above the table.
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.addArrangedSubview(heading)
        subtitle.font = .systemFont(ofSize: 12)
        content.addArrangedSubview(subtitle)
        subtitle.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let card = ModelLibraryLayerView()
        card.fill = .modelLibraryCard
        card.stroke = .separatorColor
        card.radius = M.cornerRadius
        card.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        buildLanguageFooter()

        let cardStack = NSStackView(views: [header, ModelLibrarySeparator(), rows, languageFooter])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        for view in cardStack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        buildReadyBanner()
        content.addArrangedSubview(readyBanner)
        readyBanner.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.addArrangedSubview(card)
        content.setCustomSpacing(16, after: subtitle)
        content.setCustomSpacing(12, after: readyBanner)
        card.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let container = ModelLibraryDocument()
        scroll.documentView = container
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])
        view = scroll
        refresh()
        backend.onChange = { [weak self] in self?.refresh() }
    }

    // Window content size that shows every row without scrolling. The store lists
    // every catalog model, available or not, so pass the count it returns.
    static func preferredSize(modelCount: Int) -> NSSize {
        let M = ModelLibraryMetrics.self
        let card = M.headerHeight + 1 + CGFloat(modelCount) * M.rowHeight + 66
        return NSSize(width: 760, height: (24 + 22 + 4 + 16 + 16 + card + 24).rounded())
    }

    // Shown once a model has finished loading: how to dictate, and where Settings are.
    private func buildReadyBanner() {
        readyBanner.fill = .modelLibraryReady
        readyBanner.stroke = .modelLibraryReadyStroke
        readyBanner.radius = 10
        readyBanner.translatesAutoresizingMaskIntoConstraints = false
        readyBanner.isHidden = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .systemGreen
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = modelLibraryLabel("Ready to dictate", size: 13, weight: .semibold)
        readyText.font = .systemFont(ofSize: 12)
        readyText.textColor = .secondaryLabelColor
        readyText.maximumNumberOfLines = 3
        let text = NSStackView(views: [title, readyText])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        let dismiss = NSButton(title: "Got It", target: self, action: #selector(dismissReady))
        dismiss.bezelStyle = .push
        dismiss.controlSize = .small
        dismiss.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, text, dismiss] { readyBanner.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: readyBanner.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: text.topAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.topAnchor.constraint(equalTo: readyBanner.topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: readyBanner.bottomAnchor, constant: -12),
            text.trailingAnchor.constraint(lessThanOrEqualTo: dismiss.leadingAnchor, constant: -16),
            readyText.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            dismiss.trailingAnchor.constraint(equalTo: readyBanner.trailingAnchor, constant: -16),
            dismiss.centerYAnchor.constraint(equalTo: readyBanner.centerYAnchor),
        ])
        readyBanner.setAccessibilityElement(true)
        readyBanner.setAccessibilityRole(.group)
    }

    private func showReady(_ model: ModelLibraryEntry) {
        guard let detail = readyDetail?() else { return }
        readyText.stringValue = detail
        readyBanner.setAccessibilityLabel("Ready to dictate with \(model.name). \(detail)")
        let wasHidden = readyBanner.isHidden
        readyBanner.isHidden = false
        if wasHidden { fitWindow(modelCount: modelIDs.count) }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "\(model.name) is ready. \(detail)", .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func hideReady() {
        guard !readyBanner.isHidden else { return }
        readyBanner.isHidden = true
        fitWindow(modelCount: modelIDs.count)
    }

    @objc private func dismissReady() { hideReady() }

    private func makeHeader() -> NSView {
        let M = ModelLibraryMetrics.self
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let model = modelLibraryLabel("Model", size: 12, color: .secondaryLabelColor)
        let languages = modelLibraryLabel("Languages", size: 12, color: .secondaryLabelColor)
        let size = modelLibraryLabel("Size", size: 12, color: .secondaryLabelColor)
        size.alignment = .right
        for label in [model, languages, size] { header.addSubview(label) }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: M.headerHeight),
            model.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: M.inset),
            model.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            size.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -(M.inset + M.actionWidth + M.gap)),
            size.widthAnchor.constraint(equalToConstant: M.sizeWidth),
            size.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            languages.trailingAnchor.constraint(equalTo: size.leadingAnchor, constant: -M.gap),
            languages.widthAnchor.constraint(equalToConstant: M.languageWidth),
            languages.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func buildLanguageFooter() {
        let M = ModelLibraryMetrics.self
        languageFooter.translatesAutoresizingMaskIntoConstraints = false
        let rule = ModelLibrarySeparator()
        let title = modelLibraryLabel("Language", size: 13, weight: .medium)
        languageNote.lineBreakMode = .byWordWrapping
        languageNote.maximumNumberOfLines = 2
        languageNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        languagePopUp.addItems(withTitles: DictationLanguage.allCases.map(\.title))
        languagePopUp.target = self
        languagePopUp.action = #selector(selectLanguage)
        languagePopUp.translatesAutoresizingMaskIntoConstraints = false
        for view in [rule, title, languageNote, languagePopUp] { languageFooter.addSubview(view) }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: languageFooter.topAnchor),
            rule.leadingAnchor.constraint(equalTo: languageFooter.leadingAnchor, constant: M.inset),
            rule.trailingAnchor.constraint(equalTo: languageFooter.trailingAnchor, constant: -M.inset),
            title.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: languageFooter.leadingAnchor, constant: M.inset),
            languageNote.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            languageNote.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            languageNote.trailingAnchor.constraint(lessThanOrEqualTo: languagePopUp.leadingAnchor, constant: -M.gap),
            languageNote.bottomAnchor.constraint(equalTo: languageFooter.bottomAnchor, constant: -16),
            languagePopUp.trailingAnchor.constraint(equalTo: languageFooter.trailingAnchor, constant: -M.inset),
            languagePopUp.centerYAnchor.constraint(equalTo: languageFooter.centerYAnchor, constant: 1),
            languagePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func refresh() {
        let text = backend.message ?? notice
        subtitle.stringValue = text ?? ""
        subtitle.textColor = backend.message == nil ? .secondaryLabelColor : .labelColor
        subtitle.isHidden = text == nil
        content.setCustomSpacing(subtitle.isHidden ? 16 : 4, after: heading)
        let models = backend.models
        let ids = models.map(\.id)
        if ids.count != modelIDs.count { fitWindow(modelCount: ids.count) }
        if ids != modelIDs {
            for row in rows.arrangedSubviews {
                rows.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            for (index, model) in models.enumerated() {
                let row = ModelLibraryRow(separator: index > 0) { [weak self] action in
                    self?.backend.perform(action, modelID: model.id)
                }
                rows.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            modelIDs = ids
        }
        for (view, model) in zip(rows.arrangedSubviews, models) {
            (view as? ModelLibraryRow)?.update(model) { action in
                backend.allows(action, modelID: model.id)
            }
        }
        updateLanguageFooter(models)

        // A model just finished loading (not one that was already running when the window opened).
        if !models.isEmpty {
            let active = models.first { if case .active = $0.state { true } else { false } }
            if let lastActive, let active, active.id != lastActive {
                showReady(active)
            } else if active == nil {
                hideReady()
            }
            lastActive = .some(active?.id)
        }
    }

    // Grow or shrink the open window so every row stays visible; keep its width and top edge.
    private func fitWindow(modelCount: Int) {
        guard let window = view.window, modelCount > 0 else { return }
        var size = Self.preferredSize(modelCount: modelCount)
        if !readyBanner.isHidden {
            readyBanner.layoutSubtreeIfNeeded()
            size.height += readyBanner.fittingSize.height + 12
        }
        let content = NSRect(origin: .zero, size: size)
        var frame = window.frame
        let height = window.frameRect(forContentRect: content).height
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    // The language belongs to the model in use, like the dictation it shapes.
    private func updateLanguageFooter(_ models: [ModelLibraryEntry]) {
        let active = models.first { if case .active = $0.state { true } else { false } }
        languageModel = active?.id
        languageFooter.isHidden = readLanguage == nil || active == nil
        guard let active, let readLanguage else { return }
        if DictationLanguage.canSelect(for: active.id) {
            languagePopUp.isEnabled = true
            languagePopUp.selectItem(withTitle: readLanguage(active.id).title)
            languageNote.stringValue = "The language you speak with \(active.name)."
        } else {
            languagePopUp.isEnabled = false
            languagePopUp.selectItem(withTitle: DictationLanguage.auto.title)
            languageNote.stringValue = "\(active.name) recognizes the language by itself."
        }
        languagePopUp.setAccessibilityLabel("Dictation language for \(active.name)")
    }

    @objc private func selectLanguage() {
        let index = languagePopUp.indexOfSelectedItem
        guard let model = languageModel, DictationLanguage.allCases.indices.contains(index) else { return }
        if saveLanguage?(model, DictationLanguage.allCases[index]) != true {
            refresh()
            if let window = view.window {
                let alert = NSAlert()
                alert.messageText = "Could not save the language preference."
                alert.beginSheetModal(for: window)
            }
        }
    }
}

@MainActor
private final class ModelLibraryRow: ModelLibraryLayerView {
    private let name = modelLibraryLabel(size: 13, weight: .medium)
    private let summary = modelLibraryLabel(size: 12, color: .secondaryLabelColor)
    private let languages = modelLibraryLabel(size: 13)
    private let size = modelLibraryLabel(size: 13, color: .secondaryLabelColor)
    private let sizeNote = modelLibraryLabel("Shared cache", size: 11, color: .tertiaryLabelColor)
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let remove = NSButton()
    private let inUse = NSStackView()
    private let perform: (ModelLibraryAction) -> Void
    private var primaryAction: ModelLibraryAction?
    private var modelName = ""

    init(separator: Bool, perform: @escaping (ModelLibraryAction) -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        let M = ModelLibraryMetrics.self
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        languages.lineBreakMode = .byWordWrapping
        languages.maximumNumberOfLines = 3
        languages.cell?.truncatesLastVisibleLine = true
        size.alignment = .right
        size.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        sizeNote.alignment = .right
        sizeNote.toolTip = "Found in your Hugging Face cache. LocalVoice uses it in place and leaves it there."
        let sizeStack = NSStackView(views: [size, sizeNote])
        sizeStack.orientation = .vertical
        sizeStack.alignment = .trailing
        sizeStack.spacing = 1
        sizeStack.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        primary.bezelStyle = .push
        primary.target = self
        primary.action = #selector(performPrimary)
        primary.translatesAutoresizingMaskIntoConstraints = false

        remove.bezelStyle = .accessoryBarAction
        remove.isBordered = false
        remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove")
        remove.contentTintColor = .tertiaryLabelColor
        remove.toolTip = "Remove the downloaded model"
        remove.target = self
        remove.action = #selector(performRemove)
        remove.translatesAutoresizingMaskIntoConstraints = false

        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill",
                                               accessibilityDescription: nil) ?? NSImage())
        check.contentTintColor = .controlAccentColor
        check.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        let inUseLabel = modelLibraryLabel("In Use", size: 13, weight: .medium, color: .controlAccentColor)
        inUse.setViews([check, inUseLabel], in: .leading)
        inUse.spacing = 5
        inUse.alignment = .centerY
        inUse.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [name, summary])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        let rule = ModelLibrarySeparator()
        rule.isHidden = !separator
        for view in [rule, text, languages, sizeStack, remove, primary, inUse] { addSubview(view) }
        // Rows are rowHeight tall unless their text needs more.
        let height = heightAnchor.constraint(equalToConstant: M.rowHeight)
        height.priority = .defaultHigh - 1
        NSLayoutConstraint.activate([
            height,
            heightAnchor.constraint(greaterThanOrEqualToConstant: M.rowHeight),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),

            primary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.inset),
            primary.centerYAnchor.constraint(equalTo: centerYAnchor),
            primary.widthAnchor.constraint(equalToConstant: M.buttonWidth),
            inUse.centerXAnchor.constraint(equalTo: primary.centerXAnchor),
            inUse.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -6),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),

            sizeStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(M.inset + M.actionWidth + M.gap)),
            sizeStack.widthAnchor.constraint(equalToConstant: M.sizeWidth),
            sizeStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            size.widthAnchor.constraint(equalTo: sizeStack.widthAnchor),
            sizeNote.widthAnchor.constraint(equalTo: sizeStack.widthAnchor),
            languages.trailingAnchor.constraint(equalTo: sizeStack.leadingAnchor, constant: -M.gap),
            languages.widthAnchor.constraint(equalToConstant: M.languageWidth),
            languages.centerYAnchor.constraint(equalTo: centerYAnchor),
            languages.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),

            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.inset),
            text.trailingAnchor.constraint(lessThanOrEqualTo: languages.leadingAnchor, constant: -M.gap),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !remove.isHidden, remove.isEnabled else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Remove Download", action: #selector(performRemove), keyEquivalent: "").target = self
        return menu
    }

    func update(_ model: ModelLibraryEntry, allows: (ModelLibraryAction) -> Bool) {
        let details = ModelLibraryDetails.of(model.id)
        modelName = model.name
        name.stringValue = model.name
        summary.stringValue = details.summary.isEmpty ? model.source : details.summary
        summary.toolTip = model.source
        languages.stringValue = details.languages
        languages.textColor = .labelColor
        languages.toolTip = nil
        size.stringValue = model.size
        fill = nil
        alphaValue = 1
        var installed = false
        let state: String

        switch model.state {
        case .notInstalled:
            show(.download, title: "Download")
            state = "Not downloaded"
        case let .downloading(fraction):
            let progress = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            summary.stringValue = downloadText(progress, bytes: model.bytes)
            fill = .modelLibraryHighlight
            show(.cancel, title: "Cancel")
            state = summary.stringValue
        case .installed:
            show(.use, title: "Use")
            installed = true
            state = "Downloaded"
        case .active:
            show(nil, inUse: true)
            installed = true
            state = "In use"
        case let .unavailable(reason):
            // The store may report this for an installed model too; offer no action.
            show(nil)
            languages.stringValue = reason
            languages.textColor = .secondaryLabelColor
            languages.toolTip = reason
            alphaValue = 0.45
            state = "Unavailable: \(reason)"
        }
        sizeNote.isHidden = !(installed && model.shared)
        primary.isEnabled = primaryAction.map(allows) ?? false
        remove.isHidden = primaryAction != .use || !model.removable
        remove.isEnabled = allows(.remove)
        remove.setAccessibilityLabel("Remove \(model.name)")
        var parts = [model.name, state]
        if case .downloading = model.state {} else if !details.summary.isEmpty { parts.append(details.summary) }
        if case .unavailable = model.state {} else if !details.languages.isEmpty { parts.append(details.languages) }
        parts.append(model.size)
        if !sizeNote.isHidden { parts.append("shared cache") }
        setAccessibilityLabel(parts.joined(separator: ", "))
    }

    private func downloadText(_ fraction: Double, bytes: Int64?) -> String {
        let percent = Int((fraction * 100).rounded(.down))
        guard let bytes, bytes > 0 else { return "Downloading, \(percent) %" }
        let total = Double(bytes) / 1e6
        let done = (total * fraction).rounded(.down)
        if total >= 1000 {
            let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
            return "Downloading, \((done / 1000).formatted(format)) of \((total / 1000).formatted(format)) GB (\(percent) %)"
        }
        return "Downloading, \(Int(done)) of \(Int(total.rounded())) MB (\(percent) %)"
    }

    private func show(_ action: ModelLibraryAction?, title: String = "", inUse showsInUse: Bool = false) {
        primaryAction = action
        primary.title = title
        primary.setAccessibilityLabel("\(title) \(modelName)")
        primary.isHidden = action == nil
        inUse.isHidden = !showsInUse
    }

    @objc private func performPrimary() {
        if let primaryAction { perform(primaryAction) }
    }

    @objc private func performRemove() {
        perform(.remove)
    }
}

@MainActor
final class StoreModelLibraryBackend: ModelLibraryBackend {
    private enum Operation {
        case status(previousError: String?)
        case download(String)
        case cancel
        case remove
        case activate(UUID)
    }

    private let python: URL
    private let store: URL
    private let parakeetWorker: URL?
    private let activate: (String, @escaping (Bool) -> Void) -> Void
    private var selectedModel: String?
    private var loadingModel: String?
    private var selectionRevision = 0
    private var catalog: [ModelStoreRecord] = []
    private var statusIsCurrent = false
    private var operation: Operation?
    private var command: ModelStoreCommand?
    private var fraction = 0.0
    private(set) var message: String?
    var onChange: (() -> Void)?

    // `store` is the installed localvoice_models.py script.
    init(python: URL, store: URL, selectedModel: String?, parakeetWorker: URL? = nil,
         activate: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        self.python = python
        self.store = store
        self.selectedModel = selectedModel
        self.parakeetWorker = parakeetWorker
        self.activate = activate
    }

    var models: [ModelLibraryEntry] {
        catalog.map { record in
            let state: ModelLibraryEntry.State
            if record.available == false {
                state = .unavailable(record.availabilityReason ?? "Unavailable")
            } else if case let .download(id) = operation, id == record.id {
                state = .downloading(fraction)
            } else if record.status == .notInstalled {
                state = .notInstalled
            } else {
                state = selectedModel == record.id ? .active : .installed
            }
            let location = record.location == "hf-cache" ? " · Shared cache" : ""
            let capability = record.id.hasPrefix("parakeet-") ? " · Auto language"
                : (record.id == "nemotron-streaming" ? " · Live streaming" : "")
            return ModelLibraryEntry(id: record.id, name: record.name, size: record.displaySize,
                                     source: "\(record.source)\(location)\(capability)", state: state,
                                     removable: record.canRemove, bytes: record.bytes,
                                     shared: record.location == "hf-cache")
        }
    }

    func refresh() {
        guard operation == nil else { return }
        checkStatus(notice: catalog.isEmpty ? "Checking models…" : nil)
    }

    func setActiveModel(_ id: String?) {
        selectionRevision += 1
        guard selectedModel != id else { return }
        selectedModel = id
        onChange?()
    }

    func setLoadingModel(_ id: String?) {
        guard loadingModel != id else { return }
        loadingModel = id
        onChange?()
    }

    func stop() {
        if case .download = operation { command?.cancel() }
    }

    func allows(_ action: ModelLibraryAction, modelID: String) -> Bool {
        if action == .cancel {
            if case let .download(id) = operation { return id == modelID }
            return false
        }
        guard operation == nil, statusIsCurrent,
              let record = catalog.first(where: { $0.id == modelID }),
              record.available != false else { return false }
        switch action {
        case .download:
            return record.status == .notInstalled
        case .use:
            return record.status == .installed && selectedModel != modelID && loadingModel == nil
        case .remove:
            return record.status == .installed && selectedModel != modelID &&
                loadingModel != modelID && record.canRemove
        case .cancel:
            return false
        }
    }

    func perform(_ action: ModelLibraryAction, modelID: String) {
        guard allows(action, modelID: modelID) else { return }
        switch action {
        case .download:
            fraction = 0
            operation = .download(modelID)
            message = nil
            run("download", modelID: modelID)
        case .cancel:
            operation = .cancel
            message = "Cancelling download…"
            command?.cancel()
        case .remove:
            operation = .remove
            message = "Removing model…"
            run("remove", modelID: modelID)
        case .use:
            let token = UUID()
            let revision = selectionRevision
            operation = .activate(token)
            message = "Switching model…"
            let completion: @Sendable (Bool) -> Void = { [weak self] success in
                DispatchQueue.main.async {
                    guard let self, case let .activate(current) = self.operation, current == token else { return }
                    if success, self.selectionRevision == revision { self.selectedModel = modelID }
                    self.operation = nil
                    self.message = success ? nil : "Could not switch models. Try again."
                    self.onChange?()
                }
            }
            activate(modelID, completion)
        }
        onChange?()
    }

    private func checkStatus(previousError: String? = nil, notice: String? = nil) {
        statusIsCurrent = false
        operation = .status(previousError: previousError)
        message = notice
        run("status")
        onChange?()
    }

    private func run(_ verb: String, modelID: String? = nil) {
        let command = ModelStoreCommand()
        self.command = command
        command.run(python: python, store: store, parakeetWorker: parakeetWorker,
                    verb: verb, modelID: modelID) { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
    }

    private func receive(_ event: ModelStoreCommand.Event) {
        switch event {
        case let .progress(value):
            guard case .download = operation, value > fraction else { return }
            fraction = value
            onChange?()
        case let .finished(success, models):
            command = nil
            switch operation {
            case let .status(previousError):
                if let models {
                    catalog = models
                    statusIsCurrent = true
                    message = previousError
                } else {
                    message = previousError.map { "\($0) The library could not refresh." }
                        ?? "Could not read the model library. Reopen it to retry."
                }
                operation = nil
                onChange?()
            case .download:
                checkStatus(previousError: success ? nil : "Could not download the model. Try again.",
                            notice: "Checking models…")
            case .cancel:
                checkStatus(notice: "Checking models…")
            case .remove:
                checkStatus(previousError: success ? nil : "Could not remove the model. Try again.",
                            notice: "Checking models…")
            case .activate, nil:
                break
            }
        }
    }
}

private struct ModelStoreRecord: Decodable, Sendable {
    enum Status: String, Decodable, Sendable {
        case installed
        case notInstalled = "not-installed"
    }

    let id: String
    let name: String
    let bytes: Int64
    let source: String
    let status: Status
    let location: String?
    let removable: Bool?
    let available: Bool?
    let availabilityReason: String?

    var canRemove: Bool { removable == true }

    var displaySize: String {
        if bytes >= 1_000_000_000 {
            let size = (Double(bytes) / 1e9).formatted(.number.precision(.fractionLength(0...2)))
            return "\(size) GB"
        }
        if bytes >= 1_000_000 {
            let size = (Double(bytes) / 1e6).formatted(.number.precision(.fractionLength(0)))
            return "\(size) MB"
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// All process launch, signalling, pipe reads, and JSON decoding stay off the main thread.
private final class ModelStoreCommand: @unchecked Sendable {
    enum Event: Sendable {
        case progress(Double)
        case finished(Bool, [ModelStoreRecord]?)
    }

    private struct Catalog: Decodable {
        let models: [ModelStoreRecord]
    }

    private struct Update: Decodable {
        let event: String?
        let id: String?
        let ok: Bool?
        let downloadedBytes: Double?
        let totalBytes: Double?
        let fraction: Double?
        let progress: Double?
        let percent: Double?

        var progressFraction: Double? {
            if let downloadedBytes, let totalBytes, totalBytes > 0 { return downloadedBytes / totalBytes }
            if let percent { return percent / 100 }
            return fraction ?? progress
        }
    }

    // Protects cancellation and the identity of the one child owned by this command.
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func cancel() {
        lock.withLock {
            isCancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    func run(python: URL, store: URL, parakeetWorker: URL?, verb: String, modelID: String?,
             report: @escaping @Sendable (Event) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let child = Process()
            let output = Pipe()
            child.executableURL = python
            child.arguments = ["-I", "-B", "-u", store.path, verb] + (modelID.map { [$0] } ?? [])
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
            environment["LOCALVOICE_PARAKEET_WORKER"] = parakeetWorker?.path
            child.environment = environment
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            let launched = self.lock.withLock {
                guard !self.isCancelled, (try? child.run()) != nil else { return false }
                self.process = child
                return true
            }
            guard launched else {
                report(.finished(false, nil))
                return
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var success = false
            func handle(_ line: Data) {
                guard let update = try? decoder.decode(Update.self, from: line),
                      update.id == nil || update.id == modelID else { return }
                if update.event == "success", update.ok == true { success = true }
                if verb == "download", update.event == nil || update.event == "progress",
                   let value = update.progressFraction, value.isFinite {
                    report(.progress(min(max(value, 0), 1)))
                }
            }

            // Keep draining malformed output so the child can still exit, but bound memory.
            let limit = 1_048_576
            var buffer = Data()
            var overflow = false
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                guard !overflow else { continue }
                buffer.append(chunk)
                if verb != "status" {
                    while let newline = buffer.firstIndex(of: 10) {
                        handle(Data(buffer[..<newline]))
                        buffer.removeSubrange(...newline)
                    }
                }
                if buffer.count > limit {
                    buffer.removeAll()
                    overflow = true
                }
            }
            if verb != "status", !buffer.isEmpty { handle(buffer) }
            child.waitUntilExit()
            self.lock.withLock { self.process = nil }
            let cleanExit = child.terminationReason == .exit && child.terminationStatus == 0
            let catalog = cleanExit && !overflow && verb == "status"
                ? (try? decoder.decode(Catalog.self, from: buffer))?.models : nil
            report(.finished(cleanExit && !overflow && success, catalog))
        }
    }
}

#if MODEL_LIBRARY_PREVIEW
@MainActor
private final class DemoModelLibraryBackend: NSObject, ModelLibraryBackend {
    private(set) var models = [
        ModelLibraryEntry(id: "whisper-turbo-fp16", name: "Whisper Large V3 Turbo", size: "1.61 GB",
                          source: "Hugging Face · mlx-community/whisper-large-v3-turbo", state: .active,
                          removable: false, bytes: 1_614_000_000, shared: true),
        ModelLibraryEntry(id: "whisper-turbo-q4", name: "Whisper Large V3 Turbo Q4", size: "464 MB",
                          source: "Hugging Face · mlx-community/whisper-large-v3-turbo-q4", state: .installed,
                          bytes: 464_000_000),
        ModelLibraryEntry(id: "parakeet-v3", name: "Parakeet V3", size: "483 MB",
                          source: "FluidInference · parakeet-tdt-0.6b-v3-coreml", state: .downloading(0.08),
                          bytes: 483_000_000),
        ModelLibraryEntry(id: "parakeet-ultra", name: "Parakeet Ultra", size: "632 MB",
                          source: "FluidInference · parakeet-ultra-coreml", state: .notInstalled,
                          bytes: 632_000_000),
        ModelLibraryEntry(id: "parakeet-redux", name: "Parakeet Redux", size: "220 MB",
                          source: "FluidInference · parakeet-redux-coreml", state: .unavailable("Parakeet Redux requires macOS 15 or later."),
                          bytes: 220_000_000),
        ModelLibraryEntry(id: "nemotron-streaming", name: "Nemotron Streaming", size: "615 MB",
                          source: "FluidInference · Nemotron-3.5-ASR-Streaming-Multilingual", state: .notInstalled,
                          bytes: 615_000_000),
    ]
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var downloadIndex: Int?
    private var step = 0

    override init() {
        super.init()
        // The demo opens mid-download (Parakeet V3 at 8 %), so keep it moving.
        downloadIndex = 2
        step = 2
        startTimer()
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(advance(_:)),
                          userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func perform(_ action: ModelLibraryAction, modelID: String) {
        guard let index = models.firstIndex(where: { $0.id == modelID }) else { return }
        switch (action, models[index].state) {
        case (.download, .notInstalled) where downloadIndex == nil:
            downloadIndex = index
            step = 0
            models[index].state = .downloading(0)
            startTimer()
        case (.cancel, .downloading):
            finish(at: index, state: .notInstalled)
        case (.use, .installed):
            for other in models.indices {
                if case .active = models[other].state { models[other].state = .installed }
            }
            models[index].state = .active
        case (.remove, .installed):
            models[index].state = .notInstalled
        default:
            return
        }
        onChange?()
    }

    @objc private func advance(_ timer: Timer) {
        guard let index = downloadIndex else { return }
        step += 1
        if step == 24 {
            finish(at: index, state: .installed)
        } else {
            models[index].state = .downloading(Double(step) / 24)
        }
        onChange?()
    }

    private func finish(at index: Int, state: ModelLibraryEntry.State) {
        timer?.invalidate()
        timer = nil
        downloadIndex = nil
        models[index].state = state
    }
}

@MainActor
private final class ModelLibraryPreview: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var languages: [String: DictationLanguage] = [:]
        let backend = DemoModelLibraryBackend()
        let controller = ModelLibraryViewController(
            backend: backend,
            notice: "Models run on this Mac. Demo only: actions are simulated.",
            readLanguage: { languages[$0] ?? .auto },
            saveLanguage: { languages[$0] = $1; return true },
            readyDetail: { "Tap Command twice in any app to start, and again to insert the text. Esc discards. "
                + "Settings are under the LocalVoice icon in the menu bar." }
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 340),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "LocalVoice"
        window.contentViewController = controller
        window.setContentSize(ModelLibraryViewController.preferredSize(modelCount: 6))
        window.center()
        self.window = window
        // MODEL_LIBRARY_READY=1 switches models once, as a user would, to show the ready banner.
        if ProcessInfo.processInfo.environment["MODEL_LIBRARY_READY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { backend.perform(.use, modelID: "whisper-turbo-q4") }
        }
        if let path = ProcessInfo.processInfo.environment["MODEL_LIBRARY_SNAPSHOT"] {
            snapshot(window, to: path)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Renders the window offscreen to <path>.png in the appearance from
    // MODEL_LIBRARY_APPEARANCE (light or dark), then quits.
    private func snapshot(_ window: NSWindow, to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let frameView = window.contentView?.superview else { exit(1) }
            frameView.layoutSubtreeIfNeeded()
            let bounds = frameView.bounds
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { exit(1) }
            frameView.cacheDisplay(in: bounds, to: rep)
            let data = rep.representation(using: .png, properties: [:])
            exit((try? data?.write(to: URL(fileURLWithPath: "\(path).png"))) == nil ? 1 : 0)
        }
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if let appearance = ProcessInfo.processInfo.environment["MODEL_LIBRARY_APPEARANCE"] {
            app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Model Library", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        app.mainMenu = mainMenu

        let delegate = ModelLibraryPreview()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@main
private struct ModelLibraryPreviewMain {
    static func main() {
        ModelLibraryPreview.run()
    }
}
#endif
