import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit

struct RecorderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// All writer state is confined to queue, including finishing after SCStream stops.
final class RecordingSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "ScreenSound.media", qos: .userInitiated)
    let rawURL: URL
    private let writer: AVAssetWriter
    private var inputs: [SCStreamOutputType: AVAssetWriterInput] = [:]
    private var counts: [SCStreamOutputType: Int] = [:]
    private var accepting = true
    private var failure: Error?
    private var dropped = 0
    private let origin: CMTime
    private let includeVideo: Bool
    private let systemGain: Float
    private let micGain: Float

    init(rawURL: URL, videoSize: CGSize?, system: Bool, microphone: Bool,
         origin: CMTime, systemGain: Float, micGain: Float) throws {
        self.rawURL = rawURL
        self.origin = origin
        self.includeVideo = videoSize != nil
        self.systemGain = systemGain
        self.micGain = micGain
        writer = try AVAssetWriter(outputURL: rawURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        super.init()
        if let size = videoSize {
            try add(.screen, media: .video, settings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000,
                                                  AVVideoMaxKeyFrameIntervalKey: 60]
            ])
        }
        for (type, enabled) in [(SCStreamOutputType.audio, system), (.microphone, microphone)] where enabled {
            // Each source has its own encoder. Mic input may have a different native sample rate.
            try add(type, media: .audio, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
        }
        guard writer.startWriting() else { throw writer.error ?? RecorderError(message: "Could not open the recording file.") }
        writer.startSession(atSourceTime: origin)
    }

    private func add(_ type: SCStreamOutputType, media: AVMediaType, settings: [String: Any]) throws {
        let input = AVAssetWriterInput(mediaType: media, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError(message: "Could not create the \(media.rawValue) track.") }
        writer.add(input)
        inputs[type] = input
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  status == SCFrameStatus.complete.rawValue else { return }
        }
        append(buffer, type: type)
    }

    /// Called only on queue. Also used by the synthetic media integration test.
    func append(_ buffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard accepting, failure == nil, buffer.isValid, CMSampleBufferDataIsReady(buffer),
              let input = inputs[type], buffer.presentationTimeStamp >= origin else { return }
        guard input.isReadyForMoreMediaData else { dropped += 1; return }
        if input.append(buffer) { counts[type, default: 0] += 1 }
        else { failure = writer.error ?? RecorderError(message: "Failed to write the media track.") }
    }

    struct Result {
        let rawURL: URL
        let counts: [SCStreamOutputType: Int]
        let dropped: Int

    }

    func finish(at end: CMTime) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.accepting = false
                if let failure = self.failure {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: failure)
                    return
                }
                guard !self.counts.isEmpty else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: RecorderError(message: "The recording is empty: no data was received."))
                    return
                }
                if self.includeVideo && self.counts[.screen, default: 0] == 0 {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: RecorderError(message: "No screen frames were received."))
                    return
                }
                self.writer.endSession(atSourceTime: end)
                for input in self.inputs.values { input.markAsFinished() }
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        continuation.resume(returning: Result(rawURL: self.rawURL,
                            counts: self.counts, dropped: self.dropped))
                    } else {
                        continuation.resume(throwing: self.writer.error ?? RecorderError(message: "Could not finish the recording."))
                    }
                }
            }
        }
    }

    /// Export explicitly mixes the independent source tracks into one playable audio track.
    func export(to url: URL) async throws {
        let asset = AVURLAsset(url: rawURL)
        let composition = AVMutableComposition()
        var parameters: [AVAudioMixInputParameters] = []
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let expectedTypes: [SCStreamOutputType] = [.audio, .microphone].filter { counts[$0, default: 0] > 0 }
        for (index, track) in audioTracks.enumerated() {
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RecorderError(message: "Could not create the audio mix.")
            }
            let range = try await track.load(.timeRange)
            try target.insertTimeRange(range, of: track, at: range.start)
            let parameter = AVMutableAudioMixInputParameters(track: target)
            let kind = index < expectedTypes.count ? expectedTypes[index] : .audio
            parameter.setVolume(kind == .microphone ? micGain : systemGain, at: .zero)
            parameters.append(parameter)
        }
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RecorderError(message: "Could not create the video track.")
            }
            let range = try await track.load(.timeRange)
            try target.insertTimeRange(range, of: track, at: range.start)
            target.preferredTransform = try await track.load(.preferredTransform)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        guard let session = AVAssetExportSession(asset: composition,
                presetName: includeVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A) else {
            throw RecorderError(message: "The export format is unavailable.")
        }
        session.audioMix = mix
        do { try await session.export(to: url, as: includeVideo ? .mp4 : .m4a) }
        catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
