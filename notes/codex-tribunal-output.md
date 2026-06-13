# Tribunal review - voiceMix iMessage extension

## Investigator

The Messages extension UI is implemented in `MessagesExtension/MessagesViewController.swift`. It has a fixed `voiceId` (`stock`), chooses `MockConvertService` because `Config.useMock` is hardcoded `true`, records through `AudioRecorder`, converts/fetches audio, renders an mp4 with `WaveformVideoRenderer`, then inserts that mp4 with `MSConversation.insertAttachment`.

The happy path is:

1. `recordTapped()` checks `recorder.isRecording` and either starts or stops (`MessagesExtension/MessagesViewController.swift:83`).
2. `beginRecording()` checks explicit microphone permission and uses `AVAudioApplication.requestRecordPermission` on iOS 17+ or `AVAudioSession.requestRecordPermission` on older OSes (`MessagesExtension/AudioRecorder.swift:64`, `MessagesExtension/AudioRecorder.swift:86`).
3. Once permission is granted, `startRecordingFlow()` requests `.expanded`, clears the previous ready clip, and starts `AVAudioRecorder` (`MessagesExtension/MessagesViewController.swift:121`, `MessagesExtension/AudioRecorder.swift:13`).
4. `stopAndConvert()` stops the recorder and launches an unstructured `Task` to run `prepareClip(from:)` (`MessagesExtension/MessagesViewController.swift:140`, `MessagesExtension/MessagesViewController.swift:152`).
5. `MockConvertService` sleeps 1.5 seconds, returns the recorded file URL as `audioUrl`, and `fetchAudio` copies that full recording to temp (`MessagesExtension/MockConvertService.swift:9`, `MessagesExtension/MockConvertService.swift:20`).
6. `WaveformVideoRenderer.makeVideo` loads duration, tries to build a waveform cover, writes a video-only mp4, then muxes it with the audio into a final mp4 (`MessagesExtension/WaveformVideoRenderer.swift:50`, `MessagesExtension/WaveformVideoRenderer.swift:287`, `MessagesExtension/WaveformVideoRenderer.swift:365`).
7. `sendTapped()` inserts the final mp4 into the active conversation (`MessagesExtension/MessagesViewController.swift:185`).

Facts bearing on robustness:

- The microphone usage string is present in the Messages extension plist (`MessagesExtension/Info.plist:23`).
- The explicit permission flow is mostly correct: it reads current state first, requests only when undetermined, and hops the completion to the main actor before updating UI (`MessagesExtension/MessagesViewController.swift:96`, `MessagesExtension/AudioRecorder.swift:87`).
- Recording uses AAC `.m4a`, mono, 44.1 kHz, high quality (`MessagesExtension/AudioRecorder.swift:22`).
- The audio session is activated before recording and deactivated after stopping (`MessagesExtension/AudioRecorder.swift:14`, `MessagesExtension/AudioRecorder.swift:46`).
- The renderer imports UIKit and uses `UIGraphicsImageRenderer`, `UIImage`, `UIFont`, `UIColor`, `UIBezierPath`, and SF Symbols to draw the cover (`MessagesExtension/WaveformVideoRenderer.swift:3`, `MessagesExtension/WaveformVideoRenderer.swift:93`).
- The renderer reads every decoded PCM sample into `[CGFloat]` before reducing to 40 bars (`MessagesExtension/WaveformVideoRenderer.swift:204`, `MessagesExtension/WaveformVideoRenderer.swift:212`, `MessagesExtension/WaveformVideoRenderer.swift:225`).
- The renderer writes a static H.264 video frame sequence for the whole audio duration, then reopens that video and muxes it with the audio in a second AVFoundation export pass (`MessagesExtension/WaveformVideoRenderer.swift:293`, `MessagesExtension/WaveformVideoRenderer.swift:296`).
- There is no explicit recording duration cap, no conversion/render timeout, no cancellation tracking, and no extension lifecycle cleanup for async conversion/rendering.
- The host app is only an onboarding SwiftUI screen and does not materially affect the Messages extension steel thread (`App/voiceMixerApp.swift:3`).

## Devil's Advocate

The implementation is fragile for a real iMessage extension because the heaviest operations happen inside a short-lived, memory-constrained extension process and are allowed to run without a deadline.

The strongest problem is the renderer. `readPCMAmplitudes` decodes the entire audio into a `[CGFloat]` (`MessagesExtension/WaveformVideoRenderer.swift:212`, `MessagesExtension/WaveformVideoRenderer.swift:225`). On 64-bit iOS, `CGFloat` is 8 bytes. A 60-second mono 44.1 kHz recording is roughly 2.65 million samples, so the amplitude array alone is about 21 MB before `Data` chunk buffers, decoded sample buffers, AVFoundation objects, image buffers, the writer, and the export session. A few minutes can push this into hundreds of MB. In an iMessage extension, that is a credible Jetsam/SIGKILL path. This is certain from the source, even if the exact memory threshold is device-dependent.

