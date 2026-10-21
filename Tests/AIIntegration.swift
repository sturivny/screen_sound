import Foundation
@preconcurrency import AVFoundation

final class MockAPI: URLProtocol, @unchecked Sendable {
    static var onStart: (() -> Void)?
    static var holdRequests = false
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.holdRequests { Self.onStart?(); return }
        do {
            guard let handler = Self.handler else { throw AIError(message: "Unexpected network request") }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main
struct AIIntegration {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw AIError(message: "TEST FAILED: \(message)") }
    }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
    static func network(_ root: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAPI.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = AIClient(session: session)
        let fakeKey = "test-only-placeholder"
        let audio = root.appendingPathComponent("request.m4a")
        try Data([0, 1, 2, 255]).write(to: audio)
        MockAPI.handler = { req in
            try require(req.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions", "transcription destination")
            try require(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)", "auth header")
            let raw = body(req)
            let text = String(decoding: raw, as: UTF8.self)
            try require(text.contains("gpt-transcribe") && text.contains("Контекст Том"), "model/context missing")
            try require(text.contains("filename=\"audio.m4a\"") && text.contains("Content-Type: audio/mp4"), "audio multipart header")
            try require(raw.range(of: Data([0, 1, 2, 255])) != nil, "binary audio damaged")
            try require(!text.contains(fakeKey), "key leaked into multipart payload")
            return (200, Data(#"{"text":"Обсудили планы на квартал."}"#.utf8))
        }
        let transcript = try await client.transcribe(file: audio, model: "gpt-transcribe", context: "Контекст Том", key: fakeKey)
        try require(transcript.contains("планы"), "transcript decoding")
        print("PASS transcription multipart, UTF-8 context, auth and JSON response")
        MockAPI.handler = { req in
            try require(req.url?.path == "/v1/responses", "analysis endpoint")
            let json = try JSONSerialization.jsonObject(with: body(req)) as! [String: Any]
            try require(json["store"] as? Bool == false, "response storage must be disabled")
            try require(json["model"] as? String == "gpt-5.4-mini", "analysis model")
            let input = json["input"] as! [[String: String]]
            try require(input[0]["content"]?.contains("Цели на квартал") == true, "custom task lost")
            try require(input[1]["content"]?.contains(transcript) == true, "transcript lost")
            try require((json["instructions"] as? String)?.contains("Do not invent") == true, "evidence guard missing")
            return (200, Data(##"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"# Цели\nПроект предложения."}]}]}"##.utf8))
        }
        let analysis = try await client.analyze(transcript: transcript, context: "Том", task: "Цели на квартал", model: "gpt-5.4-mini", key: fakeKey)
        try require(analysis.contains("# Цели"), "analysis decoding")
        print("PASS Responses request, custom task, evidence instructions, store:false and output parsing")
        for status in [401, 403, 404, 413, 429, 500] {
            MockAPI.handler = { _ in (status, Data("PRIVATE SERVER BODY \(fakeKey)".utf8)) }
            do { _ = try await client.transcribe(file: audio, model: "gpt-transcribe", context: "", key: fakeKey); throw AIError(message: "unhandled HTTP \(status)") }
            catch let error as AIError {
                try require(!error.message.contains("PRIVATE") && !error.message.contains(fakeKey), "server detail leaked")
                try require(!error.message.contains("unhandled"), "HTTP error accepted")
            }
        }
        print("PASS auth/quota/server errors without leaking server content")
        for json in [#"{"status":"incomplete","output":[]}"#, #"{"status":"completed","output":[]}"#,
                     #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"No"}]}]}"#] {
            var rejected = false
            do { _ = try AIClient.parseAnalysis(Data(json.utf8)) } catch { rejected = true }
            try require(rejected, "empty/incomplete/refused analysis accepted")
        }
        var rejected = false
        do { _ = try AIClient.analysisBody(transcript: String(repeating: "a", count: 400_001), context: "", task: "", model: "test") }
        catch { rejected = true }
        try require(rejected, "oversized transcript accepted")
        print("PASS incomplete/refused output and oversized transcript rejected")
        MockAPI.holdRequests = true
        let started = AsyncStream<Void> { continuation in
            MockAPI.onStart = { continuation.yield(()); continuation.finish() }
        }
        let job = Task {
            try await client.transcribe(file: audio, model: "gpt-transcribe", context: "", key: fakeKey)
        }
        for await _ in started { break }
        job.cancel()
        var cancelled = false
        do { _ = try await job.value }
        catch is CancellationError { cancelled = true }
        catch let error as URLError where error.code == .cancelled { cancelled = true }
        MockAPI.holdRequests = false
        MockAPI.onStart = nil
        try require(cancelled, "in-flight API request ignored cancellation")
        print("PASS cancellation of in-flight API request")
    }
    static func media(_ root: URL) async throws {
        let parts = try AudioPreparation.parts(duration: 3600)
        try require(parts.first?.start == 0 && parts.last!.start + parts.last!.duration == 3600, "hour not fully covered")
        for i in 1..<parts.count {
            try require(abs(parts[i-1].start + parts[i-1].duration - parts[i].start - 2) < 0.001, "overlap mismatch")
        }
        for value in [0.0, Double.nan, -1, 43201] {
            var rejected = false
            do { _ = try AudioPreparation.parts(duration: value) } catch { rejected = true }
            try require(rejected, "invalid duration accepted")
        }
        print("PASS 1-hour chunk planning, overlap, invalid duration rejection")
        let input = root.appendingPathComponent("test.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        var output: AVAudioFile? = try AVAudioFile(forWriting: input, settings: settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 3)!
        pcm.frameLength = pcm.frameCapacity
        for c in 0..<2 { for i in 0..<Int(pcm.frameLength) { pcm.floatChannelData![c][i] = Float(0.15 * sin(Double(i) * 2 * .pi * 440 / 48_000)) } }
        try output!.write(from: pcm)
        output = nil
        let (asset, inspected) = try await AudioPreparation.inspect(input)
        try require(inspected.count == 1, "short media wrongly split")
        let destination = root.appendingPathComponent("prepared.m4a")
        try await AudioPreparation.export(asset: asset, part: AudioPart(index: 0, start: 0.5, duration: 1.5), to: destination)
        let result = AVURLAsset(url: destination)
        let videoCount = try await result.loadTracks(withMediaType: .video).count
        let audioCount = try await result.loadTracks(withMediaType: .audio).count
        let duration = try await result.load(.duration).seconds
        try require(videoCount == 0 && audioCount == 1, "upload media must be audio only")
        try require(abs(duration - 1.5) < 0.1, "wrong exported time range")
        print("PASS real audio extraction to M4A, selected time range, no video")
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await network(root)
        try await media(root)
    }
}
