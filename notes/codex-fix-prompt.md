# Fix Critical + High issues in the voiceMix iMessage extension

Implement the fixes below in the existing repo. Branch is `imessage-steel-thread` — commit there, do NOT push, do NOT touch `main`, do NOT create PRs. Read the files before editing. Keep the existing `os_log` Logger markers and add new ones where noted.

These fixes come from a code tribunal. The extension is being SIGKILL'd by the system (jetsam/watchdog) during the record→convert→mp4 flow. Goal: make the encode bounded, cancellable, fail-fast, and low-memory so the iMessage extension survives.

## Files
- `MessagesExtension/WaveformVideoRenderer.swift` (the encoder — most changes here)
- `MessagesExtension/MessagesViewController.swift` (task lifecycle + presentation)
- `MessagesExtension/AudioRecorder.swift` (duration cap)

## Hard constraints
- Do NOT change `ConvertService.swift`, `MockConvertService.swift`, `Config.swift`, or `project.pbxproj` (no new files). Put new code in the existing files.
- Keep behavior: still produce an inline-playable `.mp4` (static cover + audio) and insert it as `voiceMix.mp4`. Keep the mock/live seam intact.
- Keep/extend the `os_log` Loggers (subsystem `com.aaron.voiceMixer`, categories `flow` and `render`). Log entry/exit/errors of the new code paths.
- Follow existing code style.

## CRITICAL fixes

### C1 — Stream the waveform into 40 buckets (no per-sample array)
In `WaveformVideoRenderer.readPCMAmplitudes`, do NOT accumulate one `CGFloat` per sample into a giant `[CGFloat]`. Instead compute the 40 normalized bars while reading: maintain running sum + count per bucket (or running max per bucket), assigning samples to buckets by overall sample index. You will need a first pass to know total sample count OR estimate buckets from the track's duration*sampleRate; simpler robust approach: accumulate into 40 buckets using a fixed total-sample estimate from `CMTimeGetSeconds(duration) * sampleRate`, mapping each running sample index → bucket = min(39, index * 40 / estimatedTotal). Track per-bucket sum+count, then average and normalize at the end. Wrap each sample-buffer iteration in `autoreleasepool`. Never hold all samples. The output stays `[CGFloat]` of length ≤40 so the rest of the code is unchanged.

### C2 — Cancellable conversion task tied to the extension lifecycle
In `MessagesViewController`:
- Add `private var conversionTask: Task<Void, Never>?`.
- In `stopAndConvert`, cancel any existing `conversionTask` before starting, and assign the new `Task { ... }` to it. Inside the task, after each `await`, check `Task.isCancelled` (or call `try Task.checkCancellation()` in `prepareClip`) and bail cleanly (reset UI via the existing loading/error path) if cancelled.
- Cancel `conversionTask` (and set it nil) in the MSMessagesAppViewController lifecycle hooks that fire when the extension is dismissed/backgrounded: override `didResignActive(with:)` and `willTransition(to:)` (cancel when transitioning to `.compact`), and in `deinit`. Use `[weak self]` in the task closure where you capture self for UI updates.
- Thread cancellation into `WaveformVideoRenderer.makeVideo` (and its writer loop, see H3) via `Task.checkCancellation()` at sensible points so a cancelled task stops AVFoundation work promptly.

## HIGH fixes

### H3 — Writer loop must fail-fast (no infinite hang)
In `WaveformVideoRenderer.writeVideoTrack`, the `while !input.isReadyForMoreMediaData { try await Task.sleep(...) }` loop must: check `try Task.checkCancellation()`, check `writer.status == .failed` (throw with `writer.error` if so), and enforce an overall timeout (e.g. a deadline ~10s of waiting) after which it throws and calls `writer.cancelWriting()`. Prefer rewriting to `requestMediaDataWhenReady(on:)` with a serial queue + continuation if you’re confident; otherwise keep the polling loop but add the cancellation/status/timeout guards.

### H4 — Honor `adaptor.append` return
`adaptor.append(buffer, withPresentationTime:)` returns `Bool`. Guard it: on `false`, log + inspect `writer.error`, call `writer.cancelWriting()`, and throw a concrete `RenderError`. Don’t silently continue.

### H5 — Collapse the two-pass encode into a single pass
Replace the current "write a video-only mp4, then AVMutableComposition + AVAssetExportSession to mux" with a SINGLE `AVAssetWriter` that writes both:
- one **video** `AVAssetWriterInput` fed the static cover via the pixel-buffer adaptor (as today, with H3/H4 guards), and
- one **audio** `AVAssetWriterInput` fed sample buffers read from the source audio with an `AVAssetReader` + `AVAssetReaderTrackOutput` (output settings nil/passthrough or AAC), appended until the audio reader is exhausted.
Finish writing once and you have the final `.mp4` — no `AVAssetExportSession`, no intermediate video-only file. This removes the second media pipeline (the watchdog risk) and the redundant re-encode. Make sure both inputs are added before `startWriting`, use `startSession(atSourceTime: .zero)`, mark both finished, and `finishWriting`. On any failure or cancellation: `cancelWriting()` and delete the partial output file. If a single-pass rewrite proves genuinely infeasible, you MAY keep two-pass but you MUST then bound it with a hard duration cap + timeout + cancellation + cleanup — and clearly say so in your report.

### H6 — Presentation race
In `MessagesViewController`, stop requesting `.expanded` at the same instant recording starts. Request `.expanded` earlier (e.g. once in `viewWillAppear`/`willBecomeActive`, or at the very start of `recordTapped` before the permission request), so the audio-session activation isn’t racing the presentation transition. Make `startRecordingFlow` resilient to being called when already expanded. Keep it simple and correct.

## Safety net (include it): recording duration cap
In `AudioRecorder`, add a hard max duration (15 seconds): schedule a timer on `startRecording` that calls `stop()` and notifies the controller (delegate/closure) so the UI flips to "stop/convert" automatically. This bounds memory/encode/temp usage and directly de-risks C1/H5. Surface a short note in the status label (e.g. "Recording… (15s max)").

## Verify
Run the build and fix until it passes:
`xcodebuild build -project voiceMixer.xcodeproj -scheme voiceMixerMessages -sdk iphonesimulator -destination 'id=D0A72092-9179-4C06-B7C6-BB7F12165302' CODE_SIGNING_ALLOWED=NO`
If your sandbox blocks xcodebuild/CoreSimulator (e.g. "Operation not permitted" / SCDynamicStore), say so explicitly in your report — the work will be build-verified after you finish. Either way, write code that compiles.

## Commit
One commit: `fix: bound and cancel mp4 encode to prevent iMessage extension termination`. Do NOT push.

## Report (concise)
- Per item C1, C2, H3, H4, H5, H6 + duration cap: done / partial (why).
- Whether you did true single-pass (H5) or kept bounded two-pass (and why).
- xcodebuild result (or that the sandbox blocked it).
- Files changed, commit hash, `git show --stat HEAD`.
