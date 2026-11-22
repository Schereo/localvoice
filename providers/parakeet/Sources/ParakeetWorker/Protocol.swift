import Darwin
import Foundation

enum WorkerError: LocalizedError {
    case message(String)
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .system(let operation, let code): return "\(operation) failed (errno \(code))"
        }
    }
}

enum PCMRequest {
    static let maximumSeconds = 30
    static let maximumPCMBytes = 16_000 * maximumSeconds * 4
    static let maximumBase64Bytes = ((maximumPCMBytes + 2) / 3) * 4
    static let maximumLineBytes = maximumBase64Bytes + 1024

    private struct Payload: Decodable {
        let pcm: String
    }

    static func decode(_ line: Data) throws -> [Float] {
        try decodeBase64((try? JSONDecoder().decode(Payload.self, from: line))?.pcm)
    }

    static func decodeBase64(_ pcm: String?) throws -> [Float] {
        guard let pcm, !pcm.isEmpty,
              pcm.utf8.count <= maximumBase64Bytes,
              let bytes = Data(base64Encoded: pcm),
              !bytes.isEmpty, bytes.count <= maximumPCMBytes,
              bytes.count.isMultiple(of: 4) else {
            throw WorkerError.message("Expected nonempty base64 float32 PCM at 16 kHz, at most \(maximumSeconds) seconds")
        }

        return try bytes.withUnsafeBytes { buffer in
            try stride(from: 0, to: buffer.count, by: 4).map { offset in
                let bits = buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let sample = Float(bitPattern: UInt32(littleEndian: bits))
                guard sample.isFinite else {
                    throw WorkerError.message("PCM contains a non-finite sample")
                }
                return sample
            }
        }
    }
}

enum NemotronCommand: Equatable {
    enum Language: String, Decodable {
        case de, en, auto

        var prompt: String {
            switch self {
            case .de: "de-DE"
            case .en: "en-US"
            case .auto: "auto"
            }
        }
    }

    case start(Language)
    case chunk([Float])
    case finish

    private struct Payload: Decodable {
        let command: String
        let language: Language?
        let pcm: String?
    }

    static func decode(_ line: Data) throws -> Self {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: line) else {
            throw WorkerError.message("Expected a Nemotron command and valid language or PCM")
        }
        switch payload.command {
        case "start":
            guard let language = payload.language else {
                throw WorkerError.message("Nemotron start requires language de, en, or auto")
            }
            return .start(language)
        case "chunk":
            return try .chunk(PCMRequest.decodeBase64(payload.pcm))
        case "finish":
            return .finish
        default:
            throw WorkerError.message("Unknown Nemotron command; expected start, chunk, or finish")
        }
    }
}

struct LineReader {
    enum Line: Equatable {
        case bytes(Data)
        case oversized
    }

    private let limit: Int
    private let nextChunk: () throws -> Data
    private var chunk = Data()

    init(limit: Int = PCMRequest.maximumLineBytes, nextChunk: (() throws -> Data)? = nil) {
        self.limit = limit
        self.nextChunk = nextChunk ?? Self.readInput
    }

    mutating func next() throws -> Line? {
        var line = Data()
        var oversized = false
        while true {
            if chunk.isEmpty {
                chunk = try nextChunk()
                if chunk.isEmpty {
                    if oversized { return .oversized }
                    return line.isEmpty ? nil : .bytes(line)
                }
            }

            let newline = chunk.firstIndex(of: 0x0a)
            let end = newline ?? chunk.endIndex
            if !oversized {
                let count = end - chunk.startIndex
                if count <= limit - line.count {
                    line.append(contentsOf: chunk[..<end])
                } else {
                    oversized = true
                    line.removeAll()
                }
            }
            if let newline {
                chunk = chunk[(newline + 1)...]
                return oversized ? .oversized : .bytes(line)
            }
            chunk = Data()
        }
    }

    private static func readInput() throws -> Data {
        var data = Data(count: 64 * 1024)
        while true {
            let count = data.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count >= 0 {
                data.count = count
                return data
            }
            let code = errno
            if code != EINTR { throw WorkerError.system("read stdin", code) }
        }
    }
}

struct Response: Encodable {
    let event: String
    var text: String? = nil
    var error: String? = nil

    static let ready = Response(event: "ready")
    static func result(_ text: String) -> Self { Response(event: "result", text: text) }
    static func failure(_ error: String) -> Self { Response(event: "error", error: error) }
}

func send(_ response: Response, to output: FileHandle) throws {
    var json = try JSONEncoder().encode(response)
    json.append(0x0a)
    try output.write(contentsOf: json)
}

func serve(
    output: FileHandle,
    reader: LineReader = LineReader(),
    isolation: isolated (any Actor)? = #isolation,
    handle: (Data) async throws -> String
) async throws {
    var reader = reader
    try send(.ready, to: output)
    while let line = try reader.next() {
        let response: Response
        do {
            guard case .bytes(let data) = line else {
                throw WorkerError.message("Request exceeds the \(PCMRequest.maximumLineBytes)-byte limit")
            }
            response = try await .result(handle(data))
        } catch {
            response = .failure(error.localizedDescription)
        }
        try send(response, to: output)
    }
}
