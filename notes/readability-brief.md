# Readability Review — VoiceMixCore + MessagesViewController

You are performing a **readability review** (review only — DO NOT modify any source files).
Produce a written report. Cognitive-load reduction, not linting, not architecture change.

## Scope (review ONLY these files)
- VoiceMixCore/Sources/VoiceMixCore/AudioRecorder.swift
- VoiceMixCore/Sources/VoiceMixCore/Config.swift
- VoiceMixCore/Sources/VoiceMixCore/ConvertService.swift
- VoiceMixCore/Sources/VoiceMixCore/LiveConvertService.swift
- VoiceMixCore/Sources/VoiceMixCore/MockConvertService.swift
- VoiceMixCore/Sources/VoiceMixCore/VoiceCatalog.swift
- VoiceMixCore/Sources/VoiceMixCore/VoiceCatalogPreflight.swift
- VoiceMixCore/Sources/VoiceMixCore/VoiceTransformView.swift
- VoiceMixCore/Sources/VoiceMixCore/WaveformVideoRenderer.swift
- MessagesExtension/MessagesViewController.swift

Read each file in full. You have read-only repo access (`cat`, `git diff`, etc.).

## The 7 principles to assess against
1. **Newspaper ordering** — public API / exports at top, private helpers below.
2. **Naming as narrative** — names tell the story without comments. A name needing a comment is wrong.
3. **Chunking** — group related logic with whitespace; long methods → named steps that read like a checklist.
4. **Guard clauses over nesting** — early returns flatten logic; deep nesting is a tax.
5. **Signal-to-noise** — remove dead code, redundant comments ("increment i"), unnecessary abstractions.
6. **Consistent abstraction level** — one altitude per function; don't mix orchestration with implementation detail.
7. **Predictable patterns** — similar things look similar; normalize one-off divergences.

## Constraints on what you RECOMMEND
- All proposed changes must be **behavior-preserving** — no logic/API/semantic changes.
- Do NOT recommend adding comments/docs (except replacing a bad name that can't be improved).
- Do NOT recommend changing public interfaces (signatures, exports, the package's public surface).
- Do NOT recommend moving code between files — reorder within a file only.
- This is NOT a linter pass and NOT a bug hunt. Stay on readability.

## Output
Write the report to `notes/readability-review.md` in exactly this format:

```markdown
## Readability Review
- **Date:** <timestamp>
- **Scope:** VoiceMixCore package + MessagesViewController (10 files)
- **Files reviewed:** <count>
---

### Summary
<1-3 sentences: overall readability state + highest-impact changes>

### Findings by File

#### `path/to/file.swift`
| # | Principle | Issue (cite line) | Proposed Change |
|---|-----------|-------------------|-----------------|
| 1 | Naming | `d` at L12 is cryptic | Rename to `recentUsers` |

(Omit a file's section entirely if it has no findings — say so in the Summary instead.)

### Systemic Patterns
<issues repeating across files — fix once, apply everywhere>

### Suggested Fix Order
<numbered, highest-impact first, dependencies respected>
```

Be specific and cite file:line for every finding. Keep it tight and evidence-based — no filler.
If a file is already clean, say so rather than inventing nits. Do not edit any file other than `notes/readability-review.md`.
