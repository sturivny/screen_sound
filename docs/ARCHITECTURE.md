# Architecture

The app has no package dependencies. SwiftUI/AppKit manage UI and file access;
ScreenCaptureKit captures media; AVFoundation writes, mixes and exports it;
Foundation URLSession calls OpenAI; Security/LocalAuthentication access Keychain.

## Source map

| File | Responsibility |
| --- | --- |
| `ScreenSoundApp.swift` | App lifecycle, menu bar controls, recording UI and quit guard |
| `RecorderModel.swift` | Main-actor capture lifecycle, permissions, restoration and Downloads copy |
| `RecordingSink.swift` | Serial-queue sample handling, AVAssetWriter and mixed export |
| `AIView.swift` | Tabs, context/task editors, model/key controls and text result editors |
| `AIModel.swift` | Job state, segment cache, local transcript checkpoints and analysis |
| `AudioPreparation.swift` | Audio-only composition, duration limits, segment planning and M4A export |
| `AIClient.swift` | Fixed OpenAI endpoints, multipart/JSON payloads, parsing and error handling |
| `KeychainStore.swift` | API credential storage, retrieval and deletion |
| `FilePanels.swift` | Retained, completion-based panels for AI file import/export |

## Capture and export

```text
SCStream (selected display; selected audio sources)
  ├─ screen buffers, optional ── H.264 writer input
  ├─ system audio buffers ────── AAC writer input
  └─ microphone buffers ──────── separate AAC writer input
                      ↓
             Recovery/session/sources.mov
                      ↓
       AVMutableComposition + AVAudioMix
                      ↓
             one mixed audio track
                      ↓
        completed .m4a or screen + .mp4
```

All capture callbacks and writer mutation execute on `RecordingSink.queue`.
The host clock establishes the session origin; sample timestamps preserve source
offsets. Source-native formats can differ; inputs use separate encoders.
The stream delivers video only when the screen output is registered. Audio-only
mode configures a minimal stream but never attaches a screen writer/output.

`RecorderModel.phase` follows idle → preparing → recording → finishing → idle.
Stop first stops SCStream, then drains/finishes the writer and awaits mixed export.
The final file is assigned before temporary source removal. Cleanup of timer,
sink and phase is deferred until that operation returns. No save panel runs here.
`exportToDownloads` copies off the main actor and preserves the original file.

## AI flow

```text
Selected media → AVFoundation audio-only segments → audio/transcriptions
  → checkpoint transcript.md after each part
  → optional Responses request with transcript + context + task
  → analysis.md
```

`AIModel` is main-actor isolated; async media/network operations yield to the UI.
Parts are cached by index under a job identity incorporating source path, file size,
modification time, transcription model and context. The cache is in memory;
checkpoint Markdown is durable but is not a cross-launch resume manifest.

`AIClient` creates an ephemeral URLSession, disables cookies/cache and rejects
redirects. Its destination is fixed to api.openai.com. Responses requests include
`store: false`; this is not a guarantee of zero provider retention. HTTP error
messages do not display raw server response bodies. Incomplete/refused/empty
analysis is rejected. Cancellation reaches the active URLSession request.

Analysis instructions treat the transcript as untrusted evidence and separate
proposed goals from explicit agreements. They do not establish speaker identities.

## Build resources and state

`Info.plist` defines bundle ID `local.screensound.recorder`, deployment target,
usage descriptions and the ICNS icon. The CLI build copies Assets resources;
Xcode has corresponding resource and source build phases.

UserDefaults stores the latest recording path, custom prompt and model names.
Known old Russian built-in templates migrate to English by SHA-256 identity;
custom prompts are preserved. Keychain service `local.screensound.recorder.openai`
uses account `api-key` with device-only accessibility. Keychain and TCC depend
on code identity, so rebuild/install workflows must account for ad-hoc signatures.
