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
    static let binaryPCMTag: UInt8 = 0x01
    static let binaryNemotronChunkTag: UInt8 = 0x02

    private struct Payload: Decodable {
        let pcm: String
    }

    static func decode(_ line: Data) throws -> [Float] {
        if line.first == binaryPCMTag {
            return try decodeRawPCM(line.dropFirst())
        }
        return try decodeBase64((try? JSONDecoder().decode(Payload.self, from: line))?.pcm)
    }

    static func decodeRawPCM(_ bytes: Data) throws -> [Float] {
        guard !bytes.isEmpty, bytes.count <= maximumPCMBytes, bytes.count.isMultiple(of: 4) else {
            throw WorkerError.message("Expected nonempty float32 PCM at 16 kHz, at most \(maximumSeconds) seconds")
        }
        let count = bytes.count / 4
        let samples = Array<Float>(unsafeUninitializedCapacity: count) { destination, initializedCount in
            bytes.withUnsafeBytes { raw in
                guard let src = raw.baseAddress, let dst = destination.baseAddress else { return }
                #if _endian(little)
                memcpy(dst, src, bytes.count)
                #else
                for index in 0..<count {
                    let bits = raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                    dst[index] = Float(bitPattern: UInt32(littleEndian: bits))
                }
                #endif
            }
            initializedCount = count
        }
        for sample in samples {
            guard sample.isFinite else {
                throw WorkerError.message("PCM contains a non-finite sample")
            }
        }
        return samples
    }

    static func decodeBase64(_ pcm: String?) throws -> [Float] {
        guard let pcm, !pcm.isEmpty,
              pcm.utf8.count <= maximumBase64Bytes,
              let bytes = Data(base64Encoded: pcm) else {
            throw WorkerError.message("Expected nonempty base64 float32 PCM at 16 kHz, at most \(maximumSeconds) seconds")
        }
        return try decodeRawPCM(bytes)
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
        if line.first == PCMRequest.binaryNemotronChunkTag {
            return try .chunk(PCMRequest.decodeRawPCM(line.dropFirst()))
        }
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

    private mutating func ensureAvailable(_ needed: Int) throws -> Bool {
        while chunk.count < needed {
            let more = try nextChunk()
            if more.isEmpty { return false }
            chunk.append(more)
        }
        return true
    }

    private mutating func nextBinaryFrame(tag: UInt8) throws -> Line? {
        // Header: 1-byte tag + 4-byte little-endian uint32 byte count.
        guard try ensureAvailable(5) else { return nil }
        let start = chunk.startIndex
        let length = Int(UInt32(chunk[start + 1])
            | (UInt32(chunk[start + 2]) << 8)
            | (UInt32(chunk[start + 3]) << 16)
            | (UInt32(chunk[start + 4]) << 24))
        chunk = chunk[(start + 5)...]

        let maxBytes = min(limit, PCMRequest.maximumPCMBytes)
        if length > maxBytes {
            var remaining = length
            while remaining > 0 {
                if chunk.isEmpty {
                    chunk = try nextChunk()
                    if chunk.isEmpty { break }
                }
                let dropCount = min(remaining, chunk.count)
                chunk = chunk[(chunk.startIndex + dropCount)...]
                remaining -= dropCount
            }
            return .oversized
        }

        var payload = Data(capacity: 1 + length)
        payload.append(tag)
        var remaining = length
        while remaining > 0 {
            if chunk.isEmpty {
                chunk = try nextChunk()
                if chunk.isEmpty { return nil }
            }
            let take = min(remaining, chunk.count)
            let end = chunk.startIndex + take
            payload.append(contentsOf: chunk[..<end])
            chunk = chunk[end...]
            remaining -= take
        }
        return .bytes(payload)
    }

    mutating func next() throws -> Line? {
        if chunk.isEmpty {
            chunk = try nextChunk()
            if chunk.isEmpty { return nil }
        }
        if let first = chunk.first,
           first == PCMRequest.binaryPCMTag || first == PCMRequest.binaryNemotronChunkTag {
            return try nextBinaryFrame(tag: first)
        }

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
    var binary: Bool? = nil

    static let ready = Response(event: "ready", binary: true)
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
