import CoreML
import Darwin
import FluidAudio
import Foundation

@main
enum Worker {
    static func main() async {
        let output: FileHandle
        do {
            output = try isolateOutput()
        } catch {
            exit(EXIT_FAILURE)
        }

        AppLogger.mirrorsToConsole = false
        AppLogger.minimumLevel = .fault

        let handle: @Sendable (Data) async throws -> String
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 3, arguments[2].hasPrefix("/") else {
                throw WorkerError.message("Usage: localvoice-parakeet <v3|ultra|redux|nemotron> <absolute model directory>")
            }
            let variant = arguments[1]
            let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
            if variant == "nemotron" {
                let session = try await NemotronSession.load(from: directory)
                handle = { try await session.handle(NemotronCommand.decode($0)) }
            } else {
                handle = try loadParakeet(variant: variant, directory: directory)
            }
        } catch {
            let backend = CommandLine.arguments.dropFirst().first == "nemotron" ? "Nemotron" : "Parakeet"
            try? send(.failure("\(backend) startup failed: \(error.localizedDescription)"), to: output)
            exit(EXIT_FAILURE)
        }

        do {
            try await serve(output: output, handle: handle)
        } catch {
            // Broken I/O ends the session. Do not try to write a second response.
            exit(EXIT_FAILURE)
        }
    }

    private static func loadParakeet(
        variant: String, directory: URL
    ) throws -> @Sendable (Data) async throws -> String {
        let version: AsrModelVersion
        switch variant {
        case "v3": version = .v3
        case "ultra": version = .ultra
        case "redux":
            guard #available(macOS 15, *) else {
                throw WorkerError.message("Parakeet Redux requires macOS 15 or later")
            }
            version = .redux
        default:
            throw WorkerError.message("Unknown ASR variant; expected v3, ultra, redux, or nemotron")
        }
        // Keep the smaller components on CPU and avoid Neural Engine compilation.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let models = try AsrModels.loadLocal(
            from: directory, version: version, configuration: configuration,
            encoderPrecision: .int8, encoderComputeUnits: .cpuAndGPU
        )
        let manager = AsrManager(models: models)
        return { data in
            let samples = try PCMRequest.decode(data)
            var state = try TdtDecoderState(decoderLayers: version.decoderLayers)
            let result = try await manager.transcribe(samples, decoderState: &state)
            return result.text
        }
    }

    private static func isolateOutput() throws -> FileHandle {
        // Save the parent's stdout for JSON only. Redirect both standard streams before any
        // Core ML work; prints and native logs must not corrupt JSON or block on a log pipe.
        let protocolFD = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3)
        guard protocolFD >= 0 else { throw WorkerError.system("dup stdout", errno) }
        let output = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: true)
        let sink = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard sink >= 0 else { throw WorkerError.system("open /dev/null", errno) }
        defer { if sink > STDERR_FILENO { close(sink) } }
        guard dup2(sink, STDOUT_FILENO) >= 0, dup2(sink, STDERR_FILENO) >= 0 else {
            throw WorkerError.system("redirect output", errno)
        }
        return output
    }
}
