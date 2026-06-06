# Backend Integration Plan — iOS ↔ voiceMix

**Owner:** Aaron (iMessage)
**Goal:** Flip the iMessage extension off the mock and onto the real voiceMix backend, with a curated voice lineup that routes to the correct endpoint per voice.

**Coordination:** A codex agent is editing the frontend (`VoiceTransformView.swift`) on `feat/recording-60s-limit`. All integration work below happens in a **separate git worktree** to avoid collisions.

> Revised after a codex `/review-plan` pass. See "Review fixes folded in" at the bottom.

---

## Lineup

Hardcoded catalog, IDs mapped to the backend. Each voice carries an `engine` that
selects the endpoint — the backend rejects the wrong pairing (422), so this is not
optional. **Ships in two phases** to avoid 404s on voices that don't exist server-side yet.

| Tile | backend `voiceId` | engine | endpoint | exists server-side? | phase |
|------|-------------------|--------|----------|---------------------|-------|
| Old Man | `old-man` | elevenlabs | `POST /convert` | ✅ yes | **1** |
| Young Woman | `young-woman` | elevenlabs | `POST /convert` | ✅ yes | **1** |
| Femme Fatale | `femme-fatale` | elevenlabs | `POST /convert` | ✅ yes | **1** |
| Trump | `trump` | modal | `POST /impersonate` | ❌ needs backend | **2** |
| Obama | `obama` | modal | `POST /impersonate` | ❌ needs backend | **2** |

> JFK (`jfk`, modal) is the one impression voice already live server-side. Useful as a
> DEBUG-only tile in phase 1 to exercise the `/impersonate` path before Trump/Obama land
> (keep it out of the production lineup unless wanted). If added, it **must** carry
> `engine: .modal` + `acceptsText: true` so the preflight validates modal *routing*, not
> just voice existence.

Response shape is identical for both endpoints — `{url, title, audioUrl}` — so
everything downstream (`fetchAudio` → waveform video → inline bubble) is unchanged.

---

## Phase 1 — ship the 3 elevenlabs voices live (no backend dependency)

### 1a. Pre-work: resolve the worktree/untracked-file hazard FIRST
`MessagesExtension/VoiceTransformView.swift` is currently **untracked** (`git status`),
as are several other changes on `feat/recording-60s-limit`. A worktree branched off
committed HEAD would **not contain it**. Before anything else:
- Commit (or stash-and-carry) the frontend branch's current state, **or** base the
  integration branch directly on the codex's branch state.
- Coordination checkpoint: **frontend (codex) lands first**, then the integration
  branch rebases on it, then the catalog extraction happens once — avoids a 3-way
  conflict on a file that's being actively rewritten.

```bash
git worktree add ../voiceMix-ios-integration -b feat/backend-integration
```

### 1b. New `MessagesExtension/VoiceCatalog.swift` (extracted from the view)
- Move `VoicePersona` + `.all` here. Add fields:
  - `voiceId: String` — backend id (`old-man`, …). This is what goes on the wire.
  - `engine: Engine` — `.elevenlabs` | `.modal`
- Phase 1 catalog = **only** `old-man`, `young-woman`, `femme-fatale` (+ optional DEBUG JFK).
  Do **not** add Trump/Obama here until phase 2 (else their tiles 404 on `/impersonate`).
- **Register the new file in `voiceMixer.xcodeproj/project.pbxproj`** — the project lists
  Swift files explicitly. Add to: `PBXFileReference`, the MessagesExtension group,
  `PBXBuildFile`, and the `voiceMixerMessages` `PBXSourcesBuildPhase`. Without this it
  won't compile into the extension.

### 1c. `VoicePersona` identity migration (audit, not a one-liner)
Today `.id` is both the SwiftUI `Identifiable` identity **and** the value sent to the
service (`elder`/`aria`/`mlk`). Splitting it:
- Keep `id` as stable UI identity; add `voiceId` for the network call.
- Audit every `.id` use: `Identifiable`/`ForEach`, `Equatable`, the page-dot indicators,
  and `prepareClip`. Only `prepareClip` should send `voiceId` (was `selectedPersona.id`
  at `VoiceTransformView.swift:297`). Flag this rename to codex.

### 1d. `ConvertService.swift` — engine on the seam + typed errors
- `convert(audioURL:voiceId:engine:) -> ConvertResponse`.
- Replace the single `invalidResponse` with status-specific cases:
  `httpStatus(Int, body: String?)` (or domain cases for 404/413/422/502 + network/timeout),
  decoding/logging the response body. The current collapse makes "missing voice",
  "wrong engine", "file too large", "engine 502", and "network down" all look identical.

### 1e. `LiveConvertService.swift` — route by engine + harden
- `.elevenlabs` → `POST /convert`; `.modal` → `POST /impersonate`.
- Multipart body identical (`audio` file part + `voiceId` form field). For modal, send
  **exactly** `voiceId` + `audio`, **no `text` part** (the backend rejects both). Add a
  request-builder test asserting this.
