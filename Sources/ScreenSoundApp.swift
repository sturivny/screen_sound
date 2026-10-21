import SwiftUI
import AppKit

@main
struct ScreenSoundApp: App {
    @StateObject private var model = RecorderModel()
    @StateObject private var ai = AIModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("ScreenSound") {
            MainView(recorder: model, ai: ai)
                .onAppear { delegate.model = model; delegate.ai = ai; NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        MenuBarExtra("ScreenSound", systemImage: model.phase == .recording ? "record.circle.fill" : "waveform.circle") {
            Text(model.status)
            if model.phase == .recording {
                Button("Stop recording") { Task { await model.stop() } }
            }
            Button("Show window") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }.disabled(model.busy || ai.busy)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecorderModel?
    weak var ai: AIModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.busy == true || ai?.busy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Finish processing first"
        alert.informativeText = "Stop recording or cancel AI processing, then wait for it to finish."
        alert.addButton(withTitle: "Continue")
        alert.runModal()
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ContentView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                if let icon = NSImage(named: "ScreenSound-icon") {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 50, height: 50)
                } else {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 44)).foregroundStyle(.indigo)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("ScreenSound").font(.title.bold())
                    Text("Your Mac audio and your voice, in one file").foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Mode", selection: $model.video) {
                        Text("Audio only · M4A").tag(false)
                        Text("Screen + audio · MP4").tag(true)
                    }.pickerStyle(.segmented)
                    Toggle("System audio", isOn: $model.system)
                    if model.system { gain("System volume", value: $model.systemGain) }
                    Toggle("Microphone", isOn: $model.microphone)
                    if model.microphone {
                        Picker("Source", selection: $model.microphoneID) {
                            Text("Default system microphone").tag("")
                            ForEach(model.microphones, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(device.uniqueID)
                            }
                        }
                        gain("Microphone volume", value: $model.micGain)
                    }
                    if model.video {
                        Picker("Display", selection: $model.displayID) {
                            if model.displays.isEmpty { Text("Selected when recording starts").tag(CGDirectDisplayID(0)) }
                            ForEach(model.displays, id: \.displayID) { display in
                                Text("Display \(display.displayID) · \(display.width) × \(display.height)").tag(display.displayID)
                            }
                        }
                        Text("Up to 1920 px wide at 30 fps, including the pointer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Refresh displays and microphones") { Task { await model.refreshSources() } }
                        .buttonStyle(.link)
                }.padding(10)
            }.disabled(model.busy)
            HStack {
                Circle().fill(model.phase == .recording ? .red : .secondary.opacity(0.35)).frame(width: 8, height: 8)
                Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let start = model.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                        Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                            .monospacedDigit()
                    }
                }
            }
            Button {
                Task {
                    if model.phase == .recording { await model.stop() } else { await model.start() }
                }
            } label: {
                HStack {
                    if model.phase == .preparing || model.phase == .finishing { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.phase == .recording ? "stop.fill" : "record.circle") }
                    Text(model.phase == .recording ? "Stop recording" : model.busy ? "Please wait…" : "Start recording")
                }.frame(maxWidth: .infinity).padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent).tint(model.phase == .recording ? .red : .indigo)
            .disabled(model.phase != .recording && !model.canStart)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            if let file = model.lastFile {
                HStack {
                    Label(file.lastPathComponent, systemImage: "checkmark.circle.fill").lineLimit(1)
                    Spacer()
                    Button(model.copyingFile ? "Exporting…" : "Export to Downloads") { model.exportToDownloads() }.disabled(model.copyingFile)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }.font(.caption).disabled(model.busy)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow screen and system audio recording, and microphone access when prompted. ScreenCaptureKit needs capture permission even for audio only. If macOS requests a restart, quit and reopen the app.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Screen permissions") { model.openPrivacy("Privacy_ScreenCapture") }
                    Button("Microphone permissions") { model.openPrivacy("Privacy_Microphone") }
                }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(26).frame(width: 540)
        .alert("ScreenSound", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private func gain(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 145, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%").font(.caption.monospacedDigit()).frame(width: 38)
        }
    }
}
