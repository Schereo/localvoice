import CoreML
import Darwin
import FluidAudio
import Foundation

actor NemotronSession {
    private static let chunkSamples = 35_840
    private let manager: StreamingNemotronMultilingualAsrManager
    private var active = false

    private init(manager: StreamingNemotronMultilingualAsrManager) {
        self.manager = manager
    }

    static func load(from root: URL) async throws -> NemotronSession {
        let directory = root.appendingPathComponent("multilingual", isDirectory: true)
            .appendingPathComponent("2240ms", isDirectory: true)
        let config = try NemotronMultilingualStreamingConfig(
            from: directory.appendingPathComponent("metadata.json")
        )
        guard config.sampleRate == 16_000, config.chunkMs == 2240, config.chunkSamples == chunkSamples else {
            throw WorkerError.message("Nemotron requires the 2240 ms tier (35840 samples at 16 kHz)")
        }
        // Require the compiled encoder and fused decoder from this tier. FluidAudio's
        // directory loader does not download, but can compile uncompiled bundles.
        for name in ["encoder.mlmodelc", "decoder_joint.mlmodelc"] {
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw WorkerError.message("Missing compiled Nemotron asset at \(path)")
            }
        }

        // FluidAudio exposes the encoder-specific compute setting through the
        // child process environment. The base configuration controls the fused decoder.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        for (name, value) in [
            ("FLUIDAUDIO_ENCODER_CU", "CPU_AND_GPU"),
            ("FLUIDAUDIO_DECODER_CU", "CPU_ONLY"),
            ("FLUIDAUDIO_JOINT_CU", "CPU_ONLY"),
        ] {
            guard setenv(name, value, 1) == 0 else {
                throw WorkerError.system("set \(name)", errno)
            }
        }
        let manager = StreamingNemotronMultilingualAsrManager(configuration: configuration)
        try await manager.loadModels(from: directory)
        return NemotronSession(manager: manager)
    }

    func handle(_ command: NemotronCommand) async throws -> String {
        switch command {
        case .start(let language):
            await manager.reset()
            await manager.setLanguage(language.prompt)
            active = true
            return ""
        case .chunk(let samples):
            try requireStart()
            do {
                _ = try await manager.process(samples: samples)
                // `process` always returns an empty string in FluidAudio 0.17.7.
                return await manager.getPartialTranscript()
            } catch {
                active = false
                throw error
            }
        case .finish:
            try requireStart()
            active = false
            return try await manager.finish()
        }
    }

    private func requireStart() throws {
        guard active else {
            throw WorkerError.message("Send a Nemotron start command before chunk or finish")
        }
    }
}
