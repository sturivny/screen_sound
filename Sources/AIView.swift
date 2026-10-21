import SwiftUI
import AppKit

struct AIView: View {
    @ObservedObject var ai: AIModel
    @ObservedObject var recorder: RecorderModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Transcription and AI tasks", systemImage: "text.bubble.fill").font(.title2.bold())
                    Spacer()
                    DisclosureGroup("OpenAI settings", isExpanded: $ai.settingsExpanded) { settings }.frame(width: 350)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(ai.sourceURL?.lastPathComponent ?? "No audio file selected", systemImage: "waveform")
                                .lineLimit(1).help(ai.sourceURL?.path ?? "")
                            Spacer()
                            Button("Choose file…") { ai.importAudio() }
                            Button("Last recording") {
                                if let file = recorder.lastFile { ai.selectSource(file) }
                            }.disabled(recorder.lastFile == nil)
                        }
                        TextField("Context: a conversation with Tom about team plans…", text: $ai.context, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...3)
                        Text("Context helps recognize names and terminology. Use the task field below to tell AI what to do with the text.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }.disabled(ai.busy || recorder.busy)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("What should AI do with the transcript?").font(.headline)
                        Spacer()
                        Menu("Templates") {
                            Button("Meeting summary") { ai.prompt = AIModel.Templates.meeting }
                            Button("Agreements and actions") { ai.prompt = AIModel.Templates.actions }
                            Button("Quarterly goals") { ai.prompt = AIModel.Templates.quarter }
                            Button("Custom task") { ai.prompt = "" }
                        }
                    }
                    TextEditor(text: $ai.prompt).font(.body).frame(height: 95)
                        .padding(5).background(.background).clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
                }.disabled(ai.busy)
                Text("Clicking a button below sends audio and context to OpenAI; tasks also send the transcript and your prompt. API usage is billed separately. Video frames are never uploaded.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Upload and transcribe") { ai.begin(withAnalysis: false) }
                        .disabled(!canTranscribe)
                    Button("Transcribe and run task") { ai.begin(withAnalysis: true) }
                        .buttonStyle(.borderedProminent).disabled(!canTranscribe || ai.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if ai.busy { Button("Cancel") { ai.cancel() } }
                }
                if !ai.keySaved {
                    Button("Add an API key in OpenAI settings") { ai.settingsExpanded = true }.buttonStyle(.link)
                }
                if let operation = ai.operation {
                    HStack { ProgressView().controlSize(.small); Text(operation); Spacer() }
                    ProgressView(value: ai.progress).progressViewStyle(.linear)
                } else { Text(ai.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Divider()
                HStack {
                    Picker("Result", selection: $ai.selectedResult) {
                        Text("Transcript").tag(0)
                        Text("AI result").tag(1)
                    }.pickerStyle(.segmented).frame(maxWidth: 360)
                    Spacer()
                    Button("Open text…") { ai.importTranscript() }.disabled(ai.busy)
                }
                TextEditor(text: ai.selectedResult == 0 ? $ai.transcript : $ai.analysis)
                    .font(.system(.body, design: .monospaced)).frame(height: 240).padding(6)
                    .background(.background).clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary)).disabled(ai.busy)
                HStack {
                    Button("Run task on transcript") { ai.analyzeOnly() }
                        .disabled(ai.busy || !ai.keySaved || ai.transcript.isEmpty || ai.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Copy") { ai.copyResult() }.disabled(resultEmpty)
                    Button("Save…") { ai.saveResult() }.disabled(resultEmpty || ai.busy)
                    if let directory = ai.resultDirectory {
                        Button("Show in Finder") { NSWorkspace.shared.open(directory) }
                    }
                }
                Text("Transcript times refer to recording segments. Speaker separation is not available yet. You can edit the text before running another task.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(22)
        }
        .alert("AI processing", isPresented: Binding(get: { ai.errorMessage != nil }, set: { if !$0 { ai.errorMessage = nil } })) {
            Button("OK") { ai.errorMessage = nil }
        } message: { Text(ai.errorMessage ?? "") }
    }
    private var canTranscribe: Bool { !ai.busy && !recorder.busy && ai.sourceURL != nil && ai.keySaved }
    private var resultEmpty: Bool { ai.selectedResult == 0 ? ai.transcript.isEmpty : ai.analysis.isEmpty }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(ai.keySaved ? "Key saved in macOS Keychain" : "No API key saved yet").font(.caption)
            SecureField(ai.keySaved ? "Enter a replacement key" : "OpenAI API key", text: $ai.keyInput)
                .textFieldStyle(.roundedBorder).privacySensitive()
            HStack {
                Button("Save key") { ai.saveKey() }.disabled(ai.keyInput.isEmpty)
                if ai.keySaved { Button("Remove key") { ai.removeKey() } }
                Link("Create a key", destination: URL(string: "https://platform.openai.com/api-keys")!)
            }.font(.caption)
            Text("Transcription model").font(.caption)
            TextField("Transcription model", text: $ai.transcriptionModel).textFieldStyle(.roundedBorder)
            Text("Analysis model").font(.caption)
            TextField("Analysis model", text: $ai.analysisModel).textFieldStyle(.roundedBorder)
            Text("Enter your key here only. It is not stored in the app files.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 8).disabled(ai.busy)
    }
}

struct MainView: View {
    @ObservedObject var recorder: RecorderModel
    @ObservedObject var ai: AIModel
    var body: some View {
        TabView(selection: $ai.selectedTab) {
            ScrollView {
                ContentView(model: recorder)
                if let file = recorder.lastFile {
                    Button("Use last recording for AI") { ai.selectSource(file); ai.selectedTab = 1 }
                        .disabled(ai.busy || recorder.busy).padding(.bottom, 16)
                }
            }.tabItem { Label("Recording", systemImage: "record.circle") }.tag(0)
            AIView(ai: ai, recorder: recorder).tabItem { Label("Transcript and AI", systemImage: "text.bubble") }.tag(1)
        }
        .frame(width: 820, height: 780)
        .onChange(of: recorder.lastFile) { _, file in
            if let file, !ai.busy { ai.selectSource(file) }
        }
    }
}
