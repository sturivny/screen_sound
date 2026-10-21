# User guide

## Recording

Choose **Audio only · M4A** or **Screen + audio · MP4**. Enable system audio,
microphone, or both. A screen recording can also run without sound.
Select the microphone; use **Refresh displays and microphones** to select another
display or pick up newly connected devices. Refreshing displays can request capture access.

Start/stop is available in the window (Shift-Command-R) and stop is available in
the menu bar. The app prevents ordinary quitting while recording or AI processing
is active; stop or cancel that work first. Closing the window leaves the menu bar app running.

System audio covers the Mac's audio output, excluding ScreenSound's own process.
The selected display controls the video source. Headphones avoid recording speaker
output a second time through the microphone. ScreenSound does not add echo cancellation.
The source gains are fixed when capture starts; the default 70% leaves mixing headroom.
Protected media may not be captured. Device removal or permission changes can stop capture.

## Storage and export

Completed recordings are saved under:

```text
~/Library/Application Support/ScreenSound/Recovery/<session-id>/
```

After stopping, wait for **Recording saved locally**. No save dialog opens automatically.
**Show in Finder** reveals the current recording. **Export to Downloads** copies it
to Downloads, adding a numeric suffix if the name already exists. This copy runs
in the background and leaves the original in place.

On launch, the app selects the newest existing completed M4A/MP4 from Recovery
or the last file path saved in its preferences. Selection is based on modification time.
Files are not automatically deleted. After verifying an exported copy, you may
remove older local Recovery files yourself.

If export fails, a `sources.mov` may remain. It can contain separate audio tracks;
it is not the final mixed recording. Fragmented recording improves recoverability
but does not guarantee a playable file after a crash or sudden power loss.

## Permissions

ScreenCaptureKit needs **Screen & System Audio Recording** permission even for
audio-only recording. Microphone access is requested when the microphone source is enabled.
The app has links to the relevant System Settings pages. It may also request
Downloads access when exporting. If macOS requests a relaunch, quit and reopen it.

### Access denied even though the switch is on

Ad-hoc builds have changing code signatures. A permission entry can still refer
to an older build even when its switch is enabled. Use the installed copy in
Applications rather than several build folders.

If a stale entry is confirmed, quit ScreenSound, remove only its entry from
Screen & System Audio Recording, add the exact installed app again, enable it,
and relaunch. This is a user-authorized permission refresh, not a global reset.
macOS may require the Mac owner's Touch ID or password confirmation.

### Unresponsive after stopping

First inspect Recovery before force quitting: the final M4A/MP4 may already exist.
Make a verified copy of completed media before terminating an unresponsive process.
Version 1.2 removed the automatic save panel that previously left the recording
state stuck at finishing. Do not delete local recordings to troubleshoot the UI.

## Transcription and AI tasks

1. Open **Transcript and AI → OpenAI settings**.
2. Create an API key in the [OpenAI dashboard](https://platform.openai.com/api-keys)
   and configure API billing. Enter the key in the app and click **Save key**.
3. Choose a recording or use **Last recording**. Existing audio or video can be imported.
4. Add context such as participants, names and terminology. This is a recognition hint.
5. Enter a task or select **Meeting summary**, **Agreements and actions**, or
   **Quarterly goals**. You can replace any template with your own instructions.
6. Choose **Upload and transcribe** or **Transcribe and run task**.

Transcript and AI result are separate editable views. **Run task on transcript**
uses the existing text, so a new task does not require uploading the audio again.
**Open text…** accepts a UTF-8 TXT or Markdown transcript. Copy and Save are available
for text results. A custom prompt can request a different output language.

Transcription receives audio and context. Analysis receives transcript, context,
and task. Only the selected action starts an upload. Video frames are removed.
The API key stays in Keychain; it is not included in text results.

The default models are `gpt-transcribe` and `gpt-5.4-mini`. You can change names in
settings if your project has access to compatible models. Transcription models
must accept the current multipart request with `prompt` and return JSON `text`.
Analysis models must support the Responses API. Check current provider availability.

## Long recordings, cancellation and results

Audio is prepared as M4A in segments of up to 8 minutes with 2-second overlap.
Each upload must be smaller than 24,000,000 bytes. Segment time labels are approximate
ranges, not word timestamps. Overlap may duplicate speech; speaker diarization and
voice-to-name identification are not implemented.

AI preparation accepts recordings up to 12 hours. A single analysis accepts at
most 400,000 bytes of UTF-8 transcript and does not silently truncate the tail.

Each completed transcript segment is saved to:

```text
~/Library/Application Support/ScreenSound/AI/<job-id>/transcript.md
```

The AI result is saved beside it as `analysis.md`. A partial transcript is marked
as partial. Failed analysis can be repeated using the already saved transcript.
Cancel keeps received text. During the same app session, rerunning the same source,
context, and transcription model reuses completed segments. After restarting,
open the saved transcript for analysis; transcription resume is not persisted.
Temporary audio segments are removed when a job exits. Local text results remain.
Already processed API requests may be billed even if you cancel.

Review names, decisions, and proposed goals before relying on the AI result.
