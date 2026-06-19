# voiceMix — Project Notes for Claude

iOS host app + **iMessage extension** that records a voice clip, sends it to a backend
for voice transformation, and inserts the result as an inline-playable mp4 into the
conversation.

## Architecture at a glance

- `App/` — host application (also owns the mic-permission grant; the extension consumes it).
- `MessagesExtension/` — the `MSMessagesAppViewController` host (`MessagesViewController.swift`)
  and `sample.mp3`. Everything else (UI + services) lives in the package below.
- `VoiceMixCore/` — local Swift package holding the SwiftUI views + service layer. It was
  extracted from the extension so **SwiftUI Previews work** (app-extension targets cannot host
  previews). The fast UI loop is the Xcode **Canvas preview** in
  `VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift` — the running Simulator does NOT
  hot-reload the extension.

## The record → transform → insert flow

`VoiceTransformViewModel.prepareClip(...)` (in `VoiceTransformView.swift`) runs:
1. `service.convert(...)` → backend `POST /convert` (elevenlabs voices) or `POST /impersonate` (modal voices)
2. `service.fetchAudio(...)` → downloads the transformed mp3
3. `renderer.makeVideo(...)` → **wraps the audio in an H.264 mp4** for inline iMessage playback

On any thrown error the task's `catch` shows **"Convert failed"** and returns to the record screen.
So a "Convert failed" UI message can mean a failure in ANY of the three steps — check which.

## ⚠️ The mp4 encode is the #1 failure point — test on a real device, not the Simulator

The local H.264 mp4 encode (step 3, `WaveformVideoRenderer.writeMovie` via `AVAssetWriter`) is the
heaviest operation and runs **inside the iMessage extension's tight memory budget**. It is a known
sore spot — there is a prior fix "bound and cancel mp4 encode to prevent iMessage extension termination".

- **In the iOS Simulator this step routinely crashes / kills the extension** (and can take down
  `CoreSimulatorService` with it). VideoToolbox/AVAssetWriter H.264 encoding is unreliable on the sim.
- When this happens, the backend logs will show a clean `POST /convert → 200` and `GET /audio → 200` —
  i.e. **the convert genuinely succeeded; only the local mp4 wrap died.** Don't chase the backend.
- **Validate the full record→transform→insert flow on a physical iPhone.** Use the Simulator only for
  layout/visual iteration via the Canvas preview.

## Voice catalog

Personas live in `VoiceMixCore/Sources/VoiceMixCore/VoiceCatalog.swift` (`VoicePersona.all`).
`name` is the display label; `voiceId` is the wire value; `engine` selects the endpoint.

| Persona | engine | endpoint |
|---|---|---|
| Femme Fatale, Young Woman, Old Man | `.elevenlabs` | `POST /convert` |
| Trump, Obama, Queen Elizabeth | `.modal` | `POST /impersonate` |

Backend rejects a wrong voice/engine pairing with a **422**.

## Backend (Hetzner) — how to read convert logs

- Host: SSH alias `hetzner` (server hostname `MusicMixer`). All `ssh hetzner` commands need
  `dangerouslyDisableSandbox: true` (network is outside the Claude Code sandbox).
- The convert API is the Docker container **`voicemix-backend-1`** (`127.0.0.1:8000`), exposed
  publicly as `https://voiceapi.awill.co` via a **Cloudflare tunnel** (`voicemix-cloudflared-1`).
- Tail recent request logs:
  ```bash
  ssh hetzner 'docker logs --since 30m --timestamps voicemix-backend-1 2>&1 | tail -80'
  ```
  Look for `POST /convert`, `POST /impersonate`, `GET /audio/...`, and any non-200 status.

## Config

`VoiceMixCore/Sources/VoiceMixCore/Config.swift`:
- `Config.baseURL` — from the extension Info.plist `API_BASE_URL`, falling back to
  `https://voiceapi.awill.co`. Code in the package resolves `Bundle.main` to the **extension** bundle
  at runtime (the package is statically linked in), so this and `sample.mp3` work normally.
- `Config.useMock` — `false` = real backend; flip to `true` to develop offline against the bundled
  `sample.mp3` (bypasses the network entirely; still exercises preview + insert).

## Gotchas

- **iMessage extension code-cache eviction:** after rebuilding, changes may not appear until you
  uninstall the app AND restart Messages (icons can need a device power-cycle — `iconservicesagent`
  caches by bundle id). Build the same simulator/device you evict on.
- **Case-different project paths** spawn duplicate DerivedData dirs — keep the path casing consistent.
- `xcodebuild ...` that writes DerivedData and all `ssh`/`gh` commands need
  `dangerouslyDisableSandbox: true`.
