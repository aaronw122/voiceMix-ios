# Challenge: The custom snap behavior is suspicious, but the investigation overstates it as the proven tap root cause

## Point-by-Point

### Finding 1: Tap uses both `ScrollViewReader.scrollTo` and `.scrollPosition(id:)`

PARTIAL.

The code evidence is accurate. The iOS 17 tap path writes `personaScrollPositionID`, writes `model.selectedPersona`, and calls `proxy.scrollTo(persona.id, anchor: .center)` in one animation block at `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:618-623`, while the same scroll view has a `.scrollPosition(id:)` binding at `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:650-659`.

The investigator is right that this creates multiple scroll-control paths, but the writeup treats "competing mechanisms" as self-evidently causal. That is not proven. The more concrete defect is that `.scrollPosition(id:)` is installed without `anchor: .center`. Apple's `ScrollPosition` documentation says that if no anchor is provided, SwiftUI scrolls the minimal amount needed when programmatically scrolling to a view. That means the binding write can legitimately bring the tapped bubble merely into view instead of centered. The separate `proxy.scrollTo(..., anchor: .center)` tries to correct this, but the code has now issued two potentially different scroll intents in the same transaction.

My evidence:
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:620` sets `personaScrollPositionID = persona.id`.
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:622` separately calls `proxy.scrollTo(persona.id, anchor: .center)`.
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:650-659` binds scroll position without an anchor.
- Apple docs for `ScrollPosition` state that without an anchor, SwiftUI uses the minimal scroll needed for programmatic view-id scrolling. That directly matches the symptom "tap selects but does not center."

### Finding 2: `PersonaCarouselScrollTargetBehavior` clamps every proposed target to one item

PARTIAL.

The custom behavior really does clamp `target.rect.origin.x` to at most one `itemStride` away from `context.originalTarget.rect.minX`, then rounds to a stride at `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:925-935`. For drag snapping, this absolutely limits motion to one item. With six personas in `VoiceCatalog.swift:54-103`, non-adjacent jumps are normal. This is risky code and likely contributes to the carousel feeling wrong.

But the investigation's strongest claim is not fully established: it says the custom behavior rewrites programmatic tap scrolling. Apple's `updateTarget(_:context:)` documentation says the system calls this method in two main cases: when a scroll gesture ends and when a scrollable view's size changes. It does not say this hook is invoked for `ScrollViewReader.scrollTo` or every `.scrollPosition(id:)` programmatic write. The `originalTarget` property is also described as the original target when the scroll gesture began, which further weakens the claim that a tap-driven `scrollTo` necessarily gets clamped through this path.

This does not exonerate the behavior. It means the investigation overstates causality. A better conclusion would be: the custom behavior is a plausible cause for drag/flick settling and may also interfere with programmatic scrolling in practice, but the code contains more direct and documented tap-centering failures even if this behavior only applies to gesture/resize target calculation.

My evidence:
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:649` installs `PersonaCarouselScrollTargetBehavior`.
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:930` clamps `proposedOffset - currentOffset` to one stride.
- Apple docs for `updateTarget(_:context:)` emphasize gesture-end and size-change target calculation, not tap/programmatic scroll calls.

### Finding 3: Apple's SwiftUI model supports the diagnosis

CHALLENGE.

This is cherry-picked. The docs do support the general fact that `ScrollTargetBehavior` can modify scroll end targets and that `.scrollPosition(id:)` works with `scrollTargetLayout()`. They do not prove the custom behavior constrains `proxy.scrollTo` or binding-driven programmatic jumps.

The same official documentation supplies a competing explanation that the investigation missed: `.scrollPosition(id:)` without an anchor does not imply center alignment. The current code wants centered focus but uses `.scrollPosition(id:)` without `anchor: .center` at `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:650-659`. That is not a secondary concern; it is directly on the desired behavior.

My evidence:
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:643` correctly applies `.scrollTargetLayout()`.
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:650-659` binds identity-based scroll position but omits a center anchor.
- Apple's `ScrollPosition` documentation says identity-based scrolling uses target layout, and no-anchor programmatic scrolling uses a minimal scroll. That contradicts the assumption that simply assigning an id should center the selected persona.

### Finding 4: Geometry preference focus updater can overwrite tapped selection during animation

CONCEDE.

This is a real issue and may be more central than the investigation makes it. Every card reports its midX at `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:633-640`; `onPreferenceChange` calls `updateFocusedPersona` at `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:666-668`; that function writes `model.selectedPersona` to whichever card is closest to the viewport center at `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:672-688`.

Immediately after a tap, the old centered card can still be closest to center. So the code can set the tapped persona active, then promptly set the previous centered persona active again. From the user's perspective, that is exactly "tapping a bubble should make it active, but it doesn't."

The investigation undersells one nuance: `updateFocusedPersona` changes `model.selectedPersona` but does not sync `personaScrollPositionID`. That creates a split brain: the visual active persona, page dots, gradient, and title depend on `model.selectedPersona`, while `.scrollPosition(id:)` is bound to `personaScrollPositionID`. Once these diverge, later scroll updates can produce unintuitive behavior.

My evidence:
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:620-621` sets both scroll id and selected persona on tap.
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:687` later writes `model.selectedPersona = persona` based only on geometry.
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:687` does not also write `personaScrollPositionID`.

