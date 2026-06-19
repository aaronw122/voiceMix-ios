# Plan Review Task — iMessage Steel Thread

Read the plan at `steel.md` (project root) and review it. Write your full review to `notes/2026-06-06-steel-review-r1-codex.md`.

## Context (critical — read carefully)

This is the **iMessage steel-thread plan** for a 10-hour hackathon tool called voiceMix (record your voice → backend converts it to a different voice/accent → send as an inline audio bubble in iMessage). Aaron owns the iMessage surface.

**Steel-thread philosophy:** get ONE voice working all the way through, end-to-end, before adding any breadth. The thread proves the architecture; everything else hangs off it. Teammates are decoupled behind a stable HTTP contract so nobody blocks anybody.

**The contract (already locked by the team):**
- `POST /convert` — multipart: `audio` (the recording) + `voiceId`. Returns JSON `{ url, title, audioUrl }`.
- Client then does `GET audioUrl` to fetch the MP3 bytes from object storage (presigned URL).
- iMessage delivers the clip inline via `conversation.insertAttachment(fileURL)`.

**Current reality for THIS plan:**
- Assume german's `/convert` + `/share` endpoints WILL be ready later — the live network path is a deliberate FUTURE swap.
- For now, **no backend runs anywhere** (not local, not remote). The whole iMessage flow must be testable **client-side only** against a mock that returns a bundled sample MP3.

## What to judge the plan on

1. Does it achieve a genuinely **client-side-validatable** steel thread (record → fake-convert/loading → inline audio bubble) with zero backend?
2. Is the **mock→real swap** clean and low-risk (network seam isolated, real `LiveConvertService` written to the locked contract)?
3. Is it faithful to **steel-thread discipline** — one voice, end-to-end, no premature breadth?
4. **iOS / Messages-framework / audio correctness:** mic permissions in an app extension, compact→expanded presentation, AVAudioRecorder format, `insertAttachment` requirements, ATS, App Groups. Flag anything technically wrong or missing that would block the thread.

## Review scope — planning vs implementation (IMPORTANT)

Plan reviews catch STRUCTURAL/ARCHITECTURAL issues, not implementation details discovered while coding.

- **Fix now (plan-level):** missing components/steps the thread depends on; contract mismatches with `/convert`; wrong iOS API usage that would invalidate the approach; architectural gaps; internal inconsistencies between sections.
- **Log as Impl-note (do NOT treat as blocking):** exact API parameter values, threading edge cases, exact recorder settings to tune, defensive coding, error-retry curves, anything you'd naturally catch when writing/running the code.

**The test:** "Would discovering this during implementation cause significant rework or wrong architecture?" If yes → plan-level. If no → Impl-note.

## Severity classification (two-step)

For every issue: FIRST apply the scope test. If it fails (it's implementation-level), tag it **Impl-note** regardless of how bad it sounds. ONLY if it's a genuine plan-level problem, assign:
- **Critical** — will cause crashes/data loss/security issues or makes the steel thread impossible at the architectural level
- **Must-fix** — significant structural / contract / design problem
- **Medium** — should fix before coding, not blocking
- **Low** — nice to have
- **Impl-note** — real but implementation-level; will not trigger plan fixes

## Output format

Write to `notes/2026-06-06-steel-review-r1-codex.md`. Group findings by severity tier. For each finding: one-line description + the plan section it refers to + a concrete suggested fix. Be concise. Do not rewrite the plan; just review it.
