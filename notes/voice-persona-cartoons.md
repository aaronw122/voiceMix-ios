---
title: "Voice Persona Cartoons + Roster Reskin"
author: "human:aaron"
version: 1
created: 2026-06-13
---

# Voice Persona Cartoons + Roster Reskin

## WANT
- Give each voice in the carousel a cartoon avatar instead of a plain monogram letter.
- The cartoon sits **inside the existing gradient ring** (gradient becomes the ring/background,
  cartoon image fills the center). Keep the selection glow.
- Reskin the 6 carousel slots to a new persona roster **without changing the wire contract**.
  Existing `voiceId`/`engine` values stay; only display `name`, `tag`, `monogram`, colors, and
  artwork change.
- New roster (mapped onto existing slots so nothing 422s today):

  | Slot (voiceId — unchanged) | engine | Was | Becomes |
  |---|---|---|---|
  | `femme-fatale` | elevenlabs | Femme Fatale | Femme Fatale |
  | `trump` | modal | Trump | Trump |
  | `obama` | modal | Obama | Yoda |
  | `queen_elizabeth` | modal | Queen Elizabeth | Batman |
  | `young-woman` | elevenlabs | Young Woman | Dwarkesh |
  | `old-man` | elevenlabs | Old Man | Elon |

- Ship **placeholder cartoon stand-ins now** (SF Symbol per persona, inside the gradient ring),
  with the loading code wired so real cartoon art files drop in later with no code change.

## DON'T
- Don't touch the network/wire contract — `voiceId`, `engine`, and endpoints are frozen.
- Don't bloat the iMessage extension's memory budget — assets must stay small (avatars only).
- Don't remove the gradient/brand colors or the selection glow.
- Don't change the carousel tile dimensions or overall layout.

## LIKE
- The existing `PersonaAvatarView` gradient-circle + glow treatment (keep the frame, swap the fill center).
- Target art style (for the eventual real files): **recognizable cartoon caricature** of each persona
  (Yoda, Batman are fictional; Trump, Dwarkesh, Elon are real public figures rendered as caricatures).

## FOR
- voiceMix iMessage extension users picking a voice in the carousel.
- SwiftUI on iOS; code lives in the `VoiceMixCore` Swift package (so Canvas previews work).
- Fast iteration loop = Xcode Canvas preview in `VoiceTransformView.swift` (the running Simulator
  does NOT hot-reload the extension).

## ENSURE
- Xcode build succeeds (package + extension compile cleanly with new personas + asset wiring).
- Canvas preview renders the 6 reskinned tiles; capture a screenshot to show the result.
- Graceful fallback: if a real cartoon asset is missing, the tile falls back to the placeholder
  SF Symbol, and ultimately to the gradient+monogram — nothing renders blank or crashes.
- Backend voices for Yoda/Batman/Dwarkesh/Elon are NOT built yet ("building soon"): until then the
  reskinned slots still produce the OLD voice on the wire. This is expected, not a bug.

## TRUST
- [autonomous] Pick placeholder SF Symbols, per-persona gradient colors, monograms, tags, and the
  asset-loading structure.
- [autonomous] Implement, build, and render the Canvas preview without check-ins.
- [ask] Surface the final preview + the voiceId→display mapping for review at the end.
- [ask] Backend voiceId updates (when real voices land) are a separate, later change.
