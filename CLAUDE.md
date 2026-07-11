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
1. `service.convert(...)` → backend `POST /impersonate` (the self-hosted engine on the **Abyss**
   machine transcribes the clip with CrisperWhisper, then re-speaks it with F5-TTS)
2. `service.fetchAudio(...)` → downloads the transformed mp3
3. `renderer.makeVideo(...)` → **wraps the audio in an H.264 mp4** for inline iMessage playback

On any thrown error the task's `catch` shows **"Convert failed"** and returns to the record screen.
So a "Convert failed" UI message can mean a failure in ANY of the three steps — check which.

> **Legacy naming:** in code the engine enum is still `VoiceEngine.modal` and the endpoint is
> `/impersonate` — these are historical names from when the TTS ran on Modal. It no longer does
> (see Backend below). The `.elevenlabs` case / `POST /convert` path is **retired** — no persona
> uses it anymore, so `/impersonate` is the only live transform endpoint.

## ⚠️ The mp4 encode is the #1 failure point — test on a real device, not the Simulator

The local H.264 mp4 encode (step 3, `WaveformVideoRenderer.writeMovie` via `AVAssetWriter`) is the
heaviest operation and runs **inside the iMessage extension's tight memory budget**. It is a known
sore spot — there is a prior fix "bound and cancel mp4 encode to prevent iMessage extension termination".

- **In the iOS Simulator this step routinely crashes / kills the extension** (and can take down
  `CoreSimulatorService` with it). VideoToolbox/AVAssetWriter H.264 encoding is unreliable on the sim.
- When this happens, the backend logs will show a clean `POST /impersonate → 200` and `GET /audio → 200` —
  i.e. **the convert genuinely succeeded; only the local mp4 wrap died.** Don't chase the backend.
- **Validate the full record→transform→insert flow on a physical iPhone.** Use the Simulator only for
  layout/visual iteration via the Canvas preview.

## Voice catalog

Personas live in `VoiceMixCore/Sources/VoiceMixCore/VoiceCatalog.swift` (`VoicePersona.all`).
`name` is the display label; `voiceId` is the wire value; `engine` selects the endpoint.

There are **3 personas**, all fine-tuned F5-TTS voices on the same self-hosted engine:

| Persona (name) | voiceId | engine | endpoint |
|---|---|---|---|
| El Prez | `el-prez` | `.modal` | `POST /impersonate` |
| Dwarkesh | `dwarkesh` | `.modal` | `POST /impersonate` |
| Tech Magnate | `tech-magnate` | `.modal` | `POST /impersonate` |

Backend rejects an unknown `voiceId` with a **404** (`GET /voices` lists the catalog it accepts).

## Backend — self-hosted on the Abyss machine

The transform backend runs on **Abyss**, Aaron's home **gaming PC with a GPU**. The whole voice
engine lives there now — the iPhone talks to it directly (still at `https://voiceapi.awill.co`);
it does **not** go through the old Hetzner box.

- **Stack:** F5-TTS (fine-tuned per-voice, text→speech) + **CrisperWhisper** (speech→text ASR).
  A recording is transcribed by CrisperWhisper, then re-spoken by the target voice's F5-TTS model.
- **API contract** (what the client calls): `POST /impersonate` (multipart `voiceId` + `audio`) →
  returns JSON with an `audioUrl`; `GET /audio/...` downloads the mp3; `GET /voices` lists the catalog.
- **Retired:** the Hetzner `voicemix-backend-1` Docker container, the Modal cloud endpoints
  (`TTS_MODAL_ENDPOINT_URL`), and the ElevenLabs `/convert` path. Ignore any of those if you find
  them in stale checkouts (e.g. the `voiceMix` repo) — they are no longer in the request path.

> **TODO (Aaron to confirm):** exactly how to reach Abyss and read its request logs — SSH
> alias / how the F5-TTS server process is launched (bare process vs container) / where it logs.
> Fill this in so log-reading is scriptable like the old `ssh hetzner 'docker logs …'` was.

## Config

`VoiceMixCore/Sources/VoiceMixCore/Config.swift`:
- `Config.baseURL` — from the extension Info.plist `API_BASE_URL` (set to `https://voiceapi.awill.co`
  in the project build settings), falling back to the same URL. That origin now routes to the **Abyss**
  machine (see Backend above). Code in the package resolves `Bundle.main` to the **extension** bundle
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
