import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit

@main
struct MediaIntegration {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw RecorderError(message: "TEST FAILED: \(message)") }
    }
    static func audio(rate: Double, channels: Int, frequency: Double, time: Double, origin: CMTime) throws -> CMSampleBuffer {
        let frames = Int(rate / 100)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: AVAudioChannelCount(channels), interleaved: true)!
        var description: CMAudioFormatDescription?
        var asbd = format.streamDescription.pointee
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr else { fatalError("audio format") }
        var values = [Float](repeating: 0, count: frames * channels)
        for n in 0..<frames {
            let value = Float(0.2 * sin(2 * .pi * frequency * (time + Double(n) / rate)))
            for c in 0..<channels { values[n * channels + c] = value }
        }
        var block: CMBlockBuffer?
        let bytes = values.count * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr else { fatalError("block") }
        _ = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: origin + CMTime(seconds: time, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var size = channels * MemoryLayout<Float>.size
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: description!, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &buffer) == noErr else { fatalError("sample buffer") }
        return buffer!
    }
    static func video(time: Double, origin: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        CVPixelBufferLockBaseAddress(pixel!, [])
        memset(CVPixelBufferGetBaseAddress(pixel!), 80, CVPixelBufferGetDataSize(pixel!))
        CVPixelBufferUnlockBaseAddress(pixel!, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: origin + CMTime(seconds: time, preferredTimescale: 60_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!,
            formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &result)
        return result!
    }
    static func checkAudio(_ url: URL, tones: [Double]) throws {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let rate = file.processingFormat.sampleRate
        let start = Int(rate * 0.4), length = Int(rate * 0.5)
        try require(Int(buffer.frameLength) > start + length, "decoded audio too short")
        if tones.contains(880) {
            var r = 0.0, i = 0.0
            let a = Int(rate * 0.04), count = Int(rate * 0.08)
            for n in a..<(a + count) {
                let angle = 2 * Double.pi * 880 * Double(n) / rate
                r += Double(samples[n]) * cos(angle)
                i += Double(samples[n]) * sin(angle)
            }
            try require(2 * hypot(r, i) / Double(count) < 0.01, "microphone offset lost")
        }
        for frequency in tones {
            var real = 0.0, imaginary = 0.0
            for n in 0..<length {
                let angle = 2 * Double.pi * frequency * Double(start + n) / rate
                real += Double(samples[start + n]) * cos(angle)
                imaginary += Double(samples[start + n]) * sin(angle)
            }
            let amplitude = 2 * hypot(real, imaginary) / Double(length)
            try require(amplitude > 0.07, "missing \(frequency) Hz tone (\(amplitude))")
            print("  decoded \(Int(frequency)) Hz amplitude: \(String(format: "%.3f", amplitude))")
        }
    }
    static func run(_ root: URL, name: String, screen: Bool, system: Bool, mic: Bool, silentSystem: Bool = false) async throws {
        let origin = CMTime(seconds: 10, preferredTimescale: 60_000)
        let sink = try RecordingSink(rawURL: root.appendingPathComponent("\(name)-raw.mov"),
            videoSize: screen ? CGSize(width: 320, height: 180) : nil,
            system: system, microphone: mic, origin: origin, systemGain: 0.7, micGain: 0.7)
        // Realtime pacing exercises writer backpressure as well as mixed native formats.
        for tick in 0..<150 {
            let t = Double(tick) / 100
            let buffers: [(SCStreamOutputType, CMSampleBuffer)] = try [
                system && !silentSystem ? (.audio, audio(rate: 48_000, channels: 2, frequency: 440, time: t, origin: origin)) : nil,
                // Mic starts 200ms later: preserve offsets rather than shift it to zero.
                mic && tick >= 20 ? (.microphone, audio(rate: 44_100, channels: 1, frequency: 880, time: t, origin: origin)) : nil,
                screen && tick % 3 == 0 ? (.screen, video(time: t, origin: origin)) : nil
            ].compactMap { $0 }
            await withCheckedContinuation { continuation in
                sink.queue.async {
                    for (type, buffer) in buffers { sink.append(buffer, type: type) }
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try await sink.finish(at: origin + CMTime(seconds: 1.5, preferredTimescale: 60_000))
        try require(result.dropped == 0, "unexpected dropped buffers")
        let destination = root.appendingPathComponent("\(name).\(screen ? "mp4" : "m4a")")
        try await sink.export(to: destination)
        let asset = AVURLAsset(url: destination)
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        let videoCount = try await asset.loadTracks(withMediaType: .video).count
        try require(audioCount == (system || mic ? 1 : 0), "must export ONE mixed audio track")
        try require(videoCount == (screen ? 1 : 0), "wrong video track count")
        let duration = try await asset.load(.duration).seconds
        try require(duration > 1.2 && duration < 1.7, "bad duration: \(duration)")
        if system || mic { try checkAudio(destination, tones: (system && !silentSystem ? [440] : []) + (mic ? [880] : [])) }
        print("PASS \(name): \(audioCount) audio, \(videoCount) video, \(String(format: "%.2f", duration)) s")
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await run(root, name: "mixed-audio", screen: false, system: true, mic: true)
        try await run(root, name: "screen-mixed", screen: true, system: true, mic: true)
        try await run(root, name: "system-only", screen: false, system: true, mic: false)
        try await run(root, name: "mic-only", screen: false, system: false, mic: true)
        try await run(root, name: "missing-system", screen: false, system: true, mic: true, silentSystem: true)
        try await run(root, name: "silent-video", screen: true, system: false, mic: false)
        let empty = try RecordingSink(rawURL: root.appendingPathComponent("empty.mov"), videoSize: nil,
            system: true, microphone: true, origin: .zero, systemGain: 1, micGain: 1)
        do { _ = try await empty.finish(at: CMTime(seconds: 1, preferredTimescale: 600)); fatalError("empty recording accepted") }
        catch { print("PASS empty recording rejected: \(error.localizedDescription)") }
    }
}