- Map non-2xx to the typed errors from 1d (read body, don't swallow).
- **Testability:** `multipartBody` is `private` and there is **no test target** in the
  project today. Add a step to either create a unit-test target or make the request
  builder internal/package-visible so the modal single-part assertion (and elevenlabs
  body shape) can actually be tested.
- Sanitize the upload filename to a fixed `recording.m4a` (avoid `Content-Disposition`
  header injection from a future file source — `LiveConvertService.swift:72`).
- Size guard: check file size **before** reading the whole file + body into memory;
  fail with a specific "too large" error rather than buffering then 413-ing.
- `fetchAudio` is already correct (GET `audioUrl` → temp `.mp3`).

### 1f. `MockConvertService.swift`
- Match the new signature. In DEBUG, assert known `voiceId`/`engine` pairings (or expose a
  spy that records them) so mock-green doesn't mask wrong live routing.

### 1g. `Config.swift` — keep the override path
- **Do not** hardcode-only. `Config` already reads `API_BASE_URL` (`Config.swift:11-16`)
  but `MessagesExtension/Info.plist` has **no such key today** — so the override is dead
  until wired. Add `API_BASE_URL = $(API_BASE_URL)` to the extension Info.plist and define
  Debug/Release build settings (Debug→dev, Release→prod) per `steel.md`. Set the code
  fallback to `https://voiceapi.awill.co`. (Or explicitly decide the override is
  opportunistic and skip it — but don't leave it half-wired.)
- `useMock = false` for live (keep mock path for offline dev).

### 1h. `/voices` DEBUG preflight (promoted to core)
At launch in DEBUG, fetch `GET /voices` and fail loudly if the local catalog's `voiceId`,
`engine`, or `acceptsText` no longer matches the server. The hardcoded catalog is
otherwise silent drift → 404/422 at demo time.
- **Placement:** a small `VoiceCatalogPreflight` invoked from
  `MessagesViewController.viewDidLoad` (after the root view exists), gated `#if DEBUG`,
  with a short timeout and non-blocking behavior. Do **not** put async networking in
  static catalog initialization or in `Config`.

### 1i. ATS check
Inspect **both** `MessagesExtension/Info.plist` and `App/Info.plist` for any stale
`NSAppTransportSecurity` override. HTTPS origin needs none; document that a plain-HTTP
local/tunnel dev endpoint requires a **debug-only, extension-target** ATS exception.

### 1j. `VoiceTransformViewModel.prepareClip` + error copy
Pass `selectedPersona.engine` into `convert(...)`. Today every failure maps to
`"Convert failed"` and resets to record (`VoiceTransformView.swift:286-291`). Map the
typed `ConvertServiceError` cases to distinct user-visible status lines (404 = "voice
unavailable", 413/422 = "recording too long/large", 502 = "voice engine busy, try again",
offline = "no connection"). On transient 502/network failure, **keep** the selected
persona + recorded clip so the user can retry instead of being dropped back to record.

---

## Phase 2 — Trump & Obama (backend-gated)

Add `trump` and `obama` as `modal` voices (`acceptsText: true`) in
`backend/app/voices.py` once john's Modal impersonation models exist (path-B / ASR→TTS in
the backend `plan.md`). Land the iOS tiles **in the same coordinated release** so they
never 404. Before wiring modal voices, add modal-specific UX:
- Cold-start timeout policy (Modal cold start ~15–45s) — the current status copy reaches
  "Rendering new audio…" and then stalls indefinitely (`VoiceTransformView.swift:346`).
- A cold-start-aware status line + a real timeout/cancel.

---

## Stays aligned (no work needed)
- 60s recording cap matches backend `MAX_SECONDS = 60`.
- No API keys on the client — backend owns ElevenLabs / Modal credentials.

---

## Verification (post-implementation, loopy)
1. Confirm `voiceapi.awill.co` is live: `GET /voices` returns the catalog.
2. **Assert the live switch actually took**: service selection happens in
   `MessagesViewController` property init (`MessagesViewController.swift:9-10`) and
   `Config.useMock` is still `true` today (`Config.swift:24-25`). Log/assert at that
   selection site that `useMock == false`, `baseURL == https://voiceapi.awill.co`, and
   `LiveConvertService` is the instance in use.
3. Record → convert against each phase-1 elevenlabs voice → inline bubble plays; verify
   real network traffic / backend logs per voice.
4. Exercise error paths: unknown voice (404), oversized/over-60s (413/422), engine
   failure (502), airplane mode (network) — confirm each shows a distinct status line.
5. `/impersonate` path verified in phase 2 (or via the DEBUG JFK tile earlier).

---

## Review fixes folded in (from codex `/review-plan`)
- **Blocking:** two-phase catalog split (no Trump/Obama tiles before backend); register
  `VoiceCatalog.swift` in `project.pbxproj`; full `.id`→`voiceId` audit; typed HTTP error
  handling before going live; assert the live switch in verification.
- **Should-fix:** keep the `API_BASE_URL` override (don't hardcode-only); ATS plist audit
  + HTTP-dev caveat; modal single-part (`audio` only) test; promote `/voices` preflight to
  core; pre-read size guard; modal cold-start timeout/UX (phase 2); fixed `recording.m4a`
  filename; mock engine-parity assert; retry-preserves-clip on transient failure.
