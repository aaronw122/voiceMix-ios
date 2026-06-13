# Codex Review R1 — iMessage Steel Thread

## Critical

None.

## Must-fix

None.

## Medium

- Clarify the terminal success state: `insertAttachment` inserts into the Messages input field, not necessarily the sent transcript — `Goal (DoD)`, `Build order / Insert inline`. Suggested fix: make the green-thread DoD "audio attachment appears in the compose field and plays; user can tap Send to deliver it" unless the plan intentionally uses a send API instead.

- Make the bundled MP3 resource a first-class build step — `The mock seam`, `Build order / Wire the mock service`. Suggested fix: add an explicit step to add `sample.mp3` to the `voiceMixerMessages` target resources and verify `Bundle.main.url(forResource:withExtension:)` resolves before the Send flow depends on it.

## Low

- Tighten the mock protocol narrative so `convert` and `fetchAudio` responsibilities are unambiguous — `The mock seam`. Suggested fix: state that mock `convert` returns a dummy `{url,title,audioUrl}` response, while mock `fetchAudio` maps that dummy `audioUrl` to a local bundled/copied MP3 file.

## Impl-note

- Configure and activate the audio session for recording, not only permission — `Build order / Recorder`. Suggested fix: in `AudioRecorder`, set an appropriate `AVAudioSession` category such as record/playAndRecord before starting `AVAudioRecorder`; default iOS audio sessions allow playback but not recording.

- Handle `insertAttachment` completion/error on the right UI path — `Build order / Insert inline`. Suggested fix: await the async API or use the completion handler, then update UI on the main actor instead of assuming insertion succeeded synchronously.

- Ensure the fetched/mock MP3 is a durable local file URL with a playable extension — `The mock seam`, `Build order / Insert inline`. Suggested fix: have both services return a temp/caches `.mp3` file URL, copying from the bundle for the mock and from downloaded bytes for live.

- Permission validation probably needs a real device pass in addition to simulator — `Build order / Expanded presentation + mic permission`. Suggested fix: keep simulator as the fast loop, but add one physical-device smoke test for the mic prompt and iMessage extension behavior.
