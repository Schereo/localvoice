import Foundation

// Usage: model-library-smoke <existing-temp-directory> <python-executable>
@main
@MainActor
private struct ModelLibrarySmoke {
    private static let fp16 = "whisper-turbo-fp16"
    private static let q4 = "whisper-turbo-q4"
    private static let parakeet = "parakeet-v3"
    private static let nemotron = "nemotron-streaming"
    private static let qwen = "qwen3-asr-1.7b"

    static func main() {
        do {
            let arguments = CommandLine.arguments
            try expect(arguments.count == 3, "Usage: model-library-smoke <existing-temp-directory> <python-executable>")
            let scratch = URL(fileURLWithPath: arguments[1], isDirectory: true)
                .appendingPathComponent("model-library-\(UUID().uuidString)", isDirectory: true)
            let python = URL(fileURLWithPath: arguments[2])
            try expect(FileManager.default.isExecutableFile(atPath: python.path), "Python must be an executable file")
            let files = FileManager.default
            try files.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: scratch) }
            try run(in: scratch, python: python)
            print("Model library smoke test passed")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run(in scratch: URL, python: URL) throws {
        func file(_ name: String) -> URL { scratch.appendingPathComponent(name) }
        let script = file("localvoice_models.py")
        try fixture.write(to: script, atomically: true, encoding: .utf8)

        var activationRequests: [String] = []
        var activationOnMain = true
        var completeActivation: ((Bool) -> Void)?
        let backend = StoreModelLibraryBackend(python: python, store: script, selectedModel: fp16,
                                               parakeetWorker: file("localvoice-parakeet")) { id, complete in
            activationOnMain = activationOnMain && Thread.isMainThread
            activationRequests.append(id)
            completeActivation = complete
        }
        defer { backend.perform(.cancel, modelID: q4) }

        var progress: [Double] = []
        backend.onChange = { [weak backend] in
            if case let .downloading(fraction)? = backend?.models.first(where: { $0.id == q4 })?.state {
                progress.append(fraction)
            }
        }
        func isActive(_ id: String) -> Bool {
            if case .active? = backend.models.first(where: { $0.id == id })?.state { return true }
            return false
        }
        func isLoading(_ id: String) -> Bool {
            if case .loading? = backend.models.first(where: { $0.id == id })?.state { return true }
            return false
        }

        backend.refresh()
        try waitFor("initial status") { backend.allows(.download, modelID: q4) }
        try expect(isActive(fp16), "FP16 should start active")
        try expect(backend.models.first(where: { $0.id == "legacy" })?.removable == false,
                   "A shared-cache model must not expose Remove")
        try expect(!backend.allows(.remove, modelID: fp16), "Selected FP16 must not be removable")
        try expect(backend.allows(.use, modelID: parakeet), "An installed Parakeet must be selectable")
        try expect(!backend.allows(.download, modelID: "parakeet-redux"),
                   "An unsupported macOS version must block download")
        backend.perform(.remove, modelID: fp16)

        backend.perform(.download, modelID: q4)
        try waitFor("streamed progress before completion") { progress.contains(0.2) }
        try expect(!backend.allows(.download, modelID: q4), "A second download must be blocked")
        try expect(!backend.allows(.cancel, modelID: fp16), "Cancel must target only the managed download")
        backend.perform(.cancel, modelID: q4)
        try waitFor("status recheck after cancellation") { backend.allows(.download, modelID: q4) }
        try expect(FileManager.default.fileExists(atPath: file("cancelled").path), "Download did not receive SIGTERM")

        try Data().write(to: file("fail-download"))
        backend.perform(.download, modelID: q4)
        try waitFor("status recheck after failed download") { backend.allows(.download, modelID: q4) }
        try expect(backend.message?.contains("Could not download") == true &&
                   backend.message?.contains("private-path") == false,
                   "Download failure should be shown without raw subprocess output")
        try FileManager.default.removeItem(at: file("fail-download"))

        backend.perform(.download, modelID: q4)
        try waitFor("model installed after download") { backend.allows(.use, modelID: q4) }
        try expect(progress.contains(0.8), "The explicit percent update was not displayed")
        try expect(isActive(fp16) && activationRequests.isEmpty, "Download must not activate the model")

        backend.perform(.use, modelID: q4)
        try expect(isActive(fp16) && !backend.allows(.remove, modelID: q4),
                   "The previous model must stay active and Remove must be blocked while switching")
        try expect(isLoading(q4), "The model being switched to must show as loading")
        completeActivation?(false)
        try waitFor("failed activation") { backend.allows(.use, modelID: q4) }
        try expect(!isLoading(q4), "A failed switch must clear the loading state")
        try expect(isActive(fp16) && backend.message?.contains("Could not switch") == true,
                   "Failed activation must keep the previous selection and show an error")

        backend.perform(.use, modelID: q4)
        completeActivation?(true)
        try waitFor("successful activation") { isActive(q4) }
        try expect(activationOnMain && activationRequests == [q4, q4],
                   "Only Use should request activation, on the main thread")
        try expect(!backend.allows(.remove, modelID: q4), "Activated Q4 must not be removable")
        backend.perform(.remove, modelID: q4)
        backend.perform(.use, modelID: parakeet)
        completeActivation?(true)
        try waitFor("Parakeet selected") { isActive(parakeet) }
        backend.perform(.use, modelID: nemotron)
        completeActivation?(true)
        try waitFor("Nemotron selected") { isActive(nemotron) }
        backend.perform(.use, modelID: qwen)
        completeActivation?(true)
        try waitFor("Qwen selected") { isActive(qwen) }
        backend.perform(.use, modelID: fp16)
        completeActivation?(true)
        try waitFor("Whisper selected again") { isActive(fp16) }
        try expect(activationRequests.suffix(4) == [parakeet, nemotron, qwen, fp16],
                   "The picker must pass the stable IDs when switching providers")
        backend.setActiveModel(fp16)
        backend.perform(.remove, modelID: q4)
        try waitFor("status recheck after removing inactive Q4") { backend.allows(.download, modelID: q4) }
        let log = try String(contentsOf: file("commands"), encoding: .utf8)
        let removals = log.split(separator: "\n").filter { $0.hasPrefix("remove ") }
        try expect(removals == ["remove \(q4)"], "Only the inactive model may reach the remove command")

        try Data().write(to: file("bad-status"))
        backend.refresh()
        try waitFor("invalid status error") { backend.message?.contains("Could not read") == true }
        try expect(!backend.allows(.download, modelID: q4), "An invalid status must not leave actions enabled")
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    private static func waitFor(_ label: String, _ condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            try expect(ProcessInfo.processInfo.systemUptime < deadline, "Timed out waiting for \(label)")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private static let fixture = #"""
    import json
    import os
    import pathlib
    import signal
    import sys
    import time

    root = pathlib.Path(__file__).parent
    installed = root / "installed"
    cancelled = root / "cancelled"
    fp16, q4 = "whisper-turbo-fp16", "whisper-turbo-q4"
    command, *args = sys.argv[1:]
    with (root / "commands").open("a") as log:
        print(" ".join(sys.argv[1:]), file=log)

    def emit(**event):
        print(json.dumps(event), flush=True)

    def model(id, name, size, present=True, location="localvoice"):
        return dict(id=id, name=name, bytes=size, source="mlx-community/" + id,
                    status="installed" if present else "not-installed",
                    location=location if present else None,
                    removable=present and location == "localvoice")

    def cancel(*_):
        cancelled.touch()
        sys.exit(143)

    if command == "status":
        assert os.environ["LOCALVOICE_PARAKEET_WORKER"].endswith("/localvoice-parakeet")
        if (root / "bad-status").exists():
            print("not JSON")
        else:
            emit(models=[model(fp16, "FP16", 1613977880),
                         model(q4, "Q4", 463665005, present=installed.exists()),
                         model("legacy", "Legacy", 463665005, location="hf-cache"),
                         model("parakeet-v3", "Parakeet v3", 500000000),
                         model("nemotron-streaming", "Nemotron Streaming", 650000000),
                         model("qwen3-asr-1.7b", "Qwen3-ASR 1.7B", 2467775902),
                         dict(model("parakeet-redux", "Parakeet Redux", 220000000, present=False),
                              available=False, availability_reason="Requires macOS 15+")])
    elif command == "download":
        assert args == [q4]
        if (root / "fail-download").exists():
            emit(event="error", ok=False, id=q4, error="/fixture/private-path")
            sys.exit(1)
        signal.signal(signal.SIGTERM, cancel)
        emit(event="progress", id=q4, downloaded_bytes=20, total_bytes=100)
        if not cancelled.exists():
            time.sleep(10)
            sys.exit("Expected a cancellation")
        emit(event="progress", id=q4, percent=80)
        installed.touch()
        emit(event="success", ok=True, id=q4)
    elif command == "remove":
        assert args == [q4]
        installed.unlink()
        emit(event="success", ok=True, id=q4, removed=True)
    else:
        raise AssertionError(command)
    """#
}
