# Tribunal review — voiceMix iMessage extension

Run a one-shot adversarial tribunal on the CURRENT code. Read the real source first. Three roles, in order, then a ruling:

1. **Investigator** — read all the source and state plainly what the code does and the facts that bear on correctness/robustness. No spin.
2. **Devil's advocate** — make the strongest possible case that this implementation is fragile or wrong: where will it crash, hang, get killed, leak, misbehave, or violate iMessage-extension constraints? Be ruthless and specific (file:line).
3. **Judge** — weigh both sides and deliver a ruling: prioritized findings (Critical / High / Medium / Low), each with file:line, the concrete risk, and a recommended fix. End with a one-line verdict on production-readiness for the steel thread.

## Central question
Is the voiceMix iMessage extension implementation correct and robust enough to reliably do: pick voice → record → (mock) convert → wrap audio in an mp4 → insert an inline-playable bubble — on a real device, without crashing or being terminated by the system?

## Context (what we already know)
- It's an iMessage app extension (target `voiceMixerMessages`). The host app is just an onboarding screen.
- Known live issues this session: on a physical device the mic-permission prompt never appeared and tapping Record dismissed the extension — we JUST added an explicit `AVAudioApplication.requestRecordPermission` flow + `os_log` instrumentation (commit `3b4103c`). On the simulator, after recording, the extension was SIGKILL'd with `timed out during delayed presentation` (no Swift backtrace) — suspected encoder memory/watchdog pressure, amplified because `MockConvertService` now echoes the user's full real recording (not a 2s sample).
- The encoder (`WaveformVideoRenderer`) does a TWO-pass build: writes a video-only H.264 track holding a 600x600 static cover for the full duration via `AVAssetWriter`, then muxes with the audio via `AVMutableComposition` + `AVAssetExportSession` (medium quality). It also reads ALL PCM samples into a `[CGFloat]` before downsampling to 40 waveform bars.

## Files to read (all under the repo root)
- `MessagesExtension/MessagesViewController.swift`
- `MessagesExtension/AudioRecorder.swift`
- `MessagesExtension/WaveformVideoRenderer.swift`
- `MessagesExtension/ConvertService.swift`
- `MessagesExtension/MockConvertService.swift`
- `MessagesExtension/LiveConvertService.swift`
- `MessagesExtension/Config.swift`
- `MessagesExtension/Info.plist`
- `App/voiceMixerApp.swift`

## Focus areas (not exhaustive)
- iMessage-extension constraints: memory budget, presentation/watchdog timeouts, lifecycle (resign/teardown mid-async-work), `requestPresentationStyle` timing, audio session use inside an extension.
- Concurrency/threading: is heavy work truly off the main actor? UIKit drawing off-main? completion handlers hopped to main? cancellation when the extension is dismissed mid-`Task`?
- The encoder: memory (per-sample `[CGFloat]`), two-pass cost, the `while !input.isReadyForMoreMediaData { sleep }` loop (no timeout/cancel/status check), ignored `adaptor.append` return, missing `cancelWriting`/cleanup, duration mismatches, the iOS18 `export(to:as:)` path.
- The permission fix just added: is the new flow correct (state check, off-main callback hopped to main, denied handling, re-tap behavior)?
- The mock echo + `LiveConvertService` correctness; `Config` safety.
- Any force-unwraps, force-trys, or assumptions that can crash.

## Output
Write to `notes/codex-tribunal-output.md`. Sections: Investigator, Devil's Advocate, Judge (with the prioritized findings table: severity | file:line | risk | fix), then the one-line verdict. Be concrete; flag certain vs uncertain.
