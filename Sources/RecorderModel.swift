import SwiftUI
import ScreenCaptureKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class RecorderModel: NSObject, ObservableObject, SCStreamDelegate {
    enum Phase { case idle, preparing, recording, finishing }
    @Published var phase: Phase = .idle
    @Published var video = false
    @Published var system = true
    @Published var microphone = true
    @Published var systemGain: Double = 0.7
    @Published var micGain: Double = 0.7
    @Published var displays: [SCDisplay] = []
    @Published var displayID: CGDirectDisplayID = 0
    @Published var microphones: [AVCaptureDevice] = []
    @Published var microphoneID = ""
    @Published var status = "Ready to record"
    @Published var errorMessage: String?
    @Published var lastFile: URL? {
        didSet {
            if let lastFile { UserDefaults.standard.set(lastFile.path, forKey: "recorder.lastFile") }
        }
    }
    @Published var startedAt: Date?
    @Published var copyingFile = false
    private var stream: SCStream?
    private var sink: RecordingSink?
    private var recordingDirectory: URL?
    private var capturedVideo = false
    private var activity: NSObjectProtocol?
    var busy: Bool { phase != .idle }
    var canStart: Bool { !busy && (system || microphone || video) }

    override init() {
        super.init()
        refreshMicrophones()
        restoreLastRecording()
    }

    private func restoreLastRecording() {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let path = UserDefaults.standard.string(forKey: "recorder.lastFile"), fm.fileExists(atPath: path) {
            candidates.append(URL(fileURLWithPath: path))
        }
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenSound/Recovery", isDirectory: true)
        if let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                       options: [.skipsHiddenFiles]) {
            for case let url as URL in entries where ["m4a", "mp4"].contains(url.pathExtension) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > 0 { candidates.append(url) }
            }
        }
        lastFile = candidates.max { left, right in
            let a = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        if lastFile != nil { status = "Last recording restored" }
    }

    func refreshMicrophones() {
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices
    }

    func loadDisplays() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        displays = content.displays
        guard !displays.isEmpty else { throw RecorderError(message: "No display is available.") }
        if !displays.contains(where: { $0.displayID == displayID }) { displayID = displays[0].displayID }
    }

    func refreshSources() async {
        guard !busy else { return }
        phase = .preparing
        defer { phase = .idle }
        do { refreshMicrophones(); try await loadDisplays(); status = "Sources refreshed" }
        catch { show(error) }
    }

    func start() async {
        guard canStart else { return }
        phase = .preparing
        status = "Checking permissions…"
        errorMessage = nil
        do {
            if microphone {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else {
                    throw RecorderError(message: "Microphone access is denied. Allow ScreenSound in System Settings → Privacy & Security → Microphone.")
                }
            }
            // SCShareableContent triggers the native screen/system-audio TCC permission flow.
            try await loadDisplays()
            guard let display = displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError(message: "The selected display is disconnected. Refresh the sources.")
            }
            if microphone && !microphoneID.isEmpty {
                refreshMicrophones()
                guard microphones.contains(where: { $0.uniqueID == microphoneID }) else {
                    throw RecorderError(message: "The selected microphone is disconnected. Choose another source.")
                }
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = min(1.0, 1920.0 / Double(display.width))
            let width = max(2, Int(Double(display.width) * scale) / 2 * 2)
            let height = max(2, Int(Double(display.height) * scale) / 2 * 2)
            config.width = video ? width : 2
            config.height = video ? height : 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: video ? 30 : 1)
            config.queueDepth = 5
            config.showsCursor = video
            config.capturesAudio = system
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.captureMicrophone = microphone
            config.microphoneCaptureDeviceID = microphoneID.isEmpty ? nil : microphoneID
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ScreenSound/Recovery/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            recordingDirectory = directory
            capturedVideo = video
            let output = try RecordingSink(rawURL: directory.appendingPathComponent("sources.mov"),
                videoSize: video ? CGSize(width: width, height: height) : nil,
                system: system, microphone: microphone, origin: CMClockGetTime(CMClockGetHostTimeClock()),
                systemGain: Float(systemGain), micGain: Float(micGain))
            sink = output
            let capture = SCStream(filter: filter, configuration: config, delegate: self)
            stream = capture
            if video { try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue) }
            if system { try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue) }
            if microphone { try capture.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue) }
            try await capture.startCapture()
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                            reason: "ScreenSound is recording")
            startedAt = Date()
            phase = .recording
            status = "Recording"
        } catch {
            // A partially started stream must not keep recording after an error.
            try? await stream?.stopCapture()
            stream = nil
            if let sink { _ = try? await sink.finish(at: CMClockGetTime(CMClockGetHostTimeClock())) }
            self.sink = nil
            phase = .idle
            show(error)
        }
    }

    func stop(interruption: String? = nil) async {
        guard phase == .recording, let output = sink else { return }
        phase = .finishing
        status = "Finishing recording and mixing audio…"
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        var stopWarning = interruption
        do { try await stream?.stopCapture() }
        catch { stopWarning = stopWarning ?? error.localizedDescription }
        stream = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        defer { sink = nil; startedAt = nil; phase = .idle }
        do {
            let result = try await output.finish(at: end)
            guard let directory = recordingDirectory else { throw RecorderError(message: "The recording folder is unavailable.") }
            let date = DateFormatter()
            date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let name = "ScreenSound_\(date.string(from: Date())).\(capturedVideo ? "mp4" : "m4a")"
            let completed = directory.appendingPathComponent(name)
            try await output.export(to: completed)
            lastFile = completed
            var warnings: [String] = []
            if system && result.counts[.audio, default: 0] == 0 { warnings.append("No system audio was received.") }
            if microphone && result.counts[.microphone, default: 0] == 0 { warnings.append("No microphone audio was received.") }
            if result.dropped > 0 { warnings.append("Dropped buffers: \(result.dropped).") }
            if let stopWarning { warnings.append(stopWarning) }
            status = warnings.isEmpty ? "Recording saved locally" : warnings.joined(separator: " ")
            // The recording is already on disk. Do not open a modal panel from this async task.
            // The user can export it to Downloads later, or open its folder in Finder.
            try? FileManager.default.removeItem(at: result.rawURL)
        } catch {
            lastFile = FileManager.default.fileExists(atPath: output.rawURL.path) ? output.rawURL : nil
            show(RecorderError(message: "\(error.localizedDescription) The source recording, if available, was kept at \(output.rawURL.path)"))
        }
    }

    func exportToDownloads() {
        guard !copyingFile, let source = lastFile else { return }
        copyingFile = true
        Task { @MainActor in
            defer { copyingFile = false }
            do {
                let destination = try await Task.detached(priority: .userInitiated) {
                    let manager = FileManager.default
                    let directory = try manager.url(for: .downloadsDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
                    let base = source.deletingPathExtension().lastPathComponent
                    var destination = directory.appendingPathComponent(source.lastPathComponent)
                    var suffix = 1
                    while manager.fileExists(atPath: destination.path) {
                        destination = directory.appendingPathComponent("\(base)-\(suffix).\(source.pathExtension)")
                        suffix += 1
                    }
                    try manager.copyItem(at: source, to: destination)
                    return destination
                }.value
                if self.lastFile == source { self.lastFile = destination }
                if self.phase == .idle { self.status = "Copy saved in Downloads" }
            } catch { self.show(error) }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if self.phase == .recording { await self.stop(interruption: "Recording interrupted: \(error.localizedDescription)") }
        }
    }

    func show(_ error: Error) {
        errorMessage = error.localizedDescription
        status = "The operation could not be completed"
    }

    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
