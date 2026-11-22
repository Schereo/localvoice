import Foundation

@main
enum ProtocolTests {
    static func main() async throws {
        try testOversizedLine()
        try testPCM()
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
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let json = try output.split(separator: "\n").map {
            try JSONDecoder().decode([String: String].self, from: Data($0.utf8))
        }
        expect(json.map { $0["event"] } == ["ready", "result", "error", "error", "result"], "wrong events")
        expect(json[1] == ["event": "result", "text": "1.0\n"], "wrong result")
        expect(json[3] == ["event": "error", "error": "inference failed"], "wrong error")
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
