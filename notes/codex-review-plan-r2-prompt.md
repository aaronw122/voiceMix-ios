# Task: Round 2 review of the iOS backend-integration plan

This is the SECOND review round. `integration-plan.md` was revised to address round-1
findings (see its "Review fixes folded in" section). Your job: verify the revisions
actually resolve the prior issues, and surface anything still open or newly introduced.
Be skeptical — confirm fixes are concrete and correct, not just mentioned.

## Read these files (your cwd)
- `integration-plan.md` — THE REVISED PLAN
- `MessagesExtension/ConvertService.swift`, `LiveConvertService.swift`,
  `MockConvertService.swift`, `Config.swift`, `VoiceTransformView.swift`
- `voiceMixer.xcodeproj/project.pbxproj` — to confirm the pbxproj-registration step is
  accurate (does the file really list sources explicitly? cite the build phase).

## Backend contract (GROUND TRUTH — sibling repo you cannot read; trust these)
- `GET /voices` → `[{id,name,engine,acceptsText}]`
- `POST /convert` — multipart `audio`+`voiceId`; ONLY `engine=="elevenlabs"` (422 otherwise)
- `POST /impersonate` — multipart `voiceId` + EXACTLY ONE of `audio`/`text`; ONLY
  `engine=="modal"` (422 otherwise); 404 unknown voiceId
- Both return `{url,title,audioUrl}`. Limits: 10MB (413), 60s (422). Origin
  `https://voiceapi.awill.co` (HTTPS, Cloudflare tunnel).
- Exists today: `old-man`,`young-woman`,`femme-fatale` (elevenlabs), `jfk` (modal).
  NOT yet: `trump`,`obama`.

## Evaluate
1. Are the round-1 BLOCKING items genuinely resolved by the revised plan? Go one by one:
   phase split, pbxproj registration, `.id`→`voiceId` audit, typed errors, live-switch
   verification. Cite plan section + code/file:line. Flag any that are hand-wavy.
2. Any NEW problems introduced by the revisions?
3. Any remaining should-fix that would still bite a real demo?

## Output
Write to `notes/codex-review-plan-r2-output.md`:
- **Round-1 items: resolved? (one line each: RESOLVED / PARTIAL / NOT — why)**
- **New issues**
- **Remaining gaps**
- **Verdict**: is the revised plan sound enough to implement now? One paragraph.
Be concrete: file:line + specific fix, not vague advice.
