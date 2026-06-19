---
title: "Native-Style Animated Waveform Playback"
author: "human:aaron"
version: 1
created: 2026-06-16
---

# Native-Style Animated Waveform Playback

Make the generated mp4 bubble look and behave as close to a native iOS voice
message as possible: a waveform shaped like the actual audio, with a playback
progress indicator that moves synchronously across it as the clip plays.

## WANT
- Bake **animated playback progress** into the generated `.mp4` so that, on play,
  the waveform visibly advances in sync with the audio. Because frames are pinned
  to presentation times, sync is automatic on playback (no runtime player logic).
- Progress visualization = **fill + leading playhead line**: unplayed bars sit in a
  muted color, each bar "activates" to the accent color as the playhead reaches it,
  and a thin vertical playhead line leads the fill edge.
- Keep the **audio-shaped waveform** that already exists (`waveformBars` → 54
  normalized amplitude bars), but render it in **native bar proportions** (centered,
  symmetric, rounded caps) with a single tasteful **brand accent color** (Claude to
  propose; user confirms).
- Keep the **dark pill background** (current dark gradient) — intentional, theme-safe,
  hides the fact that we can't match the recipient's bubble color.
- Update the **in-extension live preview** (`displayBars` consumer in
  `VoiceTransformView`) to mirror the new native style so what the user sees before
  sending matches what gets inserted.

## DON'T
- Don't touch the backend convert/impersonate flow or `ConvertService` — this is
  purely the presentation/mux layer (`WaveformVideoRenderer`) + the preview view.
- Don't keep the rainbow-on-dark waveform aesthetic.
- Don't attempt a transparent video or to match the recipient's bubble color — not
  possible for a baked mp4; the dark pill is the deliberate compromise.
- Don't blow the iMessage extension's tight memory budget. The mp4 encode is the
  documented #1 failure point; rendering N distinct frames (vs. 1 repeated frame
  today) must stay bounded and must not regress the existing
  bound/cancel/timeout safeguards.
- Don't add a runtime audio player or scrubbing UI — progress is pre-baked into video frames.

## LIKE
- Apple Messages / Voice Memos inline audio playback (gray waveform that fills with
  color left-to-right as it plays).
- The existing `WaveformVideoRenderer` waveform sampling pipeline (keep it).
- Reference screenshots to be supplied by user (optional; decisions above stand without them).

## FOR
- iMessage extension users on a physical iPhone (the only place the encode is
  reliably validated — Simulator routinely kills the extension on H.264 encode).
- Stack: Swift, AVFoundation (`AVAssetWriter` / pixel-buffer adaptor), UIKit
  (`UIGraphicsImageRenderer` / Core Graphics), SwiftUI for the preview.
- Code lives in `VoiceMixCore/Sources/VoiceMixCore/` — primarily
  `WaveformVideoRenderer.swift` and `VoiceTransformView.swift`.

## ENSURE
- On a physical iPhone, sending a converted clip produces an mp4 whose waveform
  **playhead advances in sync with the audio** from start to finish.
- Played bars render in the accent color; unplayed bars render muted; a leading
  playhead line tracks the fill edge.
- The waveform shape still reflects the actual audio amplitudes (loud sections =
  taller bars).
- The encode **completes reliably on-device** without terminating the extension,
  for both short (~2s) and longer (~15s+) clips; total rendered frame count is
  bounded (target ~12fps, capped for long clips).
- The existing cancellation / writer-timeout / cleanup safeguards remain intact.
- If PCM sampling fails, it still falls back to a non-blank cover (no regression of
  the current graceful fallback), animated playhead optional in that path.
- The in-extension preview visually matches the sent bubble's style.

## TRUST
- [autonomous] Frame-generation strategy (e.g. pre-render per-progress-step cover
  images, reuse pixel buffers, autorelease per frame) and the exact memory-bounding
  approach.
- [autonomous] FPS tuning within the reliability bound (~12fps) and the long-clip
  frame-count cap.
- [autonomous] Native bar metrics (count, spacing, corner radius, min height) and
  muted/active color treatment.
- [autonomous] Proposing the brand accent color.
- [ask] Final sign-off on the proposed accent color before it ships.
- [ask] Final on-device visual confirmation that it reads as "native enough."
