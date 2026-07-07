# Implementation Plan — Native-Style Animated Waveform Playback

> Revision: 3 (color model corrected: rainbow kept, faded unplayed; + round-2 fixes MF1/MF2)
>
> Status: Phases 1–3 implemented on `feat/native-waveform-playback` and building
> (VoiceMixCore + app + Messages extension compile). Phase 4 (on-device
> validation on a physical iPhone) is pending — the only step agents can't do.

Spec: `notes/native-waveform-playback.md`
Branch: `feat/native-waveform-playback`

## Goal restated
Bake a synchronized playback-progress animation into the generated `.mp4` (played
bars keep the existing rainbow, unplayed/resting bars are faded + a leading playhead
line), matching the in-extension preview, without regressing the extension's
memory/termination safeguards.

---

## Key design decisions

### 1. Progress is baked per-frame, not played at runtime
Today `writeVideoTrack` appends **one** static pixel buffer at every presentation
time. We change it to render a **distinct frame per presentation time**, where each
frame's `progress = presentationSeconds / durationSeconds` (clamped 0…1). Because
each frame's playhead position is pinned to its presentation time, playback sync is
automatic on the OS video clock — no runtime player logic needed.

**Reach the end exactly (MF1):** do NOT append an extra frame and do NOT rely on a
plain `min(1,…)` clamp — the clamp is a no-op because the last emitted frame sits at
`(n-1)/fps < duration`, so it never reaches 1.0. Instead, **force the progress of the
LAST emitted frame** (highest index in the frame-times array) to exactly `1.0`;
interior frames use `presentationSeconds / duration`. That terminal frame is held from
its PTS through `endSession(atSourceTime: duration)`, so the playhead lands at the far
edge exactly as the audio ends, without touching the session boundary. Endpoint
reached is a Phase 4 validation check. This is also the parity criterion with the
preview (both linear over duration; match only when audio duration == muxed video
duration — see §2).

### 2. One shared draw model (prevents preview/video drift)
SwiftUI `Canvas` (preview) and Core Graphics `CGContext` (mp4) are different APIs,
so we can't literally share one draw call. Instead extract a **pure geometry+color
model** that both consume:

```
struct WaveformFrame {
    struct Bar { let rect: CGRect; let rgba: (r,g,b,a); let isPlayed: Bool }
    let bars: [Bar]
    let playheadX: CGFloat?      // nil when progress == 0 or no fill
    let cornerRadius: CGFloat
}

enum WaveformLayout {
    static func frame(bars: [Double], progress: Double, size: CGSize,
                      palette: WaveformPalette) -> WaveformFrame
}
```

- Each `Bar` still carries per-bar `rgba` + `isPlayed`. `WaveformLayout.frame(...)`
  computes each bar's `rgba` as **`rainbowColor(t, …)` when played, else the faded
  treatment** — the palette parameterizes the played (rainbow) vs faded treatment
  rather than an accent/muted pair. `WaveformPalette` exposes these as **RGBA
  components** so each side can build its native color type (`UIColor` for CG, `Color`
  for SwiftUI). The faded value must be an **opaque pre-composited** RGBA (not a
  translucent color) so unplayed bars look identical over the renderer's dark gradient
  and the preview's transparent Canvas.
- Bar metrics live in ONE place (count 54, `barWidth = 0.42 * gap`, `radius ≤ 6`,
  symmetric `±0.48·h`, min height 3) — copied from the current `NeonWaveformView`
  metrics, which is the look the user already likes. All metrics derive from `size`,
  so the preview must be pinned to the video's aspect ratio (600:140) for parity —
  see Phase 3.
- **Aspect parity (MF2 — resolved):** DROP the renderer's `hInset 36 / vInset 30` so
  the renderer passes the full **600×140** rect to `WaveformLayout`, and keep the
  preview pinned to 600:140. Both backends therefore feed `WaveformLayout` the same
  **4.29:1** rect — no inset contradiction.
- **Shared fill predicate (L1):** `isPlayed = (t < progress)` is **strict**, so at
  `progress == 0` the resting state is fully faded (bar 0 is NOT lit).
- The renderer and the preview each do only trivial `fill(rect)` / playhead-line
  draws off this model.
- **Progress parity:** preview progress (`AVAudioPlayer.currentTime / duration`) and
  baked progress (`presentationSeconds / videoDuration`) are both linear-over-
  duration and match ONLY if **audio duration == muxed video duration**. Treat that
  equality as a testable criterion (see ENSURE map), along with "playhead reaches the
  far edge exactly as the audio ends."

New file: `VoiceMixCore/Sources/VoiceMixCore/WaveformLayout.swift`.

### 3. Colors: rainbow played + faded unplayed
- **No new brand/accent color.** The **played** bar color = the existing per-bar
  `rainbowColor(t, …)` — reuse it, do NOT remove it. The **unplayed/faded** bar color
  = an **opaque pre-composited dimmed treatment** (e.g. low-lightness/low-saturation,
  or low-alpha-over-dark composited to opaque) so it renders identically over the
  renderer's dark gradient and the preview background.
