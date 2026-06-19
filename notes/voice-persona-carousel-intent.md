---
title: "Voice Persona Carousel Focus"
author: "human:aaron"
version: 1
created: 2026-06-08
---

# Voice Persona Carousel Focus

## WANT
Make the persona picker easier to understand by giving the selected persona stronger visual focus. The selected persona should appear slightly larger, and horizontal scrolling should naturally settle on one exact persona at a time.

## DON'T
Do not change the backend voice IDs, persona list, conversion flow, or record/review behavior.

## LIKE
Native iOS picker/carousel behavior where scrolling has clear resting positions and the centered item feels selected.

## FOR
iMessage extension users choosing a voice before recording. The UI needs to be quick to parse in a compact extension viewport.

## ENSURE
The selected persona is visibly larger than neighbors.
Scrolling horizontally updates focus to a single persona.
Tapping a persona still selects it.
The carousel keeps stable layout dimensions and does not resize the surrounding page.

## TRUST
[autonomous] Tune spacing, scale, opacity, and selection treatment to match the existing visual style.
[autonomous] Use native SwiftUI scroll targeting where available and preserve the existing fallback for older iOS.
[ask] Broader interaction changes outside persona selection.
