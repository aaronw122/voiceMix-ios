# Task: Critical review of the iOS backend-integration plan

You are reviewing a plan document for an iOS iMessage extension that integrates with
the "voiceMix" backend. Do a rigorous, skeptical, multi-pass review (at least 2–3
passes — first for correctness against the code, then for gaps/risks, then for
sequencing/coordination). Your job is to find what's wrong, missing, or risky — not
to praise it.

## Read these files (in this repo, your cwd)

- `integration-plan.md` — THE PLAN UNDER REVIEW
- `MessagesExtension/ConvertService.swift` — the networking seam (protocol + response)
- `MessagesExtension/LiveConvertService.swift` — real multipart networking
- `MessagesExtension/MockConvertService.swift` — the mock
- `MessagesExtension/Config.swift` — baseURL + useMock flag
- `MessagesExtension/VoiceTransformView.swift` — UI + viewmodel (VoicePersona catalog,
  prepareClip). NOTE: a separate agent is actively editing this file.

## Backend contract (GROUND TRUTH — the backend lives in a sibling repo you cannot
read, so trust these facts extracted from it)

Endpoints (FastAPI):
- `GET /voices` → `[{id, name, engine, acceptsText}]`
- `POST /convert` — multipart `audio` (File) + `voiceId` (Form). **Only accepts
  `engine == "elevenlabs"` voices**; returns 422 for a modal voice.
- `POST /impersonate` — multipart `voiceId` (Form) + EXACTLY ONE of `audio` (File) or
  `text` (Form). **Only accepts `engine == "modal"` voices**; returns 422 for an
  elevenlabs voice. Returns 404 for unknown voiceId.
- Both convert/impersonate return identical JSON: `{url, title, audioUrl}`.
- `GET /share/{clip_id}` — HTML; audio is streamed from `audioUrl`.
- Limits: `MAX_BYTES = 10 MB` (413 over), `MAX_SECONDS = 60` (422 over).
- Public origin: `https://voiceapi.awill.co` (Cloudflare tunnel, HTTPS).

Voices that EXIST in the backend today (`voices.py`):
- `old-man` (Old Man) — engine elevenlabs — acceptsText false
- `young-woman` (Young Woman) — engine elevenlabs — acceptsText false
- `femme-fatale` (Femme Fatale) — engine elevenlabs — acceptsText false
- `jfk` (JFK) — engine modal — acceptsText true

Voices the plan wants but that DO NOT exist server-side yet: `trump`, `obama` (both
intended as modal / `/impersonate`).

## What to evaluate

1. **Correctness**: Does the plan's endpoint routing, voiceId mapping, and engine
   model actually match the backend contract and the current iOS code? Cite file:line.
2. **Gaps / missing steps**: error handling (404/413/422/502/network), loading/timeout
   for modal cold-starts (~15–45s cold), ATS, Info.plist `NSAppTransportSecurity`,
   the persona-id → voiceId rename ripple, anything the plan glosses over.
3. **Risks**: hardcoded-catalog drift vs `/voices`, the Trump/Obama 404 sequencing,
   the worktree/codex collision on `VoiceTransformView.swift`, mock/live parity.
4. **Sequencing & coordination**: is the worktree + merge-back plan sound? Is the
   "ship 3 elevenlabs now, add Trump/Obama later" split actually clean given they
   share one hardcoded catalog file?
5. **Anything the plan is silent on that would bite during a real demo.**

## Output

Write your review to `notes/codex-review-plan-output.md`. Structure it as:
- **Blocking issues** (must fix before implementing) — each with file:line + concrete fix
- **Should-fix** (correctness/robustness gaps)
- **Nice-to-have / questions**
- **Verdict**: is the plan sound enough to implement? One paragraph.

Be specific and concrete. Prefer "change X at file:line to Y because Z" over vague advice.
