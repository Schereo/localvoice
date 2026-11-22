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
}

enum DictationLanguage: String, CaseIterable {
    case auto, de, en

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .de: "Deutsch"
        case .en: "English"
        }
    }

    static func canSelect(for model: String) -> Bool {
        ["whisper-turbo-fp16", "whisper-turbo-q4", "nemotron-streaming"].contains(model)
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

@MainActor
final class ModelLibraryViewController: NSViewController {
    private let backend: any ModelLibraryBackend
    private let notice: String?
    private let readLanguage: ((String) -> DictationLanguage)?
    private let saveLanguage: ((String, DictationLanguage) -> Bool)?
    private let rows = NSStackView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var modelIDs: [String] = []

    init(backend: any ModelLibraryBackend, notice: String? = nil,
         readLanguage: ((String) -> DictationLanguage)? = nil,
         saveLanguage: ((String, DictationLanguage) -> Bool)? = nil) {
        self.backend = backend
        self.notice = notice
        self.readLanguage = readLanguage
        self.saveLanguage = saveLanguage
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let heading = NSTextField(labelWithString: "Model Library")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12

        let content = NSStackView(views: [heading])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        var lastHeaderView: NSView = heading
        if let notice {
            let label = NSTextField(wrappingLabelWithString: notice)
            label.textColor = .secondaryLabelColor
            content.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            lastHeaderView = label
        }
        content.addArrangedSubview(rows)
        content.setCustomSpacing(20, after: lastHeaderView)
        message.textColor = .secondaryLabelColor
        content.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
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
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            rows.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        view = scroll
        refresh()
        backend.onChange = { [weak self] in self?.refresh() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func refresh() {
        message.stringValue = backend.message ?? ""
        message.isHidden = backend.message == nil
        let models = backend.models
        let ids = models.map(\.id)
        if ids != modelIDs {
            for row in rows.arrangedSubviews {
                rows.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            for model in models {
                let row = ModelLibraryRow(perform: { [weak self] action in
                    self?.backend.perform(action, modelID: model.id)
                }, setLanguage: { [weak self] language in
                    guard let self else { return }
                    if self.saveLanguage?(model.id, language) != true {
                        self.refresh()
                        if let window = self.view.window {
                            let alert = NSAlert()
                            alert.messageText = "Could not save the language preference."
                            alert.beginSheetModal(for: window)
                        }
                    }
                })
                rows.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            modelIDs = ids
        }
        for (view, model) in zip(rows.arrangedSubviews, models) {
            let language = DictationLanguage.canSelect(for: model.id) ? readLanguage?(model.id) : nil
            (view as? ModelLibraryRow)?.update(model, language: language) { action in
                backend.allows(action, modelID: model.id)
            }
        }
    }
}

@MainActor
private final class ModelLibraryRow: NSView {
    private let name = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let remove = NSButton(title: "Remove", target: nil, action: nil)
    private let language = NSPopUpButton()
    private let languageRow = NSStackView()
    private let perform: (ModelLibraryAction) -> Void
    private let setLanguage: (DictationLanguage) -> Void
    private var primaryAction: ModelLibraryAction?

    init(perform: @escaping (ModelLibraryAction) -> Void, setLanguage: @escaping (DictationLanguage) -> Void) {
        self.perform = perform
        self.setLanguage = setLanguage
        super.init(frame: .zero)
        let border = NSBox()
        border.boxType = .custom
        border.borderWidth = 1
        border.borderColor = .separatorColor
        border.fillColor = .clear
        border.cornerRadius = 8
        border.setAccessibilityElement(false)
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        source.textColor = .secondaryLabelColor
        source.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        source.lineBreakMode = .byTruncatingMiddle
        source.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)

        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 116).isActive = true

        primary.target = self
        primary.action = #selector(performPrimary)
        remove.target = self
        remove.action = #selector(performRemove)
        language.controlSize = .small
        language.addItems(withTitles: DictationLanguage.allCases.map(\.title))
        language.target = self
        language.action = #selector(selectLanguage)
        let caption = NSTextField(labelWithString: "Dictation Language")
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        languageRow.alignment = .centerY
        languageRow.addArrangedSubview(caption)
        languageRow.addArrangedSubview(language)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [status, progress, spacer, primary, remove])
        actions.alignment = .centerY
        actions.spacing = 8
        actions.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true

        let content = NSStackView(views: [name, source, languageRow, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.setCustomSpacing(10, after: source)
        source.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true
        actions.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ model: ModelLibraryEntry, language choice: DictationLanguage?, allows: (ModelLibraryAction) -> Bool) {
        name.stringValue = "\(model.name) · \(model.size)"
        source.stringValue = model.source
        source.toolTip = model.source
        progress.setAccessibilityLabel("\(model.name) download progress")
        remove.setAccessibilityLabel("Remove \(model.name)")
        language.setAccessibilityLabel("Dictation Language for \(model.name)")
        languageRow.isHidden = choice == nil
        if let choice { language.selectItem(withTitle: choice.title) }

        switch model.state {
        case .notInstalled:
            show("Not Installed", action: .download, title: "Download", modelName: model.name)
        case let .downloading(fraction):
            let progress = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            show("Downloading \(Int(progress * 100))%", action: .cancel, title: "Cancel",
                 modelName: model.name, fraction: progress)
        case .installed:
            show("Installed", action: .use, title: "Use", modelName: model.name)
        case .active:
            show("Active", modelName: model.name)
        case let .unavailable(reason):
            show(reason, modelName: model.name)
        }
        primary.isEnabled = primaryAction.map(allows) ?? false
        remove.isHidden = primaryAction != .use || !model.removable
        remove.isEnabled = allows(.remove)
    }

    private func show(_ text: String, action: ModelLibraryAction? = nil, title: String = "",
                      modelName: String, fraction: Double? = nil) {
        status.stringValue = text
        status.textColor = action == nil ? .controlAccentColor : .secondaryLabelColor
        primaryAction = action
        primary.title = title
        primary.setAccessibilityLabel("\(title) \(modelName)")
        primary.isHidden = action == nil
        progress.isHidden = fraction == nil
        if let fraction { progress.doubleValue = fraction }
    }

    @objc private func performPrimary() {
        if let primaryAction { perform(primaryAction) }
    }

    @objc private func performRemove() {
        perform(.remove)
    }

    @objc private func selectLanguage() {
        let index = language.indexOfSelectedItem
        guard DictationLanguage.allCases.indices.contains(index) else { return }
        setLanguage(DictationLanguage.allCases[index])
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
                                     removable: record.canRemove)
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
        ModelLibraryEntry(id: "fp16", name: "Whisper Turbo FP16", size: "1.61 GB",
                          source: "Hugging Face · mlx-community/whisper-large-v3-turbo", state: .active),
        ModelLibraryEntry(id: "q4", name: "Whisper Turbo Q4", size: "464 MB",
                          source: "Hugging Face · mlx-community/whisper-large-v3-turbo-q4", state: .notInstalled),
        ModelLibraryEntry(id: "parakeet-v3", name: "Parakeet V3", size: "483 MB",
                          source: "FluidInference · Auto language", state: .notInstalled),
        ModelLibraryEntry(id: "parakeet-ultra", name: "Parakeet Ultra", size: "632 MB",
                          source: "FluidInference · Auto language", state: .notInstalled),
        ModelLibraryEntry(id: "parakeet-redux", name: "Parakeet Redux", size: "220 MB",
                          source: "FluidInference · Auto language", state: .notInstalled),
        ModelLibraryEntry(id: "nemotron-streaming", name: "Nemotron Streaming", size: "615 MB",
                          source: "FluidInference · Live streaming", state: .notInstalled),
    ]
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var downloadIndex: Int?
    private var step = 0

    func perform(_ action: ModelLibraryAction, modelID: String) {
        guard let index = models.firstIndex(where: { $0.id == modelID }) else { return }
        switch (action, models[index].state) {
        case (.download, .notInstalled) where downloadIndex == nil:
            downloadIndex = index
            step = 0
            models[index].state = .downloading(0)
            let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(advance(_:)),
                              userInfo: nil, repeats: true)
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
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
        let controller = ModelLibraryViewController(
            backend: DemoModelLibraryBackend(),
            notice: "Demo only. Actions are simulated; no network or files are used."
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 340),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "LocalVoice"
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 580, height: 565))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
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
