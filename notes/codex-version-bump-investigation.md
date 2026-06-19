# Investigation: make an interactive version bump apply to the CURRENT Xcode archive

## Goal
When the user runs **Product → Archive** in Xcode, they want to interactively choose:
- how much to bump the **build number** (`CFBundleVersion` / `CURRENT_PROJECT_VERSION`), and
- whether to bump the **marketing version** (`CFBundleShortVersionString` / `MARKETING_VERSION`) by patch/minor/major,

and have **the archive being produced right now carry those chosen numbers** (not the next one).

## Project facts
- Xcode project: `voiceMixer.xcodeproj` (very recent Xcode; scheme LastUpgradeVersion 2630).
- TWO targets that MUST share the same build number (App Store Connect rejects a mismatch):
  - App  → bundle id `com.aaron.voiceMixer`, `INFOPLIST_FILE = App/Info.plist`
  - MessagesExtension (iMessage extension) → `com.aaron.voiceMixer.Messages`, `INFOPLIST_FILE = MessagesExtension/Info.plist`
- Both Info.plists use build-setting substitution:
  - `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`
  - `CFBundleShortVersionString = $(MARKETING_VERSION)`
- Current settings in `project.pbxproj`: `CURRENT_PROJECT_VERSION` (per target), `MARKETING_VERSION = 1.0`.
- `GENERATE_INFOPLIST_FILE = NO` (explicit plists).

## What we built so far (and why it FAILS)
- `scripts/bump-build-number.sh` — pops two `osascript` dialogs, then:
  - build number: loops `xcrun agvtool next-version` (NO `-all`, to preserve the `$(CURRENT_PROJECT_VERSION)` substitution and keep both targets in sync),
  - marketing: `sed -i '' -E 's/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = <new>;/g' project.pbxproj`.
- Wired as an **Archive PRE-action** in `voiceMixer.xcodeproj/xcshareddata/xcschemes/voiceMixer.xcscheme` (Shell `/bin/sh`, "Provide build settings from" = voiceMixer, scriptText = `"${PROJECT_DIR}/scripts/bump-build-number.sh"`).

### Reproduced failure (key evidence)
1. Reset `CURRENT_PROJECT_VERSION` to `1`. Quit & reopened Xcode so the scheme reloaded (verified the pre-action shows under Edit Scheme → Archive → Pre-actions).
2. Ran Product → Archive, chose build "+1", marketing "None".
3. **Result:** `project.pbxproj` is now `CURRENT_PROJECT_VERSION = 2` (pre-action DID run), **but the produced archive shows `1.0 (1)` in Organizer.**

Conclusion: Xcode resolves/caches the build settings for the archive BEFORE the pre-action's on-disk edit is re-read, so the archive ships the pre-bump value. The script works standalone (proven). The problem is purely the pre-action vs. build-settings-caching race.

## What we want you to do
1. **Confirm or refute** the root-cause analysis above (pre-action edits the project too late to affect the current archive's already-resolved build settings).
2. **Recommend the most robust mechanism** to make the CURRENT archive carry the chosen version while keeping an interactive "decide at archive time, all optional" UX. Our leading candidate:
   - Keep the interactive `osascript` prompt in the **pre-action**, but have it WRITE the chosen final values to a temp file (e.g. `$TMPDIR` or a build-dir path),
   - then add a **Run Script BUILD PHASE** to BOTH targets (App + MessagesExtension), ordered LAST, guarded to archive-only (`[ "$ACTION" = install ]`), that reads those chosen values and writes them straight into the **compiled** Info.plist of the output bundle via PlistBuddy:
     `"${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"` → `Set :CFBundleVersion` / `Set :CFBundleShortVersionString`.
   - This patches the final signed-input artifact, so caching can't out-race it.
   Evaluate this vs. alternatives (e.g. doing the bump in a wrapper before `xcodebuild`, xcconfig approaches, `AGVTOOL`/`VERSIONING_SYSTEM`). Call out pitfalls: build-phase script sandboxing (`ENABLE_USER_SCRIPT_SANDBOXING`), phases running on every Debug build, signing/`Info.plist`-already-processed ordering, the two targets needing identical build numbers, and whether editing the compiled Info.plist after signing breaks the signature (note: build phases run before code signing, so it should be fine — confirm).
3. Give the **exact, concrete implementation**: the build-phase shell script(s), where in the build-phase order they go, the guards, and any required build-setting changes. If safe, you may edit the repo files directly (the scheme, `scripts/`, and add new `scripts/*.sh`), but do NOT hand-edit `project.pbxproj` to add build phases unless you are confident — instead give precise step-by-step Xcode UI instructions for adding the Run Script phase to each target.

## Constraints / gotchas
- Never use `agvtool ... -all` (it clobbers the `$(...)` substitution in the source plists).
- Both targets' build numbers must stay identical.
- Must degrade gracefully with no GUI (CI / `xcodebuild` headless) → no prompt, leave versions unchanged.
- macOS `sed -i ''` and `/usr/libexec/PlistBuddy` are available.

## Files to read
- `voiceMixer.xcodeproj/project.pbxproj`
- `voiceMixer.xcodeproj/xcshareddata/xcschemes/voiceMixer.xcscheme`
- `scripts/bump-build-number.sh`
- `App/Info.plist`, `MessagesExtension/Info.plist`
- `CLAUDE.md` (project notes — architecture context)

## Output
Write your findings + concrete recommended implementation to `notes/codex-version-bump-output.md`. Be specific and implementation-ready. Keep it focused.
