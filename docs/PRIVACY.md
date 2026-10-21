# Privacy and local data

## Local recording

Capture, writing, mixing and recording export run locally. Stopping a recording
does not start an AI job. ScreenCaptureKit requires macOS capture permission even
when no video output is registered. Microphone access is requested only for that
source. The app never changes system privacy grants on its own.

Completed media and recoverable sources live in Application Support/ScreenSound/Recovery.
Exports to Downloads are additional copies. The latest recording path is kept in
UserDefaults. Local recordings are not automatically deleted.

## Explicit OpenAI upload

- Transcription sends prepared audio and entered context to
  `https://api.openai.com/v1/audio/transcriptions`.
- Analysis sends transcript, context and task to `https://api.openai.com/v1/responses`.
- Video frames are removed before transcription. Analysis does not upload audio again.
- API authorization uses the user's key in the request header. HTTP redirects are rejected.
- The API key is stored in macOS Keychain, not source files, preferences or text exports.
- No real key is needed for the repository's tests. They use mocked network responses.

Responses uses `store: false`. Provider-side retention, project controls and billing
still apply; consult the current [OpenAI data guide](https://developers.openai.com/api/docs/guides/your-data).

## Text results and preferences

Transcript checkpoints and AI results are saved under Application Support/ScreenSound/AI.
Saved transcript documents include source file name, entered context, model and
completion status. Results remain after failure/cancellation. Temporary prepared
audio segments are removed when the job finishes or exits.

The task prompt and model names persist in UserDefaults. Context is not a preference,
but is included in saved transcript documents. User-authored prompts can themselves
contain private information. Review local files before sharing them.

## Repository boundary

Commit source, tests, documentation and design assets only. Personal recordings,
transcripts, exports, keys, preferences and local process samples are not fixtures.
.gitignore excludes common media, credential and generated artifact paths. Before
pushing, review the actual staged file list; ignore rules are a safeguard, not a
substitute for inspecting the changes.
