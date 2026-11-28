import Foundation

@main
enum ProtocolTests {
    static func main() async throws {
        try testOversizedLine()
        try testPCM()
        try testBinaryFrames()
        try testMaximumDuration()
        try testNemotronCommands()
        try await testSession()
        print("Parakeet protocol tests passed")
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        let ok = try condition()
        precondition(ok, message)
    }

    static func testOversizedLine() throws {
        var chunks = ["1234", "5", "6789\nOK\n", "\n", "end", ""].makeIterator()
        var reader = LineReader(limit: 5, nextChunk: { Data((chunks.next() ?? "").utf8) })
        try expect(reader.next() == .oversized, "oversized line accepted")
        try expect(reader.next() == .bytes(Data("OK".utf8)), "lost line after oversized input")
        try expect(reader.next() == .bytes(Data()), "lost blank line")
        try expect(reader.next() == .bytes(Data("end".utf8)), "lost buffered input at EOF")
        try expect(reader.next() == nil, "EOF yielded an extra line")
    }

    static func expectInvalid(_ line: Data) throws {
        do {
            _ = try PCMRequest.decode(line)
        } catch WorkerError.message {
            return
        }
        preconditionFailure("invalid PCM accepted")
    }

    static func testPCM() throws {
        let pcm = Data([0, 0, 128, 63, 0, 0, 0, 191]).base64EncodedString()
        try expect(PCMRequest.decode(Data(#"{"pcm":"\#(pcm)"}"#.utf8)) == [1, -0.5], "wrong endianness or format")
        for line in [#"{"pcm":null}"#, #"{"pcm":""}"#, #"{"pcm":"a!"}"#,
                     #"{"pcm":"AQ=="}"#, #"{"pcm":"AACAfw=="}"#, #"{"pcm":"AADAfw=="}"#] {
            try expectInvalid(Data(line.utf8))
        }
    }

    static func testBinaryFrames() throws {
        func frame(tag: UInt8, payload: Data) -> Data {
            var out = Data([tag])
            var len = UInt32(payload.count).littleEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(payload)
            return out
        }

        let raw = Data([0, 0, 128, 63, 0, 0, 0, 191]) // [1.0, -0.5]
        let f1 = frame(tag: PCMRequest.binaryPCMTag, payload: raw)
        let f2 = Data(#"{"command":"start","language":"de"}"#.utf8) + Data([0x0a])
        let f3 = frame(tag: PCMRequest.binaryNemotronChunkTag, payload: raw)
        let combined = f1 + f2 + f3
        // Feed in small pieces to test split headers and payloads.
        var offset = 0
        var reader = LineReader(nextChunk: {
            if offset >= combined.count { return Data() }
            let end = min(offset + 3, combined.count)
            let piece = combined[offset..<end]
            offset = end
            return Data(piece)
        })
        guard case .bytes(let b1)? = try reader.next() else { preconditionFailure("missing binary frame 1") }
        try expect(PCMRequest.decode(b1) == [1.0, -0.5], "binary Parakeet PCM mismatch")
        guard case .bytes(let b2)? = try reader.next() else { preconditionFailure("missing json line") }
        try expect(NemotronCommand.decode(b2) == .start(.de), "mixed JSON after binary failed")
        guard case .bytes(let b3)? = try reader.next() else { preconditionFailure("missing binary frame 2") }
        try expect(NemotronCommand.decode(b3) == .chunk([1.0, -0.5]), "binary Nemotron chunk mismatch")
        try expect(reader.next() == nil, "expected EOF after binary frames")

        // Non-finite binary float (NaN) must be rejected.
        let nanFrame = Data([PCMRequest.binaryPCMTag, 0, 0, 192, 127])
        try expectInvalid(nanFrame)
    }

    static func testMaximumDuration() throws {
        let maximum = PCMRequest.maximumPCMBytes
        let pcm = Data(count: maximum).base64EncodedString()
        try expect(PCMRequest.decode(Data(#"{"pcm":"\#(pcm)"}"#.utf8)).count == 480_000, "30 seconds rejected")
        let tooLong = Data(count: maximum + 4).base64EncodedString()
        try expectInvalid(Data(#"{"pcm":"\#(tooLong)"}"#.utf8))
    }

    static func testSession() async throws {
        let valid = #"{"pcm":"AACAPw=="}"#
        var chunks = ["\(valid)\ninvalid\n\(valid)\n\(valid)\n", ""].makeIterator()
        let reader = LineReader(nextChunk: { Data((chunks.next() ?? "").utf8) })
        let pipe = Pipe()
        var calls = 0
        try await serve(output: pipe.fileHandleForWriting, reader: reader) { data in
            let samples = try PCMRequest.decode(data)
            calls += 1
            if calls == 2 { throw WorkerError.message("inference failed") }
            return "\(samples[0])\n"
        }
        try pipe.fileHandleForWriting.close()
        struct EventReply: Decodable, Equatable {
            let event: String
            let text: String?
            let error: String?
            let binary: Bool?
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let json = try output.split(separator: "\n").map {
            try JSONDecoder().decode(EventReply.self, from: Data($0.utf8))
        }
        expect(json.map(\.event) == ["ready", "result", "error", "error", "result"], "wrong events")
        expect(json[0].binary == true, "ready must advertise binary support")
        expect(json[1] == EventReply(event: "result", text: "1.0\n", error: nil, binary: nil), "wrong result")
        expect(json[3] == EventReply(event: "error", text: nil, error: "inference failed", binary: nil), "wrong error")
        expect(json[4] == json[1] && calls == 3, "worker did not recover")
    }

    static func testNemotronCommands() throws {
        for (code, language, prompt) in [
            ("de", NemotronCommand.Language.de, "de-DE"), ("en", .en, "en-US"), ("auto", .auto, "auto"),
        ] {
            let start = Data(#"{"command":"start","language":"\#(code)"}"#.utf8)
            try expect(NemotronCommand.decode(start) == .start(language), "wrong start command")
            expect(language.prompt == prompt, "wrong language prompt")
        }
        let chunk = Data(#"{"command":"chunk","pcm":"AACAPw=="}"#.utf8)
        try expect(NemotronCommand.decode(chunk) == .chunk([1]), "wrong chunk command")
        let finish = Data(#"{"command":"finish"}"#.utf8)
        try expect(NemotronCommand.decode(finish) == .finish, "wrong finish command")
        for invalid in [#"{"command":"start"}"#, #"{"command":"start","language":"fr"}"#,
                        #"{"command":"chunk"}"#, #"{"pcm":"AACAPw=="}"#, #"{"command":"stop"}"#] {
            do {
                _ = try NemotronCommand.decode(Data(invalid.utf8))
            } catch WorkerError.message {
                continue
            }
            preconditionFailure("invalid Nemotron command accepted")
        }
    }
}
