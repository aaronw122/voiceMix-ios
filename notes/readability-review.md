## Readability Review
- **Date:** 2026-06-07 16:49:53 EDT
- **Scope:** VoiceMixCore package + MessagesViewController (10 files)
- **Files reviewed:** 10
---

### Summary
The small service and catalog-support files are mostly readable; `AudioRecorder.swift`, `ConvertService.swift`, `MockConvertService.swift`, `VoiceCatalogPreflight.swift`, and `MessagesViewController.swift` have no review-level findings. The highest-impact cleanup is in `VoiceTransformView.swift` and `WaveformVideoRenderer.swift`, where long functions mix orchestration, state transitions, rendering details, and error handling.

### Findings by File

#### `VoiceMixCore/Sources/VoiceMixCore/Config.swift`
| # | Principle | Issue (cite line) | Proposed Change |
|---|-----------|-------------------|-----------------|
| 1 | Signal-to-noise | Thread-specific process notes dominate the simple `baseURL` constant at L4-L10 and L17-L25. | Remove stale process commentary and keep the constant focused on the fallback behavior. |

#### `VoiceMixCore/Sources/VoiceMixCore/LiveConvertService.swift`
| # | Principle | Issue (cite line) | Proposed Change |
|---|-----------|-------------------|-----------------|
| 1 | Consistent abstraction level | `convert(audioURL:voiceId:engine:)` selects an endpoint, builds a request, checks file size, builds multipart data, uploads, validates HTTP, logs, and decodes in one method at L25-L70. | Extract private helpers for endpoint selection, upload-size validation, request/body creation, and response validation so `convert` reads as the upload flow. |
| 2 | Chunking | `multipartBody` manually appends both fields inline at L103-L123, with comments separating logical sections. | Extract private `appendVoiceIdField` and `appendAudioFileField` helpers or local closures so the multipart structure is named instead of comment-delimited. |

#### `VoiceMixCore/Sources/VoiceMixCore/VoiceCatalog.swift`
| # | Principle | Issue (cite line) | Proposed Change |
|---|-----------|-------------------|-----------------|
| 1 | Predictable patterns | Each catalog entry repeats the same `Color(hex:)` and `UIColor(hex:)` pair from the same two hex values at L38-L97. | Add a private catalog-entry factory or private color-pair helper inside the file so each persona lists the two hex values once while preserving existing properties. |
| 2 | Signal-to-noise | The comment at L34-L36 says only three ElevenLabs voices are present, but the array immediately includes modal voices at L48-L77. | Remove or correct the stale comment so readers do not have to reconcile it with the data below. |

#### `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift`
| # | Principle | Issue (cite line) | Proposed Change |
|---|-----------|-------------------|-----------------|
| 1 | Chunking | `goBack()` mixes playback cleanup, retry cleanup, recording teardown, and step routing at L89-L110. | Extract private helpers such as `leaveRecordStep()` and `returnToRecordStep()` so the switch reads as navigation intent. |
| 2 | Consistent abstraction level | `send()` handles validation, playback state, sending state, the Messages callback, failure UI, success UI, reset, and dismiss at L158-L184. | Extract a private `handleInsertCompletion(_:)` and success/failure helpers to separate command setup from completion handling. |
| 3 | Consistent abstraction level | `startConversion(from:)` combines state setup, task lifecycle, async conversion, cancellation handling, success state, and failure mapping at L233-L263. | Keep `startConversion` as orchestration and move task body branches into named helpers such as `finishConversion(with:)`, `handleConversionCancellation()`, and the existing failure handler. |
| 4 | Naming as narrative | `prepareClip(from:)` mutates `waveformBars` while its name suggests it only returns a `PreparedClip`, at L302-L319. | Rename or split the waveform update into a named step, for example `updatePreviewWaveform(from:)`, so the side effect is visible at the call site. |
| 5 | Predictable patterns | Timer setup repeats the same invalidate/schedule/MainActor closure shape across recording, status, and playback timers at L328-L382. | Introduce a small private timer helper or narrowly extract each timer's callback body so the repeated scheduling pattern is easier to scan. |
| 6 | Chunking | `recordControl` contains three UI states inline, including two similar circular button implementations at L706-L739. | Extract `transformingControl`, `stopRecordingButton`, and `startRecordingButton` view builders to make the state branches read as named controls. |
| 7 | Predictable patterns | The Redo and Preview controls repeat a circular button plus label structure at L761-L803. | Extract a private `reviewAction` view builder that takes label, icon, size, and action parameters while preserving the current layout. |
| 8 | Consistent abstraction level | `NeonWaveformView.draw` computes source data, mode-specific animation, colors, geometry, path creation, and drawing in one loop at L881-L923. | Extract mode styling and bar-rect/path drawing helpers so the loop reads as "resolve style, resolve geometry, draw bar." |

#### `VoiceMixCore/Sources/VoiceMixCore/WaveformVideoRenderer.swift`
| # | Principle | Issue (cite line) | Proposed Change |
|---|-----------|-------------------|-----------------|
| 1 | Signal-to-noise | `makeCoverImage(duration:personaName:centerDraw:)` accepts `duration` and `personaName` but no longer uses them, and the comment explains that historical compatibility at L104-L110. | Remove the unused parameters and update same-file call sites, unless tests require the labels; otherwise mark them intentionally unused with `_` and shorten the stale explanation. |
| 2 | Chunking | `readPCMAmplitudes` handles reader setup, sample-buffer copying, bucket accumulation, reader-status validation, averaging, and normalization at L194-L240. | Extract reader setup and sample-buffer accumulation into private helpers so the method reads as "stream samples, average buckets, normalize." |
| 3 | Guard clauses over nesting | `estimatedSampleCount` nests optional format-description checks at L255-L261. | Extract `sampleRate(from:)` or use guard clauses to flatten the default-rate fallback. |
| 4 | Consistent abstraction level | `writeMovie` sets up writer inputs, reader outputs, startup, pixel-buffer creation, concurrent track writing, cancellation, finalization, and status validation at L314-L387. | Extract setup and finalization helpers so the method shows the muxing sequence without low-level AVFoundation setup details. |
| 5 | Naming as narrative | The loop variables `i` and `t` in `drawWaveform` at L280-L283 require nearby context to decode. | Rename to `barIndex` and `position` or `normalizedPosition` to make the waveform math self-describing. |

### Systemic Patterns
The main repeated pattern is functions that start with readable orchestration but then drop into low-level mechanics in the same body, especially in conversion, playback, rendering, and waveform drawing paths. A second pattern is comments preserving historical context after the code has moved on; those comments now add cognitive load rather than reducing it.

### Suggested Fix Order
1. Refactor `VoiceTransformViewModel` methods in `VoiceTransformView.swift` first, starting with `startConversion(from:)`, `send()`, and `prepareClip(from:)`, because they drive the main user flow.
2. Refactor `WaveformVideoRenderer.writeMovie` and `readPCMAmplitudes`, because they are the densest implementation blocks and will benefit most from named stages.
3. Extract repeated SwiftUI control builders in `VoiceTransformView.swift` after the model cleanup, keeping UI changes isolated and behavior-preserving.
4. Simplify `LiveConvertService.convert` and `multipartBody` so the network path follows the same named-step style as the cleaned rendering path.
5. Clean the small catalog/config readability issues last: remove stale comments and reduce duplicated color construction in `VoiceCatalog.swift`.
