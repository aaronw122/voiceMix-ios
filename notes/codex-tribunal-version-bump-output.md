# Tribunal verdict: archive version bump ships build 1

## 1. Investigator findings

- The immediate mechanism is confirmed: the archive shipped `1` because `scripts/apply-archive-version-to-built-plist.sh` stamped `build_version` into the built plists from its parsed source (`scripts/apply-archive-version-to-built-plist.sh:43-56`). The reported build log line `version 1.0 build 1` means the script's runtime value was `1`.
- The current repo state contradicts that runtime value: `voiceMixer.xcodeproj/project.pbxproj` now has `CURRENT_PROJECT_VERSION = 2` in project Release and Debug (`project.pbxproj:323`, `project.pbxproj:458`) and `MARKETING_VERSION = 1.0` (`project.pbxproj:338`, `project.pbxproj:479`).
- The source plists are corrupted and must be restored: both `App/Info.plist:21-22` and `MessagesExtension/Info.plist:21-22` currently contain literal `<string>1</string>` for `CFBundleVersion`; they should contain `$(CURRENT_PROJECT_VERSION)`.
- The Archive pre-action is wired (`voiceMixer.xcscheme:74-95`) and invokes `scripts/bump-build-number.sh` (`voiceMixer.xcscheme:81-82`). That script mutates `project.pbxproj` with `agvtool next-version` and `sed` (`scripts/bump-build-number.sh:83-99`), but it does not currently write an explicit per-archive contract for target build phases.
- The build phases are correctly positioned last in both targets (`project.pbxproj:115-120`, `project.pbxproj:136-140`) and are always out of date (`project.pbxproj:157-185`), which is appropriate for patching the processed plist before signing.

Candidate resolution:

- (a) Pre-action did not run for that archive: plausible but not proven. The stronger verdict is that the build phase did not receive an explicit chosen value for that archive. The current `2` can be from a different run or later repo state.
- (b) Corrupted source plists are dominant cause: refuted for the archive where the build phase logged `build 1`, because the patcher was the last writer. Still a required fix because non-archive builds and any patcher failure fall back to literal `1`.
- (c) Pre-action/build-phase ordering: no evidence that target build phases run before the Archive pre-action. The issue is data visibility/freshness, not target-phase ordering.
- (d) Build phase should read cached env vars: refuted. `$CURRENT_PROJECT_VERSION` / `$MARKETING_VERSION` can be stale after an Archive pre-action edit. But grepping `project.pbxproj` is also not robust enough as the inter-phase source of truth.

## 2. Devil's-advocate rebuttal

- The investigator correctly identifies the stamping mechanism, but cannot prove why the script saw `1` without the exact pre-action transcript for that same archive.
- A stable env-file handoff is better than grepping `project.pbxproj`, but it must not silently no-op or read stale data during `ACTION=install`. Missing or malformed archive values should fail the archive, not produce another uploadable `1`.
- `PROJECT_TEMP_DIR` may be shared in this scheme, but the safer minimal path is a deterministic source-root-derived ignored file, because both the app and extension target phases have `SRCROOT`. Use a file under `${SRCROOT}/.build/`, include the source root and a timestamp/nonce, and reject mismatches.
- Sourcing an arbitrary shell file is unnecessary. Use simple `KEY=value` parsing with validation, or source only after strict ownership/content checks. Validate build as an integer and marketing as dotted numeric text.
- Restoring source plists to `$(CURRENT_PROJECT_VERSION)` is not cleanup; it is the safety net that makes normal builds and failed archive patching honest.

## 3. Judge verdict

The root cause of "ships 1" is not simply "the source plists say 1" and not reliably "the pre-action did not run." The root cause is that the archive flow uses `project.pbxproj` as both persistent state and same-archive communication, then the build phase stamps whatever it can parse at runtime. In the failing archive, that parsed value was `1`; the current file later says `2`, so current repo state is not a trustworthy record of the archive's per-run chosen value.

