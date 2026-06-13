# Verdict: The carousel is broken because the iOS 17 path has competing scroll and selection authorities, not because of one single line.

## Disputed Points

### Finding 1: Tap uses both `ScrollViewReader.scrollTo` and `.scrollPosition(id:)`

MODIFIED.

The code evidence is upheld: in `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift`, the iOS 17 tap handler sets `personaScrollPositionID`, sets `model.selectedPersona`, and calls `proxy.scrollTo(persona.id, anchor: .center)` in the same animation block at lines 618-623. The same scroll view also binds `.scrollPosition(id:)` at lines 650-659.

The causal claim needs modification. This is not merely "two mechanisms" in the abstract; it is two scroll commands with potentially different semantics, because the `.scrollPosition(id:)` binding has no `anchor: .center`, while the proxy scroll does. The code is therefore issuing both identity-based scrolling and proxy-based centered scrolling for the same tap.

What I verified: current source lines 614-659.

### Finding 2: `PersonaCarouselScrollTargetBehavior` clamps targets to one item

MODIFIED.

The behavior really does clamp the target offset to at most one item stride from `context.originalTarget.rect.minX`, then rounds to an item stride and assigns `target.rect.origin.x` at lines 925-935. With six personas in `VoiceCatalog.swift` lines 54-103, non-adjacent tap requests are common, so this custom behavior is risky and inconsistent with "tap any persona into focus."

However, I do not treat it as proven that this custom `ScrollTargetBehavior` is the sole tap root cause. The code proves it can constrain scroll target resolution. It does not, by itself, prove every `ScrollViewReader.scrollTo` or `.scrollPosition(id:)` programmatic request is intercepted in exactly the same way. The custom behavior should still be removed or replaced because it is brittle and works against multi-item jumps.

What I verified: current source lines 649 and 921-937, plus persona count in `VoiceCatalog.swift` lines 54-103.

### Finding 3: Apple's SwiftUI API model supports the investigation's diagnosis

MODIFIED.

The general SwiftUI model supports concern about scroll-target behavior: this carousel marks the HStack with `.scrollTargetLayout()` at line 643, installs a custom `.scrollTargetBehavior(...)` at line 649, and binds `.scrollPosition(id:)` at lines 650-659.

But the defense is right that this does not fully prove the custom snapper is the tap-specific root cause. The code itself reveals a more direct inconsistency: the bound scroll position omits a center anchor even though the required behavior is centered focus. So the API-model point is valid as background, but overstated as proof.

What I verified: current source lines 643-659.

### Finding 4: Geometry preference focus updater can overwrite tapped selection during animation

UPHELD.

This is a concrete and highly relevant defect. Each card reports its current center through a geometry preference at lines 633-640. Every preference change calls `updateFocusedPersona(from:viewportWidth:)` at lines 666-668. That function picks whichever card center is currently nearest the viewport center and writes `model.selectedPersona = persona` at line 687.

Immediately after a tap, the old centered item can still be nearest the viewport center. Therefore the tap can set the clicked persona active, and the geometry updater can promptly set the old centered persona active again while the scroll is still in flight. It also does not sync `personaScrollPositionID`, creating split state between the scroll-position binding and the selected persona model.

What I verified: current source lines 618-623, 633-640, 666-688.

### Finding 5: Legacy carousel has simpler, more reliable semantics

UPHELD.

The legacy path has one practical source of selection truth: tapping `personaButton` changes `model.selectedPersona`, and the scroll view reacts with `proxy.scrollTo(model.selectedPersona.id, anchor: .center)` on selection change. It does not use `.scrollPosition(id:)`, the custom `PersonaCarouselScrollTargetBehavior`, or the geometry preference writer.

This does not prove the custom behavior alone is guilty, but it strongly supports the broader diagnosis that the iOS 17 implementation regressed by adding multiple conflicting authorities.

What I verified: current source lines 690-713 and 716-725.

### Finding 6: Recommended fix should remove custom behavior, use native centered scroll positioning, and simplify state

UPHELD WITH MODIFICATION.

The recommended direction is correct, but the fix should be framed as collapsing the iOS 17 carousel to one source of truth, not only deleting the custom snapper.

The concrete fix should:

- Remove `ScrollViewReader` from the iOS 17 path, or at least stop issuing `proxy.scrollTo` alongside `.scrollPosition`.
- Replace `PersonaCarouselScrollTargetBehavior` with native centered target behavior such as `.viewAligned(anchor: .center)`.
- Use `.scrollPosition(id: ..., anchor: .center)`.
- Let the scroll-position binding map the centered id to `model.selectedPersona`.
- Remove or strictly gate the geometry preference updater so it cannot overwrite tap selection during programmatic scroll.

This also matches `notes/voice-persona-carousel-intent.md`, which asks for native iOS picker/carousel behavior, centered selection, tapping selection, stable layout, and native SwiftUI targeting where available.

What I verified: current source lines 614-688, custom behavior lines 921-937, and intent file lines 10-30.

## Final Answer

The persona carousel still does not work right because the iOS 17 carousel has competing state and scroll writers. A tap sets `personaScrollPositionID`, sets `model.selectedPersona`, and calls `ScrollViewReader.scrollTo`. At the same time, `.scrollPosition(id:)` is bound without a center anchor, a custom scroll target behavior clamps target movement to one item, and a geometry preference updater independently rewrites `model.selectedPersona` based on whichever bubble is currently closest to center.

The most defensible root cause is the multi-writer design. The geometry updater is the clearest tap-visible bug because it can immediately undo the tapped active persona while the carousel is still animating. The custom one-item target behavior is also a real defect and should be removed, but the evidence does not prove it is the only or primary tap-specific cause.

Confidence: high.

What would change this answer: a runtime trace from iOS 17 showing that `ScrollTargetBehavior.updateTarget` is never called for tap/programmatic scrolls would reduce the custom-snapper portion of the diagnosis, but would not change the overall multi-writer verdict. A trace showing no geometry preference changes during tap animation would reduce the geometry-race weight, but the missing centered scroll-position anchor and duplicate scroll commands would remain.

## Recommendations

1. Refactor the iOS 17 carousel to one scroll authority: `.scrollPosition(id:anchor:)`.
2. Add `anchor: .center` to the scroll-position binding.
3. Replace `PersonaCarouselScrollTargetBehavior` with native `.viewAligned(anchor: .center)` or equivalent native centered targeting.
4. Remove the geometry preference selection writer, or gate it during programmatic tap scrolls. Prefer letting the scroll-position binding update `model.selectedPersona`.
5. Preserve the legacy fallback unless it is separately retested and replaced.
