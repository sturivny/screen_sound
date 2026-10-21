# Development and validation

## Prerequisites and commands

Use Apple Silicon with macOS 15+, Command Line Tools containing SDK macOS 15+
and Swift 6+, or Xcode 16+. `build.sh` targets arm64-apple-macosx15.0 in Swift 5
language mode. It has no downloaded dependencies.

From the repository root:

```bash
./build.sh
./test.sh
./test-ai.sh
plutil -lint Info.plist ScreenSound.xcodeproj/project.pbxproj
codesign --verify --strict build/ScreenSound.app
```

Build output, module cache and test executables are under ignored `build/`.
Test media lives in a fresh temporary directory, removed by a shell trap.
When using an automated sandbox, local system media encoders may be unavailable:
Cannot Encode is a runner limitation until confirmed otherwise. Request the
appropriate execution access or report that media tests were not run. Do not
change production codec settings solely to hide a restricted-runner failure.

## Coverage

`Tests/MediaIntegration.swift` passes synthetic PCM/video buffers through the same
RecordingSink used by the app. It checks:

- mixed M4A and MP4 export and one final audio track;
- both 440/880 Hz signals after decoding;
- 48 kHz stereo system input and 44.1 kHz mono microphone input;
- a delayed microphone retaining its initial timing offset;
- source-only modes, a missing system signal, silent video and empty-recording rejection;
- duration, track counts and dropped buffers.

`Tests/AIIntegration.swift` checks mocked multipart and Responses requests,
UTF-8 context, auth placement, store:false, task/evidence separation, response
parsing, 401/403/404/413/429/500 handling without body leakage, incomplete/refused
responses, oversize text and cancellation of an in-flight request. It also checks
hour-long segment planning and real AVFoundation audio extraction to M4A.

Tests do not validate recognition accuracy or real API account access.
The media test currently emits a Swift Sendable warning for captured CMSampleBuffers
in Swift 5 mode. The production build passes; do not claim Swift 6 strict-mode compliance.

## Manual checks for relevant UI/capture changes

Only capture live media when authorized by the user doing the test.

1. Use one installed copy and verify its bundle version and signature.
2. Start/stop a short audio recording with system audio and microphone enabled.
3. Confirm stop returns to an enabled Start recording button, clears the timer,
   shows Recording saved locally and does not open a save panel.
4. Export to Downloads; verify the copy's contents match and the original remains.
   An existing name must produce a suffix rather than overwrite.
5. Relaunch and confirm the latest completed recording is available.
6. For video changes, check picture, pointer, both audio sources and synchronization.
7. For AI UI changes, check import/cancel, templates, editable result selection and
   saving text. Do not upload a real conversation merely to validate the UI.

## Installation and code identity

Building does not modify the installed app. Install only within the user's
authorized task, after checking for active capture/processing and recoverable data.
Keep a rollback build when replacing a working installation. Never force quit an
app with potentially unsaved media before preserving what is available.

The current app is ad-hoc signed, not Developer ID signed or notarized. Rebuilding
changes its code hash; TCC can keep an old requirement while showing an enabled
switch. Read-only diagnosis can inspect the bundle signature and app-specific TCC
messages. A confirmed stale grant is refreshed through System Settings for only
ScreenSound, with user authorization and owner authentication where requested.
Do not edit the TCC database, reset unrelated applications, weaken signing checks,
or bypass system authentication.

A release intended for other Macs needs an appropriate signing identity and
notarization. Do not commit certificates or key material. Bump version/build in
Info.plist for a release and check all Xcode resources are included.

## Baseline evidence

On 21 October 2026 the 1.2 code built with Swift 6.4 / Command Line Tools on
macOS 27.0.1, targeting macOS 15. Both integration scripts passed. A local manual
check confirmed start, stop, return to idle and Downloads export; a previously
completed recording was recovered and its exported copy matched byte for byte.

The project was not run on macOS 15 or 26 in that environment, an Xcode-driven build
was not verified, and real-key API transcription quality was not tested. These
are historical baseline checks; rerun the relevant commands for a new change.
