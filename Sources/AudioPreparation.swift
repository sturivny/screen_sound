import Foundation
@preconcurrency import AVFoundation

struct AudioPart: Sendable {
    let index: Int
    let start: Double
    let duration: Double
    var label: String {
        func stamp(_ value: Double) -> String {
            let n = Int(value)
            return String(format: "%02d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
        }
        return "\(stamp(start))–\(stamp(start + duration))"
    }
}

enum AudioPreparation {
    /// 8 minutes per request, with 2s overlap to preserve words at part boundaries.
    static func parts(duration: Double, chunkLength: Double = 480) throws -> [AudioPart] {
        guard duration.isFinite, duration > 0, duration <= 12 * 3600, chunkLength > 2 else {
            throw AIError(message: "The recording must be longer than zero and no more than 12 hours.")
        }
        var result: [AudioPart] = []
        var start = 0.0
        while start < duration {
            let length = min(chunkLength, duration - start)
            result.append(AudioPart(index: result.count, start: start, duration: length))
            if start + length >= duration { break }
            start += chunkLength - 2
        }
        return result
    }
    static func inspect(_ url: URL) async throws -> (AVURLAsset, [AudioPart]) {
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw AIError(message: "The selected file has no audio track.")
        }
        let duration = try await asset.load(.duration).seconds
        return (asset, try parts(duration: duration))
    }
    static func export(asset: AVAsset, part: AudioPart, to url: URL) async throws {
        try Task.checkCancellation()
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: part.start, preferredTimescale: 48_000),
                                duration: CMTime(seconds: part.duration, preferredTimescale: 48_000))
        // Do not send video frames. All audio tracks of an imported media file are mixed.
        var params: [AVAudioMixInputParameters] = []
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        for track in tracks {
            let available = try await track.load(.timeRange)
            let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
            if intersection.isEmpty { continue }
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw AIError(message: "Could not prepare the audio.")
            }
            try target.insertTimeRange(intersection, of: track, at: intersection.start - range.start)
            let parameter = AVMutableAudioMixInputParameters(track: target)
            parameter.setVolume(1 / Float(max(1, tracks.count)), at: .zero)
            params.append(parameter)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AIError(message: "Could not create an audio segment.")
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        exporter.audioMix = mix
        try await exporter.export(to: url, as: .m4a)
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size < AIClient.maxUploadBytes else {
            throw AIError(message: "The prepared segment exceeds the API upload limit.")
        }
    }
}