The render pipeline then does two full media passes. It writes a video-only track over the full duration (`MessagesExtension/WaveformVideoRenderer.swift:294`), then builds an `AVMutableComposition` and exports it again (`MessagesExtension/WaveformVideoRenderer.swift:397`). The observed simulator kill, "timed out during delayed presentation", fits this class of issue: the extension is busy rendering/exporting instead of finishing the presentation/update window quickly. This is not proven solely by source, but it is strongly consistent with the design and the known symptom.

The writer loop can hang indefinitely:

- It waits while `!input.isReadyForMoreMediaData` (`MessagesExtension/WaveformVideoRenderer.swift:341`).
- It does not check `Task.isCancelled`.
- It does not check `writer.status` or `writer.error` while waiting.
- It has no timeout.
- It ignores the boolean returned by `adaptor.append` (`MessagesExtension/WaveformVideoRenderer.swift:344`).

If the writer fails or backpressure never clears, the task can sit in a sleep loop until the extension is killed. The later `writer.status` check only runs after the loop exits, which is exactly the condition that may never happen.

The async work is unstructured and retained by the task. `stopAndConvert()` starts `Task { ... }` and captures `self` throughout the closure (`MessagesExtension/MessagesViewController.swift:152`). There is no property storing the task, no cancellation in `willResignActive`, `didResignActive`, `willTransition`, or deinit, and no cleanup of AVAssetWriter/export if the Messages extension is dismissed. An extension host can tear down or suspend the extension mid-operation; this code keeps work alive until the system terminates it. The insert completion uses `[weak self]`, but conversion/rendering does not.

The UI drawing is probably happening off the main actor. `prepareClip` runs in an unstructured task, then `WaveformVideoRenderer.makeVideo` calls `makeBestAvailableCover`, which calls `makeCoverImage`, which uses UIKit drawing APIs (`MessagesExtension/WaveformVideoRenderer.swift:55`, `MessagesExtension/WaveformVideoRenderer.swift:93`). UIKit drawing with `UIGraphicsImageRenderer` is commonly usable off-main in image contexts, but SF Symbol/image/font rendering and UIKit objects off the main thread in an extension are still a risk. At minimum the code does not document or isolate that assumption. If there is a main-thread-only violation or contention, it will be hard to diagnose.

The video duration math is sloppy. `staticFrameTimes` produces `Int(durationSeconds * fps)` frames (`MessagesExtension/WaveformVideoRenderer.swift:361`) at times `0..<frameCount` (`MessagesExtension/WaveformVideoRenderer.swift:362`). For a 1.0s clip at 6 fps, the last frame is at 5/6s, then `writer.endSession(atSourceTime: duration)` forces the session to 1.0s. This may work, but it relies on writer/session behavior rather than appending a final sample at or beyond the duration. For fractional durations, truncation can undershoot. Muxing then inserts the requested `duration` from the generated video track (`MessagesExtension/WaveformVideoRenderer.swift:386`, `MessagesExtension/WaveformVideoRenderer.swift:390`), so if the video track is shorter than requested, `insertTimeRange` can throw.

The code does not limit how long a user can record. Because the mock now echoes the full recording (`MessagesExtension/MockConvertService.swift:15`), every extra second increases waveform decode work, static frame count, export time, temp disk usage, and memory pressure. The steel thread has no guardrail like 10 or 15 seconds.

The live networking path is not production-safe. It reads the entire upload file into `Data` (`MessagesExtension/LiveConvertService.swift:23`), builds another multipart `Data` containing the whole audio (`MessagesExtension/LiveConvertService.swift:58`, `MessagesExtension/LiveConvertService.swift:74`), downloads the whole converted file into memory (`MessagesExtension/LiveConvertService.swift:39`), and force-unwraps UTF-8 conversion in the multipart helper (`MessagesExtension/LiveConvertService.swift:62`). The force unwrap is probably safe for literal ASCII strings, but the buffering pattern is not safe for extension memory.

The permission fix is an improvement, but one race remains: after permission is granted, `startRecordingFlow()` calls `requestPresentationStyle(.expanded)` and immediately starts recording (`MessagesExtension/MessagesViewController.swift:123`, `MessagesExtension/MessagesViewController.swift:130`). If the host presentation transition dismisses/recreates the extension or the audio session activation interacts badly with the presentation transition, there is no state machine to recover. That is a plausible contributor to "tapping Record dismissed the extension", although not certain from source.

## Judge