- Keep the `rainbowColor` usage in BOTH the renderer's `drawWaveform` and
  `NeonWaveformView.playing`; the change is faded-unplayed + baked progress + a
  playhead line, not a recolor.
- **`.ready` (resting pre-send preview) renders as the ALL-FADED state** — equivalent
  to `.playing` at `progress == 0` (every bar faded, no playhead) — so pressing play
  only lights bars up (no recolor pop). The review screen renders
  `NeonWaveformView(mode: model.isPlaying ? .playing : .ready)`, and this keeps the
  resting preview matching the sent bubble.
- **Shared-`.ready` concern resolved:** since **faded = dormant** and **rainbow =
  active/played** everywhere, transitions are intuitive (idle/rest = faded,
  recording/played = rainbow). Recording & transforming keep their existing
  rainbow/shimmer — consistent now, no longer a DON'T violation.
- **Drop the per-bar shadow/glow** in the renderer (blur 10) — native voice memos
  have none, the preview has none, and it removes per-frame cost.

### 4. Playhead line (new in both)
A thin (~2px) **bright/white** rounded rule at `playheadX`, drawn after the bars so it
reads on any rainbow bar color. Suppressed at `progress == 0`.

### 5. Memory & reliability (the #1 failure point)
- Render frames **one at a time** in the write loop, pulling each buffer from
  `adaptor.pixelBufferPool` (fresh buffer per frame — never reuse a buffer the
  encoder may still hold), draw directly into its `CGContext` (no per-frame
  `UIImage`), append, all inside `autoreleasepool`.
- **Fully repaint the opaque background first, every frame.** Pooled buffers recycle
  stale pixels, so translucent bars drawn over an un-cleared buffer would ghost.
- **Data flow (single PCM read):** `makeVideo` samples `bars` once via the existing
  `waveformBars` (no second PCM read) and threads `bars` + `palette` +
  `durationSeconds` through `writeMovie` → `writeVideoTrack`. `writeVideoTrack`
  branches on `bars.isEmpty`: non-empty → per-frame animated draw; empty → the
  existing static single-buffer mic-glyph fallback.
- **Coordinate hygiene (Y-flip):** drawing directly into the raw `CVPixelBuffer`
  `CGContext` is bottom-left / Y-up, unlike `UIGraphicsImageRenderer`+blit. Apply
  `translateBy(x:0, y:h); scaleBy(x:1, y:-1)` so the context is top-left-origin to
  match the SwiftUI `Canvas`, and declare `WaveformLayout` rects as top-left-origin.
  Today's content is Y-symmetric, so this is hygiene against future asymmetric
  elements, not a functional bug now.
- Keep fps ≈ 12 (up from 6). Add a **hard frame cap** (e.g. `maxFrames = 240`) as a
  safety net: if `durationSeconds * 12 > maxFrames`, lower the effective fps so long
  clips never explode the frame count (autonomous per TRUST). `log()` when capped.
- Preserve ALL existing safeguards: `Task.checkCancellation`, `waitForInputReady`
  timeout, `writer.cancelWriting()` on failure, temp-file cleanup, concurrent
  video+audio feeding (the deadlock fix).

### 6. Fallback path unchanged
If PCM sampling yields no bars, keep the current static mic-glyph cover (one
repeated frame). Animated playhead is skipped there (spec: optional). No regression.

---

## Phases

### Phase 1 — Shared layout module (no behavior change yet)
- Add `WaveformLayout.swift` + `WaveformPalette` (RGBA-based).
- Encode the canonical 54-bar metrics + played/muted logic + playhead X.
- Unit-testable pure functions (no UIKit dependency beyond `CGRect`/`CGFloat`).

### Phase 2 — Renderer: per-frame animated encode
- **Data flow:** `makeVideo` samples `bars` once via the existing `waveformBars` (no
  second PCM read) and threads `bars` + `palette` + `durationSeconds` through
  `writeMovie` → `writeVideoTrack`; `writeVideoTrack` branches on `bars.isEmpty`
  (non-empty → animated draw, empty → static mic-glyph fallback).
- Refactor `drawWaveform` → draw from `WaveformFrame` (rainbow played / faded unplayed, no glow).
- Add `drawCover(into cgContext:, size:, bars:, progress:, palette:)` that paints
  background + `WaveformLayout.frame(...)` + playhead directly into a CG context.
- Rewrite `writeVideoTrack` to loop presentation times, compute progress, pull a
  pooled buffer, draw, append (autoreleasepool per frame).
- Bump fps to 12; add frame cap + `log`.
- Keep the fallback (empty bars) on the old single-static-frame path.

### Phase 3 — Preview: adopt shared model + playhead
- `NeonWaveformView.playing` builds colors from `WaveformPalette` via
  `WaveformLayout` (rainbow played / faded unplayed) and draws the playhead line.