The pre-action + build-phase split is sound for the required Product -> Archive UX, but only if the pre-action writes a fresh, explicit archive-version contract and the build phases consume that contract. A single build-phase-only implementation would prompt twice and can race across targets. A CLI wrapper would be cleaner but does not preserve Product -> Archive.

The build phase should not read `project.pbxproj`, and it should not use cached Xcode env vars for values changed by the pre-action. It should read the explicit contract file written by the pre-action. Keep patching the built plist before signing; that is the right artifact and timing.

`ENABLE_USER_SCRIPT_SANDBOXING = NO` (`project.pbxproj:328`, `project.pbxproj:463`) is not the cause, but it broadens script read/write permissions. Keep it only as a short-term expedient. Add explicit input/output paths and try re-enabling sandboxing once the handoff file and built plist write are declared. Editing the built plist before signing is acceptable; editing it after signing would invalidate the bundle, but these phases are before signing and last in each target's build phases.

## 4. Numbered implementation-ready go-forward fix

1. Restore both source plists:
   - `App/Info.plist:21-22` -> `<key>CFBundleVersion</key>` / `<string>$(CURRENT_PROJECT_VERSION)</string>`
   - `MessagesExtension/Info.plist:21-22` -> `<key>CFBundleVersion</key>` / `<string>$(CURRENT_PROJECT_VERSION)</string>`

2. Change `scripts/bump-build-number.sh` so it always writes the final chosen values after the optional bumps, including when the user chooses "leave it":
   - Use a deterministic shared path such as `${SRCROOT:-${PROJECT_DIR}}/.build/voicemix-archive-version.env`.
   - Create the directory.
   - Write keys like:
     - `VOICE_MIX_ARCHIVE_VERSION_FILE=1`
     - `VOICE_MIX_SRCROOT=<absolute SRCROOT/PROJECT_DIR>`
     - `VOICE_MIX_WRITTEN_AT=<epoch seconds>`
     - `VOICE_MIX_BUILD_VERSION=<final agvtool value>`
     - `VOICE_MIX_MARKETING_VERSION=<final MARKETING_VERSION>`
   - Continue persisting the project bump to `project.pbxproj` for future builds.

3. Change `scripts/apply-archive-version-to-built-plist.sh`:
   - Keep `ACTION != install` as a no-op.
   - For `ACTION=install`, read only the explicit archive-version file; stop grepping `project.pbxproj`.
   - Fail the archive if the file is missing, malformed, for a different `SRCROOT`, stale for the current archive window, or lacks either value.
   - Validate `VOICE_MIX_BUILD_VERSION` as an integer and `VOICE_MIX_MARKETING_VERSION` as dotted numeric text before calling PlistBuddy.
   - Patch `${TARGET_BUILD_DIR}/${INFOPLIST_PATH}` for both `CFBundleVersion` and `CFBundleShortVersionString`.

4. Keep the two `Apply Archive Version` build phases last and always out of date (`project.pbxproj:115-120`, `project.pbxproj:136-140`, `project.pbxproj:157-185`). Add input/output declarations:
   - Input: `$(SRCROOT)/.build/voicemix-archive-version.env`
   - Output: `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)`

5. Keep `ENABLE_USER_SCRIPT_SANDBOXING = NO` only if Xcode blocks the declared read/write paths. The preferred final state is sandboxing re-enabled with declared inputs/outputs.

6. Verify with a fresh Xcode Product -> Archive after quitting/reopening Xcode:
   - Choose build `+1`, marketing unchanged.
   - Confirm both archived plists show the same final build:
     - `voiceMixer.xcarchive/Products/Applications/voiceMixer.app/Info.plist`
     - `voiceMixer.xcarchive/Products/Applications/voiceMixer.app/PlugIns/voiceMixerMessages.appex/Info.plist`
   - Confirm the build log says both targets stamped the same explicit contract value.
