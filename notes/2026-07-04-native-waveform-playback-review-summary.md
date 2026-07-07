# Plan Review Summary

**Plan:** notes/native-waveform-playback-plan.md
**Rounds:** 3
**Final revision:** 3

---

## Issues Found & Fixed

### Round 1 — 3 Must-fixes raised; 1 upheld, 2 downgraded

**MF3 (upheld) — Rainbow↔accent flip on the review screen on every play/pause.**
The plan recolored only `.playing` to a brand accent while leaving `.ready` rainbow.
`reviewPage` uses `isPlaying ? .playing : .ready` (VoiceTransformView.swift:925), so hitting
play produced a visible in-place palette swap every cycle — directly violating the spec DON'T
("drop rainbow") and ENSURE ("preview matches sent bubble"). Verdict: real spec defect; fix
required before coding.

**MF1 (downgraded to Low/impl-note) — Data-flow / single PCM read under-specified.**
The declared `drawCover(into:size:bars:progress:palette:)` signature already dictates that
`bars` is sampled upstream and threaded down; the branch predicate (`bars.isEmpty` → static
fallback) matches the existing predicate in `makeBestAvailableCover`. Verdict: plan-granularity
nit, not a design defect. Folded in as an impl-note.

**MF2 (downgraded to Low/hygiene-note) — Y-flip trap in raw CVPixelBuffer CGContext.**
Drawing directly into a bottom-left/Y-up context vs. the preview's top-left Canvas is a
visual no-op for this feature: bars are Y-symmetric, the playhead is a full-height vertical
rule (flip-invariant), and the background gradient is near-black with a ~10/255 stop delta.
Verdict: correct output ships; flip the CTM only as future-proofing. Folded in as an impl-note
(note: the CTM flip also inverts the gradient in the flipped space — draw gradient after
flipping so top→bottom stays correct).

**Md1–Md7 — Various Medium clarifications folded into revision 2:**
- Stale pooled buffers ghost: full opaque background repaint required every frame (§5).
- Muted bars over translucent vs. opaque background: switch to opaque pre-composited RGBA.
- `isPlayed` / `playheadX` must be computed only inside `WaveformLayout.frame(...)` — remove
  the preview's inline `t <= progress` check.
- Progress never reaches 1.0 (last PTS is `(frameCount-1)/fps < duration`): fix deferred to R2.
- Preview progress clock vs. baked clock parity: add explicit "audio dur == muxed video dur"
  assertion and playhead-reaches-far-edge criterion to Phase 4.
- "Native enough" validation must be done on a real outgoing (blue) sender bubble, not the
  light-gray Canvas preview.

---

### Round 2 — 3 Must-fixes raised; all resolved in revision 3

**MF1 (r2) — Terminal-frame fix wording had two broken branches.**
Plan offered (a) append a frame at PTS == `durationSeconds` — risky because `endSession`
trims or rounds it; and (b) plain `min(1, presentationSeconds/duration)` clamp — a no-op
because the last emitted frame is always `< duration`, so the ratio never hits 1. The correct
mechanism: do NOT append an extra frame; force the progress of the LAST emitted frame
(highest index in `staticFrameTimes`) to exactly 1.0; interior frames use
`presentationSeconds / duration`. The held terminal frame then sits at the far edge from its
PTS through `endSession(atSourceTime: duration)` without touching the session boundary.

**MF2 (r2) — Aspect/inset contradiction.**
The plan pinned the preview to 600:140 but left the renderer's `hInset 36 / vInset 30` as
an open decision. Those choices are coupled: the renderer currently draws bars into a 528×80
(6.6:1) rect while the pinned preview uses 4.29:1; `WaveformLayout` derives all metrics from
the size it is given, so different aspect ratios yield visibly different bar proportions —
breaking the ENSURE "preview matches sent bubble." Resolution chosen in revision 3: drop the
`hInset/vInset`; both backends pass the full 600×140 (4.29:1) rect to `WaveformLayout`.

**MF3 (r2) — `.ready` is mounted on BOTH `recordPage` (:821) and `reviewPage` (:925).**
Recoloring `.ready` to muted brand accent fixed the review-screen rainbow↔accent flip only
to re-introduce it on the record page: idle (muted-accent) → recording (rainbow) in-place
recolor on first tap — the exact class of issue that triggered R1's MF3.

**Mid-review color-model correction by the user (between R2 and R3):**
The user dropped the brand-accent palette entirely. The model reverts to one palette
(rainbow) with a dim/faded rest treatment for unplayed bars and `.ready`. This dissolves
MF3 (r2) at the root — every state transition is now a brightness/saturation change of the
same per-bar hue, not a hue swap — and makes the R2 Medium about rainbow violating the spec
DON'T moot (spec was simultaneously reversed to "keep the rainbow for played bars, don't
introduce a new accent"). Revision 3 was written against this updated color model.

---

### Round 3 — 0 Critical / 0 Must-fix

All R2 findings confirmed resolved. The terminal-frame mechanism (MF1), the explicit
inset drop + 600:140 pin on both backends (MF2), and the single-palette resolution of
MF3 are each verified in the plan text. The color pivot to rainbow-played / faded-unplayed
is cosmetic to the encode path and reinforces the opaque-buffer requirement. No new
structural problems introduced.

---

## Remaining Issues

**None blocking.**