- **`.ready` is IN scope:** render it as the all-faded waveform (`.playing` at
  `progress == 0`: every bar faded, no playhead) so the resting pre-send preview
  already matches the sent bubble and play only lights bars up — no recolor pop when
  the user presses play/pause. (Recording/transforming keep their existing rainbow.)
- **Pin the preview to the video aspect ratio** (600:140, e.g.
  `.aspectRatio(600.0/140.0, contentMode: .fit)`), since all metrics derive from
  `size`. **Drop the renderer's `hInset 36 / vInset 30`** (MF2) so both backends feed
  `WaveformLayout` the same full 600×140 (4.29:1) rect.
- `WaveformLayout.frame(...)` is the **only** place `isPlayed` and `playheadX` are
  computed, using the strict predicate `isPlayed = (t < progress)` (L1) so both
  backends consume the same model (no rounding drift on the fill edge, bar 0 not lit
  at progress 0); remove the preview's inline `t <= progress` check.
- Confirm `progress` wiring from the audio player clock is unchanged.

### Phase 4 — Validate
- Build `VoiceMixCore` (`swift build` / Xcode) — no compile regressions.
- Canvas preview iteration for the `.playing` look (fast loop).
- **On-device (physical iPhone):** full record → convert → insert; watch the sent
  bubble play with the playhead advancing in sync. Test short (~2s) and long
  (~15s+) clips for encode reliability (no extension termination).
- **Endpoint check:** confirm the baked fill/playhead reach the far edge (progress
  1.0) exactly as the audio ends — no halting short of the clip end (see §1 terminal
  frame).
- User sign-off on "native enough" (TRUST [ask] gate). The **"native enough" gate
  requires viewing a real OUTGOING (blue) iMessage bubble on-device** — the Canvas
  preview (dark pill on gray) cannot answer native fidelity.

---

## ENSURE → validation map
| ENSURE criterion                                          | How verified                                                                                   |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Playhead advances in sync with audio                      | On-device playback of sent bubble (Phase 4)                                                    |
| Played=rainbow, unplayed=faded, leading playhead line     | On-device + Canvas preview                                                                     |
| Bars still reflect real amplitudes                        | Existing `waveformBars` untouched; visual check                                                |
| Encode reliable on-device, no termination, bounded frames | On-device short+long clips; frame-cap log                                                      |
| Cancellation/timeout/cleanup intact                       | Code review of preserved safeguards; cancel mid-encode                                         |
| Graceful fallback when sampling fails                     | Force empty-bars path; confirm mic cover still renders                                         |
| Preview matches sent bubble                               | Side-by-side preview vs on-device bubble; resting `.ready` is all-faded (no play recolor pop)  |
| Progress parity (preview vs baked)                        | Assert audio duration == muxed video duration; playhead reaches far edge exactly as audio ends |
| "Native enough"                                           | View a real OUTGOING (blue) bubble on-device — Canvas preview cannot answer this               |
|                                                           |                                                                                                |

## Risks / assumptions
- **Encoder cost of distinct frames:** distinct H.264 frames compress worse than
  identical ones, but at 600×140 / 12fps the payload is tiny; frame cap bounds worst
  case. Primary risk remains extension memory — mitigated by pooled buffers +
  autorelease + cap. Must be validated on-device, not Simulator.
- **`pixelBufferPool` availability:** pool exists only after `startWriting` +
  `startSession`; sequencing already satisfies this. If nil, fall back to
  `CVPixelBufferCreate` per frame.
- **Metrics parity:** using preview metrics as canonical means the renderer's pill
  proportions shift slightly from today — intended (matches the liked preview).

## Out of scope
- Backend convert/impersonate changes; `ConvertService`.
- Runtime audio scrubbing UI; transparent video; matching recipient bubble color.
- Restyling the preview **recording/transforming** modes — they keep their existing
  rainbow look intentionally (consistent with rainbow = active everywhere). (`.ready`
  is IN scope — see Phase 3 — because the review screen shows it at rest and it must
  match the sent bubble.)

## Discoveries
- The preview (`NeonWaveformView.playing`) already implements the desired fill
  effect and already receives a `progress` value — this is a port + unify job, not a
  from-scratch feature. The static-waveform-shaped-to-audio requirement is already
  satisfied by `waveformBars`; only the moving progress + native color/metrics are new.
- Round-1 plan review upheld MF3 (eliminate the rainbow↔accent flip by bringing
  `.ready` into the accent palette) and folded MF1/MF2 + Md1–Md7 in as clarifications.
- Color model corrected to rainbow-played / faded-unplayed (no brand color); round-2
  upheld MF1 (terminal frame → progress 1.0) and MF2 (drop renderer inset for aspect
  parity), both applied; MF3 / rainbow-scope dissolved by keeping rainbow everywhere.