### Finding 5: Legacy carousel has simpler, more reliable tap-to-center semantics

CONCEDE.

The comparison is fair. The legacy path uses `ScrollViewReader` only, scrolls on `model.selectedPersona` changes, and has no iOS 17 scroll-position binding, custom target behavior, or geometry preference writer at `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:690-713`.

This does not prove the custom target behavior is the root cause, but it does show that the iOS 17 path introduced several independent sources of scroll and selection truth. The legacy path's important property is not merely "no custom behavior"; it is "one selection state drives one scroll command."

My evidence:
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:707-711` scrolls to `model.selectedPersona.id` whenever the selected persona changes.
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:690-713` has no geometry-based selected-persona writer.
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:690-713` has no `.scrollPosition(id:)` binding.

### Finding 6: Recommended fix is to remove the custom behavior, use `.viewAligned(anchor: .center)`, and drive taps through scroll position

PARTIAL.

This fix is directionally good but incomplete as a diagnosis-backed recommendation.

I agree with removing or replacing the custom `PersonaCarouselScrollTargetBehavior`; it is brittle, has unclear interaction with programmatic scrolling, and violates the intent note's preference for native SwiftUI scroll targeting in `notes/voice-persona-carousel-intent.md:30`.

I also agree with adding `anchor: .center` to `.scrollPosition`. That should be treated as a first-order fix, not just a cleanup. The current no-anchor binding is independently inconsistent with centered focus.

The part I would challenge is leaving the geometry writer around as an optional later cleanup. The code already has `.scrollPosition(id:)` capable of reporting active identity and a binding setter that maps new ids into `model.selectedPersona`. Keeping `onPreferenceChange` as a second selected-persona writer preserves the same race the investigation identified. If the intended source of truth is the centered target, remove the geometry preference writer or gate it while a tap/programmatic scroll is in flight.

My evidence:
- `notes/voice-persona-carousel-intent.md:23-25` says the selected persona should be larger, scrolling updates focus, and tapping still selects.
- `notes/voice-persona-carousel-intent.md:30` explicitly trusts native SwiftUI scroll targeting where available.
- `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:650-659` already maps scroll-position id changes into `model.selectedPersona`, making the geometry writer redundant or conflicting.

## Counter-Conclusion

The original investigation probably points at a real problem, but it overclaims the root cause. The most defensible answer is that the iOS 17 carousel is broken because it has too many independent scroll/selection writers:

1. Taps set `personaScrollPositionID`.
2. Taps set `model.selectedPersona`.
3. Taps also call `ScrollViewReader.scrollTo(..., anchor: .center)`.
4. `.scrollPosition(id:)` is bound without a center anchor, so its own programmatic behavior can be minimal-scroll rather than center-scroll.
5. `onPreferenceChange` independently overwrites `model.selectedPersona` based on current geometry during the scroll animation.
6. A custom `ScrollTargetBehavior` clamps gesture targets to one item and may also interfere with other target calculations, but the investigation does not prove it intercepts tap/programmatic scrolls.

So I would not state "the custom snap behavior is the root cause" with high confidence. I would state: the custom snap behavior should be removed, but the more rigorous fix is to collapse the carousel to one source of truth using native centered scroll positioning.

Concretely: remove `ScrollViewReader` from the iOS 17 path, remove `PersonaCarouselScrollTargetBehavior`, use `.scrollTargetBehavior(.viewAligned(anchor: .center))`, use `.scrollPosition(id: ..., anchor: .center)`, and remove or strictly gate the geometry preference selection writer. Let the scroll-position binding be the only mechanism that updates the active persona from scroll state, while taps only assign the desired id.

## Overall Assessment

The investigation is useful and mostly aimed at the right code. It correctly identifies the iOS 17 carousel path, the one-item clamp, the geometry-driven selection overwrite, and the legacy/iOS 17 behavioral split.

Its weak spot is causal certainty. It treats `ScrollTargetBehavior` as proven to constrain programmatic tap-to-center, but the cited API docs do not establish that. It also underweights the missing `.scrollPosition(..., anchor: .center)` and the fact that `updateFocusedPersona` can desynchronize `model.selectedPersona` from `personaScrollPositionID`.

Strength: medium-high as a bug hunt, medium as a root-cause proof. The recommended direction is broadly right, but the final fix should target the whole multi-writer design rather than only the custom snap behavior.
