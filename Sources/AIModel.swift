import SwiftUI
import CryptoKit
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AIModel: ObservableObject {
    @Published var selectedTab = 0
    @Published var settingsExpanded = false
    @Published var transcriptComplete = false
    @Published var sourceURL: URL?
    @Published var keyInput = ""
    @Published var keySaved = KeychainStore.hasKey()
    @Published var context = ""
    @Published var prompt = Templates.initialPrompt() {
        didSet { UserDefaults.standard.set(prompt, forKey: "ai.prompt") }
    }
    @Published var transcriptionModel = UserDefaults.standard.string(forKey: "ai.transcriptionModel") ?? "gpt-transcribe" {
        didSet { UserDefaults.standard.set(transcriptionModel, forKey: "ai.transcriptionModel") }
    }
    @Published var analysisModel = UserDefaults.standard.string(forKey: "ai.analysisModel") ?? "gpt-5.4-mini" {
        didSet { UserDefaults.standard.set(analysisModel, forKey: "ai.analysisModel") }
    }
    @Published var transcript = ""
    @Published var analysis = ""
    @Published var selectedResult = 0
    @Published var operation: String?
    @Published var progress = 0.0
    @Published var status = "Choose a file or use the last recording"
    @Published var errorMessage: String?
    @Published var resultDirectory: URL?
    private var task: Task<Void, Never>?
    private var jobIdentity = ""
    private var completedParts: [Int: String] = [:]
    private let client = AIClient()
    var busy: Bool { operation != nil }

    enum Templates {
        static func initialPrompt() -> String {
            guard let saved = UserDefaults.standard.string(forKey: "ai.prompt") else { return quarter }
            let hash = SHA256.hash(data: Data(saved.utf8)).map { String(format: "%02x", $0) }.joined()
            // Migrate built-in templates only; preserve the user's custom prompts.
            switch hash {
            case "c54c9f8c11c2251011ea7f5888d199b1c6c40c5fa062a26b7b5d75d3dccd548d": return meeting
            case "2fad0ae23515f7ae186be3773b8cb135b3b076af4d920a377aa41d2305ccb395": return actions
            case "f7a093944c872007622a8b51824a165f402a2ffae5edc5bac4c5ae4adfdd3d43": return quarter
            default: return saved
            }
        }

        static let meeting = "Summarize the meeting in English: topics, decisions, and open questions. Use the transcript as evidence; do not add facts that were not stated."
        static let actions = "Extract agreements and action items. For each, include the action, owner, and deadline if stated. Clearly mark missing details. List questions that need clarification separately. Answer in English."
        static let quarter = "This conversation is about plans for next quarter. Briefly summarize the discussion and identify any explicitly agreed goals. Then propose quarterly goals with an outcome, success criteria, owner, and deadline. Do not invent agreements or metrics: label new goals and criteria as proposals, and list missing details as questions to clarify. Answer in English."
    }

    func saveKey() {
        do { try KeychainStore.save(keyInput); keyInput = ""; keySaved = true; status = "API key saved in macOS Keychain" }
        catch { errorMessage = error.localizedDescription }
    }
    func removeKey() {
        do { try KeychainStore.delete(); keyInput = ""; keySaved = false; status = "API key removed" }
        catch { errorMessage = error.localizedDescription }
    }
    func selectSource(_ url: URL) {
        guard !busy, sourceURL != url else { return }
        sourceURL = url
        transcript = ""
        transcriptComplete = false
        analysis = ""
        completedParts = [:]
        jobIdentity = ""
        resultDirectory = nil
        status = "Recording selected. Nothing is uploaded until you click a button below."
    }
    func importAudio() {
        let panel = NSOpenPanel()
        panel.title = "Choose audio or video to transcribe"
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        FilePanels.present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectSource(url)
        }
    }
    func importTranscript() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Open a transcript for analysis"
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        FilePanels.present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.loadTranscript(url)
        }
    }
    private func loadTranscript(_ url: URL) {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 400_000 else { throw AIError(message: "The text exceeds 400 KB. Split it into separate meetings.") }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError(message: "The text file is empty.") }
            sourceURL = nil; transcript = text; transcriptComplete = true; analysis = ""; resultDirectory = nil
            jobIdentity = ""; completedParts = [:]; selectedResult = 0
            status = "Transcript loaded. You can run a task without uploading audio."
        } catch { errorMessage = error.localizedDescription }
    }
    func begin(withAnalysis: Bool) {
        guard !busy, let source = sourceURL else { return }
        let context = context, prompt = prompt
        let transcriptionModel = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let analysisModel = analysisModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcriptionModel.isEmpty, !withAnalysis || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Choose a transcription model and enter a task."; return
        }
        operation = "Preparing audio…"; progress = 0; errorMessage = nil
        task = Task {
            defer { operation = nil; task = nil }
            var working: URL?
            defer { if let working { try? FileManager.default.removeItem(at: working) } }
            do {
                let key = try KeychainStore.read()
                let metadata = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let identity = "\(source.path)|\(metadata.fileSize ?? 0)|\(metadata.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(transcriptionModel)|\(context)"
                if identity != jobIdentity {
                    jobIdentity = identity; completedParts = [:]; transcript = ""; transcriptComplete = false; analysis = ""
                    resultDirectory = nil
                }
                try ensureDirectory()
                let (asset, parts) = try await AudioPreparation.inspect(source)
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenSound-AI-\(UUID().uuidString)", isDirectory: true)
                working = temp
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                for part in parts {
                    try Task.checkCancellation()
                    if completedParts[part.index] == nil {
                        operation = "Preparing segment \(part.index + 1) of \(parts.count)…"
                        let audio = temp.appendingPathComponent("part-\(part.index).m4a")
                        try await AudioPreparation.export(asset: asset, part: part, to: audio)
                        operation = "Transcribing segment \(part.index + 1) of \(parts.count)…"
                        let text = try await client.transcribe(file: audio, model: transcriptionModel, context: context, key: key)
                        completedParts[part.index] = "[\(part.label)]\n\(text)"
                        try? FileManager.default.removeItem(at: audio)
                    }
                    transcript = completedParts.keys.sorted().compactMap { completedParts[$0] }.joined(separator: "\n\n")
                    transcriptComplete = completedParts.count == parts.count
                    try persistTranscript(complete: transcriptComplete,
                        source: source.lastPathComponent, context: context, model: transcriptionModel)
                    progress = Double(part.index + 1) / Double(parts.count)
                }
                selectedResult = 0
                status = "Transcript ready and saved locally"
                if withAnalysis {
                    try Task.checkCancellation()
                    operation = "Running your task…"
                    try await performAnalysis(key: key, context: context, prompt: prompt, model: analysisModel)
                }
            } catch { handle(error) }
        }
    }

    func analyzeOnly() {
        guard !busy, !transcript.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let context = context, prompt = prompt, model = analysisModel.trimmingCharacters(in: .whitespacesAndNewlines)
        operation = "Running your task…"; errorMessage = nil
        task = Task {
            defer { operation = nil; task = nil }
            do {
                let key = try KeychainStore.read()
                try ensureDirectory()
                // Preserve imported or user-edited source text even if the request fails.
                try persistTranscript(complete: transcriptComplete, source: sourceURL?.lastPathComponent ?? "Imported text",
                                      context: context, model: transcriptionModel)
                try await performAnalysis(key: key, context: context, prompt: prompt, model: model)
            } catch { handle(error) }
        }
    }
    private func performAnalysis(key: String, context: String, prompt: String, model: String) async throws {
        let text = try await client.analyze(transcript: (transcriptComplete ? "" : "NOTE: This is a partial transcript. The rest of the audio has not been transcribed.\n\n") + transcript, context: context, task: prompt, model: model, key: key)
        analysis = text; selectedResult = 1
        guard let directory = resultDirectory else { return }
        let document = "# AI result\n\nModel: \(model)\n\n## Task\n\n\(prompt)\n\n## Result\n\n\(text)\n"
        try document.write(to: directory.appendingPathComponent("analysis.md"), atomically: true, encoding: .utf8)
        status = "Transcript and result saved locally"
    }
    private func ensureDirectory() throws {
        if resultDirectory != nil { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenSound/AI/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        resultDirectory = directory
    }
    private func persistTranscript(complete: Bool, source: String, context: String, model: String) throws {
        guard let directory = resultDirectory else { return }
        let document = "# Transcript\n\nSource: \(source)\n\nStatus: \(complete ? "complete" : "partial")\n\nModel: \(model)\n\nContext: \(context)\n\nTime ranges refer to segments, not individual utterances. Segment boundaries may repeat speech (2-second overlap).\n\n\(transcript)\n"
        try document.write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }
    private func handle(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            status = "Processing cancelled. Text already received has been saved."
        } else {
            errorMessage = error.localizedDescription
            status = "Processing did not finish. Any text already received has been saved."
        }
    }
    func cancel() { status = "Cancelling…"; task?.cancel() }
    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedResult == 0 ? transcript : analysis, forType: .string)
    }
    func saveResult() {
        let text = selectedResult == 0 ? transcript : analysis
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Save text"
        panel.nameFieldStringValue = selectedResult == 0 ? "transcript.txt" : "analysis.md"
        panel.allowedContentTypes = selectedResult == 0 ? [.plainText] : [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        FilePanels.present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }
}