| severity | file:line | risk | fix |
|---|---:|---|---|
| Critical | `MessagesExtension/WaveformVideoRenderer.swift:204` | Certain unbounded memory growth: the renderer stores every PCM amplitude in `[CGFloat]`, which can exceed extension memory limits for normal-length recordings and plausibly cause Jetsam/SIGKILL. | Stream the waveform into 40 buckets directly while reading sample buffers; do not retain per-sample amplitudes. Also cap recording duration. |
| Critical | `MessagesExtension/MessagesViewController.swift:152` | Certain missing lifecycle/cancellation control: conversion/rendering runs in an unstructured task that is not cancelled when the iMessage extension is dismissed, compacted, or torn down. This can continue heavy AVFoundation work until the system kills the extension. | Store `conversionTask: Task<Void, Never>?`; cancel it in extension lifecycle callbacks and before starting a new conversion; pass cancellation through renderer and service work; clear UI state on cancellation. |
| High | `MessagesExtension/WaveformVideoRenderer.swift:341` | Certain hang risk: the writer backpressure loop has no timeout, cancellation check, or writer status/error check. If the writer fails or never becomes ready, the task can sleep forever. | Replace the polling loop with `requestMediaDataWhenReady` or add bounded waits that check `Task.checkCancellation()`, `writer.status`, and `writer.error`; call `writer.cancelWriting()` on failure/cancellation. |
| High | `MessagesExtension/WaveformVideoRenderer.swift:344` | Certain silent failure risk: `adaptor.append` returns `Bool`, but the result is ignored. Failed appends can produce a corrupt/short video and only surface later as export failure or insertion failure. | Guard every append; on failure, inspect `writer.error`, cancel writing, and throw a concrete render error. |
| High | `MessagesExtension/WaveformVideoRenderer.swift:293` | Strongly likely watchdog risk: the renderer does two AVFoundation passes inside the Messages extension, first writing static video for the full audio duration and then exporting/muxing. This fits the observed delayed-presentation SIGKILL. | Avoid generating a long synthetic video. Prefer a simpler inline-playable attachment strategy if possible; otherwise render only a very short/constant video track while preserving audio, use lower presets, and impose strict duration/time limits. |
| High | `MessagesExtension/MessagesViewController.swift:121` | Plausible presentation race: the extension requests `.expanded` and immediately activates recording. If expansion triggers host lifecycle changes, recording setup has no recovery state. | Request expansion earlier or wait for presentation transition/lifecycle confirmation before activating the audio session; make start idempotent and resilient to interruption. |
| Medium | `MessagesExtension/AudioRecorder.swift:13` | No recording duration cap. Long recordings multiply memory, export time, disk usage, and extension termination risk. | Add a hard maximum duration with timer-driven stop, e.g. 10-15 seconds for the steel thread, and communicate the limit in UI. |
| Medium | `MessagesExtension/WaveformVideoRenderer.swift:358` | Duration mismatch risk: generated frame times truncate duration and rely on `endSession(atSourceTime:)` to stretch the track. `insertTimeRange` can fail if the video track is shorter than requested. | Generate frame timing from `ceil(duration * fps)` and append/cover at least through the requested duration, or derive the mux range from loaded track durations after writing. |
| Medium | `MessagesExtension/WaveformVideoRenderer.swift:93` | Uncertain UIKit off-main risk: cover creation uses UIKit drawing APIs from the conversion task. It may work, but the threading contract is not explicit and failures would be hard to isolate. | Either mark cover drawing `@MainActor` and keep it tiny, or switch to CoreGraphics/CoreText-only rendering in a detached renderer. |
| Medium | `MessagesExtension/LiveConvertService.swift:23` | Certain live-path memory duplication: upload reads the full audio into memory, then multipart construction copies it into another `Data`; download also buffers the full response. This is risky in an extension once live conversion is enabled. | Use file-backed upload streams or `uploadTask` from a file/body stream, enforce server/file size limits, and download to a file URL rather than memory. |
| Low | `MessagesExtension/LiveConvertService.swift:62` | Force unwrap is present. It is low risk because the strings are expected to be UTF-8, but it is unnecessary in production code. | Replace with safe append helper that throws or preconditions with a clear invariant. |
| Low | `MessagesExtension/MockConvertService.swift:25` | Temp/caches files accumulate: recordings, copied mock audio, and final mp4s are uniquely named and not cleaned after insertion except the intermediate video-only file. | Track generated files and delete old temp files after insertion/failure or at next launch. |
| Low | `App/voiceMixerApp.swift:31` | Host onboarding says "Pick a voice", but the extension hardcodes `stock` and has no picker. This is a product mismatch, not a crash risk. | Align onboarding copy with the steel-thread behavior or implement the picker before broader testing. |

The explicit microphone permission change is directionally correct and likely fixes the missing prompt class of bug, assuming the Messages extension bundle's `NSMicrophoneUsageDescription` is the one used at runtime. The denied and re-tap behavior is acceptable for the steel thread: denied state is checked without re-prompting and the UI tells the user to enable Settings access.

The implementation is not production-ready for the steel thread on a real device: the record/permission path is close, but the unbounded renderer, missing cancellation, and two-pass AVFoundation export make system termination likely under ordinary use.