**Low — Rainbow HSB→RGB must be centralized inside `WaveformLayout` (r3, agent2).**
The rev-3 decision keeps rainbow for played bars. Parity holds only if the HSB→RGB
conversion happens once inside the shared layer and both backends consume the resulting
`rgba` components. If an implementer instead has each backend call `UIColor(hue:)` or
SwiftUI `Color(hue:)` independently, the two HSB→RGB paths can land in different color
spaces and the played rainbow drifts between preview and bubble. Plan §2 implies the
correct path; worth one explicit sentence: *`rainbowColor` is computed to rgba inside
`WaveformLayout`; neither backend calls `UIColor(hue:)` / `Color(hue:)` for bar fills.*

**Impl-note (not blocking) — Aspect pinning says "the preview" singular but there are two
mounts (r3, agent3).** `recordPage` (:824) and `reviewPage` (:928) both use
`.frame(height: 92)` + 24pt padding; only the review mount strictly needs 600:140 parity
with the sent bubble. Decide explicitly whether the record mount follows suit or is allowed
to differ (both are acceptable; just pick one before Phase 3).

---

## Implementation Notes

The highest-value gotchas to watch when coding — pulled across all three rounds:

1. **UIBezierPath / UIColor.setFill silently no-op in a raw pooled CGContext.**
   The current `drawWaveform` uses `UIBezierPath.fill()` and `UIColor.setFill()`, which
   draw into the current UIGraphics context. In the per-frame path you draw directly into
   the pooled buffer's raw `CGContext` with no UIGraphics stack, so those calls silently
   produce blank frames. Use CG-native: `CGPath(roundedRect:cornerWidth:cornerHeight:transform:)`
   + `setFillColor` / `fillPath`. Alternative: wrap in `UIGraphicsPushContext` /
   `UIGraphicsPopContext`, but CG-native is preferred for the pooled-buffer path.

2. **Frame-cap fps recompute must re-span PTS to [0, duration].**
   When `durationSeconds * fps > maxFrames`, lowering effective fps must re-derive PTS:
   `effectiveFps = frameCount / durationSeconds`, `PTS = i / effectiveFps`. If frameCount
   is capped while the timescale stays 12, the last PTS is `(maxFrames-1)/12 < duration`
   and audio outlasts video (frozen tail + A-V drift). This composes cleanly with the
   terminal-frame rule: whatever the effective fps, the highest-index frame still gets
   `progress = 1.0`.

3. **Pooled-buffer CGContext must match 32ARGB / noneSkipFirst / DeviceRGB.**
   `bitsPerComponent: 8`, `bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)`,
   `CGImageAlphaInfo.noneSkipFirst`, `CGColorSpaceCreateDeviceRGB()` — the same recipe
   as the existing `pixelBuffer(from:)`. Lock/unlock base address around the draw, inside
   the per-frame `autoreleasepool`. `CVPixelBufferPoolCreatePixelBuffer` status check →
   fall back to `CVPixelBufferCreate` on nil pool.

4. **`.ready` must force `progress = 0` internally; do not consume the passed progress arg.**
   At natural playback finish, `audioPlayerDidFinishPlaying` sets `playProgress = 1` AND
   `isPlaying = false`, so `reviewPage` mounts `mode: .ready` with `progress:
   model.playProgress == 1`. If the refactor naively routes `.ready` through
   `WaveformLayout.frame(bars, progress: passedProgress, ...)`, it would light all bars
   and place the playhead at the far edge — a visible pop back from finish. The plan's
   "render `.ready` as `.playing` at `progress == 0`" must be literal: pass 0, ignore the
   incoming value. (Pause path is safe — `stopPlayback(resetProgress: true)` already zeroes
   `playProgress`.)

5. **The two existing faded treatments must collapse to one shared value.**
   Current `.ready` = dimmed rainbow (`rainbowColor(t, lightness:0.52, saturation:0.70,
   alpha:0.50)`, line 1113-1115). Current `.playing`-unplayed = hueless
   `.white.opacity(0.16)` (line 1117-1119). The single faded RGBA from `WaveformLayout`
   must replace both. The chosen value also becomes the record-page idle appearance;
   confirm it at the visual sign-off.

6. **AAC priming/padding means audio/video duration parity needs sub-frame tolerance.**
   The AAC encoder (`makeAudioInput`) adds priming and padding, so the muxed output's
   audio-track duration can differ from the source by a few ms. Compare the output file's
   track durations (not source == source) and accept a sub-frame tolerance in the Phase 4
   parity assertion.

7. **Post-playback: sent bubble may hold the all-lit terminal frame while preview resets
   to faded — validate on device.**
   The sent mp4's terminal frame is forced to `progress = 1.0` (all bars lit). If iMessage
   holds the last video frame after inline playback, the bubble shows all-lit at rest after
   a play while the preview resets to all-faded. Conversely, the bubble's initial poster
   (frame 0, `progress = 0`, all faded) should match the preview's rest state. Confirm both
   the initial-poster and post-play held frame during the on-device Phase 4 check.

---

## Reviewer Personas Used

All three personas participated in all three rounds:

1. **iOS Media Pipeline Architect** — AVFoundation encode correctness, pixel-buffer pool
   usage and memory budget, per-frame `autoreleasepool`, cancellation / `waitForInputReady`
   timeout / `cancelWriting` / temp-cleanup safeguards, concurrent video+audio deadlock fix.

2. **Graphics & Rendering Specialist** — Pixel-accurate parity between the Core Graphics
   mp4 renderer and the SwiftUI Canvas preview, shared `WaveformLayout` geometry and color
   model, coordinate convention (Y-origin), color-space parity (HSB→RGB centralization),
   single-source `isPlayed` / `playheadX`, aspect/inset coupling.

3. **Product & Integration Reviewer** — Sent-bubble UX and native-fidelity judgment,
   preview↔sent consistency, in-place color-flip analysis across all waveform modes and
   pages, ENSURE→validation testability, color-model coherence across the full
   record→transform→review journey.
