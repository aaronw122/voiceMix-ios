# Tribunal review: "archive always ships build 1" despite version-bump automation

Run a 3-role adversarial review and write the result to `notes/codex-tribunal-version-bump-output.md`:
1. **Investigator** — establish the real root cause(s) from the evidence/files below.
2. **Devil's advocate** — attack the proposed design AND the investigator's conclusion; find failure modes.
3. **Judge** — deliver the verdict and a concrete, minimal, reliable go-forward fix.

## Goal (unchanged)
From **Product → Archive** in Xcode, interactively choose (each optional):
- build number bump (`CFBundleVersion` / `CURRENT_PROJECT_VERSION`, integer), and
- marketing version bump (`CFBundleShortVersionString` / `MARKETING_VERSION`, semver),
and have **the archive being produced carry those values**. Two targets (`voiceMixer` app +
`voiceMixerMessages` iMessage extension) MUST end up with identical build numbers.

## Current mechanism (as built)
1. Archive **PRE-action** in `voiceMixer.xcodeproj/xcshareddata/xcschemes/voiceMixer.xcscheme`
   runs `scripts/bump-build-number.sh`: osascript prompts, then bumps `CURRENT_PROJECT_VERSION`
   via looped `agvtool next-version` (NO `-all`) and `MARKETING_VERSION` via `sed` on
   `project.pbxproj`.
2. **Run Script BUILD PHASE** `scripts/apply-archive-version-to-built-plist.sh` on BOTH targets
   (ids `BA110000000000000000AAE1` = extension, `...AAE2` = app), `alwaysOutOfDate = 1`. It runs
   only when `ACTION=install`, reads `CURRENT_PROJECT_VERSION`/`MARKETING_VERSION` from
   `project.pbxproj`, and writes them into `"${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"` via PlistBuddy.
3. `ENABLE_USER_SCRIPT_SANDBOXING` set to `NO` (both project-level configs) so the build phase
   can read the project file and write the built plist.

Rationale for #2: an earlier attempt used ONLY the pre-action; it bumped `project.pbxproj` but the
produced archive still shipped the OLD number, because Xcode resolves/caches build settings for the
archive before re-reading the pre-action's on-disk edit. So we moved to patching the compiled plist.

## EVIDENCE from the failing run (all verified just now)
- `project.pbxproj`: `CURRENT_PROJECT_VERSION = 2` (x2), `MARKETING_VERSION = 1.0` (x2),
  `ENABLE_USER_SCRIPT_SANDBOXING = NO` (x2), the 4 build-phase id occurrences are present.
- **REGRESSION introduced by the assistant:** `App/Info.plist` and `MessagesExtension/Info.plist`
  were changed from `<string>$(CURRENT_PROJECT_VERSION)</string>` to `<string>1</string>`
  (literal). Cause: a stray `xcrun agvtool new-version -all 1` (the `-all` flag rewrites the SOURCE
  plists); a later `git checkout` reverted only `project.pbxproj`, leaving the plists corrupted.
  `CFBundleShortVersionString` is still `$(MARKETING_VERSION)` (intact).
- Build log (decompressed `.xcactivitylog`) for the latest archive CONFIRMS the build phase ran on
  both targets:
  - `voiceMix: stamped voiceMixer Info.plist -> version 1.0 build 1.`
  - `voiceMix: stamped voiceMixerMessages Info.plist -> version 1.0 build 1.`
  - Xcode note: "Run script build phase 'Apply Archive Version' will be run during every build
    because ... 'Based on dependency analysis' is unchecked." (Config Release, SDK iOS 26.2)
- Latest `.xcarchive` Info.plists: app `CFBundleVersion = 1`, `CFBundleShortVersionString = 1.0`;
  extension `CFBundleVersion = 1`. (Organizer shows `1.0 (1)`.)
- Xcode version: 26.3 (17C529). Project `objectVersion = 77`.

## The contradiction to resolve
`project.pbxproj` is now `2`, yet the build phase stamped `1` and the archive shipped `1`. Possible
explanations the investigator must weigh:
(a) the pre-action did NOT run for that archive (no prompt), so pbxproj was `1` during the build and
    only became `2` during a different/earlier archive's pre-action;
(b) the corrupted source plists (literal `1`) are the dominant cause and the build phase ALSO read
    `1` (pbxproj was `1` at that moment);
(c) ordering: does an Archive PRE-action reliably run BEFORE the target build phases of the SAME
    archive, such that the build phase sees the bumped pbxproj? Or can they interleave?
(d) is reading `project.pbxproj` from the build phase even the right source of truth, vs. the
    cached env vars `$CURRENT_PROJECT_VERSION`/`$MARKETING_VERSION` the build sees?

## Questions for the tribunal
1. Confirm/refute each candidate cause. What is THE root cause of "ships 1"?
2. Is the pre-action + build-phase split sound, or is there a simpler/more reliable single mechanism?
   Specifically evaluate: doing everything in ONE archive flow without depending on
   pre-action→build-phase ordering or on re-reading the mutated project file.
3. Is "build phase reads project.pbxproj" robust during an archive, or should it instead derive the
   final values another way (e.g., the pre-action writes chosen values to a file the build phase
   reads; or compute from the cached env + an offset)? Note the earlier env-file idea was rejected
   over PROJECT_TEMP_DIR path-matching worry — re-examine if that worry is real.
4. Confirm the exact go-forward fix, including: restoring the two source plists to
   `$(CURRENT_PROJECT_VERSION)`, and whatever change makes the chosen version reliably land in BOTH
   archived bundles. Keep it minimal.
5. Any risk in `ENABLE_USER_SCRIPT_SANDBOXING = NO`, or in editing the built plist before signing?

## Files to read
- `scripts/bump-build-number.sh`
- `scripts/apply-archive-version-to-built-plist.sh`
- `voiceMixer.xcodeproj/xcshareddata/xcschemes/voiceMixer.xcscheme`
- `voiceMixer.xcodeproj/project.pbxproj`
- `App/Info.plist`, `MessagesExtension/Info.plist`
- `notes/codex-version-bump-output.md` (prior investigation)

## Output
Write `notes/codex-tribunal-version-bump-output.md` with: Investigator findings, Devil's-advocate
rebuttal, Judge verdict, and a numbered, implementation-ready go-forward fix. Be concise and concrete.
