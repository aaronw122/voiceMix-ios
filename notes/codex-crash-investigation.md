# Investigate: iMessage extension terminated after record → Convert

You are debugging a real iOS iMessage app extension. Read the actual source in this repo before concluding. Be concrete and code-specific. Rank hypotheses AND, for each, give a concrete way to CHECK/verify it.

## Files to read
- `MessagesExtension/MessagesViewController.swift` — the `MSMessagesAppViewController`. Flow lives here.
- `MessagesExtension/WaveformVideoRenderer.swift` — wraps audio into an `.mp4` (AVAssetWriter video-only track holding a 600x600 cover for the duration, then AVMutableComposition + AVAssetExportSession to mux+re-encode).
- `MessagesExtension/AudioRecorder.swift` — AVAudioRecorder → `.m4a`, sets `.playAndRecord` + activates AVAudioSession.
- `MessagesExtension/MockConvertService.swift` — now echoes the user's REAL recording back (returns the recorded file URL through convert/fetchAudio) instead of a bundled 2s sample.
- `MessagesExtension/ConvertService.swift`, `Config.swift`, `MessagesExtension/Info.plist`.

## The symptom
On record → tap Convert, the extension dies. Console (NOT a debugger backtrace) repeatedly shows:
- `Remote app card controller …com.aaron.voiceMixer.Messages timed out during delayed presentation`
- `Connection to plugin interrupted while in use` / `…invalidated while in use`
- runningboardd: process exited `signal(2) code:SIGKILL(9)`
- one `(Fig) signalled err=-12900` (CoreMedia)
There is NO Swift crash backtrace and NO `.ips` crash report generated.

## What we've already established / ruled out
- `NSMicrophoneUsageDescription` IS present in the extension Info.plist (not a privacy hard-crash).
- The heavy work appears to run OFF the main actor: `MessagesViewController` is `@MainActor`; `stopAndConvert` does `Task { try await prepareClip(...) }`; `convert`/`fetchAudio`/`makeVideo` are `nonisolated async` (struct methods), so their bodies run on the cooperative pool. CONFIRM whether this reasoning is actually correct, or whether something still pins heavy work (UIGraphicsImageRenderer, CGContext, AVAssetWriter setup) to the main thread.
- It is a REGRESSION: with the previous mock returning a tiny 2s bundled `sample.mp3`, it worked; after switching the mock to echo the user's full (longer) recording, it dies. So heavier/longer audio → heavier mp4 encode correlates with the failure.
- The iOS Simulator's Messages is in a degraded state (lots of `Couldn't communicate with a helper application`, `failed to create XPC connection`, `iCloud account is in a bad state`). User is also testing on a real device to isolate environment vs code.

## What I want from you
1. **Rank the plausible root causes** for `SIGKILL` + `timed out during delayed presentation` + no backtrace, specifically for an iMessage extension doing audio→mp4 encoding. Cover at least: extension memory/jetsam limit (what IS the iMessage extension memory budget on modern iOS? cite if known), a watchdog/presentation timeout from blocking, an AVFoundation export hang/error (the -12900), AVAudioSession activation in an extension, `requestPresentationStyle(.expanded)` timing, and the simulator-host-degradation possibility.
2. **For EACH hypothesis, give a concrete CHECK** the developer can run: e.g. Xcode Debug-navigator memory gauge threshold, Instruments (Allocations/Time Profiler/Activity Monitor), `os_signpost`/`os_log` markers to bracket the encode, a `MEMORYSTATUS`/jetsam log predicate, testing the 2s sample vs real recording, temporarily stubbing `makeVideo` to return the raw audio (skip encoding) to see if the kill disappears, capping recording length, running on device vs sim, attaching to the *extension* process not the host, etc.
3. **Review the code for concrete bugs** that could cause a hang or timeout: the `while !input.isReadyForMoreMediaData { try await Task.sleep(...) }` loop, the iOS18 `export.export(to:as:)` path vs the legacy path, appending the same CVPixelBuffer many times, the `[CGFloat]` per-sample buffer in `readPCMAmplitudes` (memory for long recordings), pixel format mismatches, missing `writer.cancelWriting`/cleanup, etc.
4. **Recommend the smallest, safest changes** to make the encode fast + low-memory enough to survive (single-pass vs two-pass, frame size, streamed waveform, capping duration), and whether to decouple encoding from the extension's presentation lifecycle.

## Output
Write to `notes/codex-crash-investigation.md` → wait, write to `notes/codex-crash-output.md` (do NOT overwrite this prompt). Structure: ranked hypotheses table (cause | why it fits | how to check), then a "code bugs found" list with file:line, then "recommended minimal fix". Flag certain vs uncertain claims.
