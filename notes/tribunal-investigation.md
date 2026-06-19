# Investigation: iOS 17 persona carousel tap-to-center is being constrained by custom snap behavior

## Question
Why does tapping a persona bubble in VoiceTransformView.swift still not reliably move the clicked persona into centered focus in the iOS 17 persona carousel? What is the most likely root cause and what code change should fix it?

## Key Findings
1. The iOS 17 carousel tap handler explicitly requests the tapped persona, but it does so through two competing scroll control mechanisms: a `ScrollViewReader` proxy and `.scrollPosition(id:)`.
   Evidence: `VoiceTransformView.swift` declares `@State private var personaScrollPositionID: String?` at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:467`. In the iOS 17 path, tapping a persona sets `personaScrollPositionID = persona.id`, sets `model.selectedPersona = persona`, and calls `proxy.scrollTo(persona.id, anchor: .center)` inside the same animation block at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:617-623`. The same scroll view also binds `.scrollPosition(id:)` to `personaScrollPositionID` at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:650-659`.

2. The strongest root-cause evidence is the custom `PersonaCarouselScrollTargetBehavior`, which rewrites every proposed target to at most one item away from the current/original offset. That makes a tap on a non-adjacent persona unable to jump all the way to that persona.
   Evidence: the iOS 17 carousel installs `.scrollTargetBehavior(PersonaCarouselScrollTargetBehavior(itemStride: cardWidth + itemSpacing))` at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:649`. The behavior computes `proposedOffset - currentOffset`, clamps that delta to `[-itemStride, itemStride]`, adds it back to the original offset, rounds to a stride, and assigns that as the target at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:925-935`. With six personas declared at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceCatalog.swift:54-103`, a tap can easily be two or more items away; this code deliberately collapses that request to one item.

3. Apple's SwiftUI API model supports this diagnosis: `ScrollTargetBehavior.updateTarget(_:context:)` is specifically the hook that changes the target a scroll view should scroll to, and `.scrollPosition(id:)` uses the scroll target layout for identity-based scrolling.
   Evidence: Apple documents `ScrollTargetBehavior` as allowing custom logic for where scrolls end, with `updateTarget(_:context:)` modifying the proposed target. Apple also documents `.scrollPosition(id:anchor:)` as working with `scrollTargetLayout()` to know the identity of the actively scrolled view and to programmatically scroll to a view identity. In this file, the target layout is enabled at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:643`, the bound scroll position is installed at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:650-659`, and the custom target behavior is installed between them at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:649`.

4. A second contributing issue is that the geometry preference focus updater can immediately overwrite the tapped selection while the scroll animation is still in flight.
   Evidence: every persona reports its current center using a `GeometryReader` into `PersonaCarouselCenterPreferenceKey` at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:632-640`. The scroll view calls `updateFocusedPersona(from:viewportWidth:)` on every preference change at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:666-668`. That function picks whichever reported card center is nearest the viewport center and assigns `model.selectedPersona = persona` at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:672-688`. Immediately after a tap, before the requested card reaches center, the old centered card is still nearest center; this can flip `selectedPersona` back even though the tap handler just selected the clicked persona.

5. The legacy carousel has simpler, more reliable tap-to-center semantics because it scrolls whenever `model.selectedPersona` changes and does not install the custom one-item target limiter or geometry-driven focus override.
   Evidence: the legacy path uses `personaButton(persona)` at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:694-700`; the button's default action sets `personaScrollPositionID` and `model.selectedPersona` at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:716-725`. The legacy scroll view then reacts to `model.selectedPersona` changes by calling `proxy.scrollTo(model.selectedPersona.id, anchor: .center)` at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:707-711`. There is no `.scrollTargetBehavior(...)` or center preference updater in the legacy path at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:690-713`.

6. The most targeted code change is to stop using the custom one-item `ScrollTargetBehavior` for this carousel and use SwiftUI's built-in view-aligned behavior, with an explicit center anchor for the bound scroll position. Then drive taps through the bound scroll position instead of also calling `ScrollViewReader.scrollTo`.
   Evidence: the current custom behavior is installed at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:649` and defined at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:921-937`. The tap currently uses both binding mutation and `proxy.scrollTo` at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:617-623`. The current `.scrollPosition(id:)` has no `anchor:` argument at `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:650-659`, so adding `anchor: .center` would match the desired centered-focus behavior directly.

## Conclusion
The most likely root cause is the custom `PersonaCarouselScrollTargetBehavior`. It is intended to make drag snapping advance by at most one persona, but because it rewrites the scroll target itself, it also constrains programmatic tap scrolling. When the tapped persona is more than one card away, the requested center target is clamped to a one-card move, so the clicked persona does not reliably move into centered focus. The geometry-based focus updater is a secondary race that can make the visible selection snap back to whichever card is currently closest to center before the tap scroll completes.

Confidence level: high.

Recommended fix:

```swift
// In snapCarousel:
personaButton(persona) {
    withAnimation(.snappy(duration: 0.28)) {
        personaScrollPositionID = persona.id
        model.selectedPersona = persona
    }
}
...
.scrollTargetBehavior(.viewAligned(anchor: .center))
.scrollPosition(id: Binding(
    get: { personaScrollPositionID },
    set: { newID in
        personaScrollPositionID = newID
        if let newID,
           let persona = VoicePersona.all.first(where: { $0.id == newID }) {
            model.selectedPersona = persona
        }
    }
), anchor: .center)
```

Also remove `PersonaCarouselScrollTargetBehavior` or at least stop using it in `snapCarousel`. If selection still flickers during animations, remove the `onPreferenceChange` selection writer and let `.scrollPosition(id:anchor:)` be the single source of truth for the focused persona.

## Evidence Trail
- `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:467` — local `personaScrollPositionID` state.
- `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:594-607` — persona carousel chooses the iOS 17 snap path.
- `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:609-669` — iOS 17 carousel implementation, including tap handler, target layout, custom scroll target behavior, scroll position binding, on-appear scroll, and center preference update.
- `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:672-688` — geometry-driven selected-persona update.
- `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:690-713` — legacy carousel behavior for comparison.
- `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:716-744` — persona button selection behavior.
- `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift:921-937` — custom one-item scroll target behavior implementation.
- `/Users/aaron/code/personal/Projects/voiceMix-ios/VoiceMixCore/Sources/VoiceMixCore/VoiceCatalog.swift:54-103` — six personas, making non-adjacent tap requests common.
- Apple Developer Documentation, `ScrollTargetBehavior` — `updateTarget(_:context:)` customizes where a scroll ends; built-in `.viewAligned` settles on target views configured with `scrollTargetLayout()`.
- Apple Developer Documentation, `scrollPosition(id:anchor:)` / `ScrollPosition` — identity-based scroll position works with `scrollTargetLayout()` for programmatic scrolling and active-view identity updates.
