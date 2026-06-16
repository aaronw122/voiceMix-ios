# Devil's Advocate: version-bump tribunal challenge

## Summary

The investigator is right that the build-phase script stamped `1`, but overstates what that proves. The evidence establishes the immediate mechanism, not the root cause. The proposed env-file design is directionally better than grepping `project.pbxproj`, but only if the file path, freshness, and failure behavior are nailed down. As written, the env-file alternative can silently fall back to the stale/corrupted built plist and still ship `1`.

## Findings challenged

### 1. "The archive shipped `1` because the build phase stamped `1`"

**CONCEDE, but incomplete.** The build log line is strong evidence: `apply-archive-version-to-built-plist.sh` prints the parsed values at line 56, after reading `CURRENT_PROJECT_VERSION` from `project.pbxproj` at lines 43-46 and applying PlistBuddy at lines 49-54.

But this is a mechanism, not a root cause. It does not tell us why the script saw `1` while the current project file has `2` at `project.pbxproj:323` and `:458`. The missing evidence is the actual pre-action log for the same archive.

### 2. "(a) Pre-action did not run is the best explanation"

**CHALLENGE.** This is plausible, but not proven. The scheme does define the Archive pre-action at `voiceMixer.xcscheme:74-95`, and it invokes `"${PROJECT_DIR}/scripts/bump-build-number.sh"` at `:82` with the app buildable as the environment at `:83-91`.

Other explanations still fit the evidence:

- The build log and current file state may be from different archive attempts.
- Xcode may have used an already-loaded scheme/project state while the repo file later changed.
- The pre-action may have run but selected/returned `0` due to `osascript` cancellation, headless failure, or no prompt visibility; the script intentionally maps prompt errors to "leave it" at `bump-build-number.sh:50-60` and `:63-80`.
- The pre-action may have run in a different directory/build environment than expected. The script silently exits successfully if `cd "${PROJECT_DIR:-${SRCROOT:-.}}"` fails at line 29.

If the verdict depends on "pre-action did not run," require proof from the archive action transcript. Without that, the safer conclusion is: the build phase did not receive an explicit per-archive chosen value.

### 3. "Corrupted source plists are not the dominant cause"

**PARTIAL.** For the specific archive where the build phase definitely printed `build 1`, the patcher is the last writer, so the source plist literal `1` is not sufficient by itself.

But it is too weak to call this non-dominant in the system. Both source plists currently contain literal `CFBundleVersion = 1` (`App/Info.plist`, `MessagesExtension/Info.plist`), while the patcher no-ops for non-archive builds at `apply-archive-version-to-built-plist.sh:25-27`. If any future archive patch no-ops because an env file is missing or malformed, the corrupted source plist again ships `1`. Restoring `$(CURRENT_PROJECT_VERSION)` is not cleanup; it is a required safety net.

### 4. "Archive pre-action/build-phase ordering is not the problem"

**CONCEDE with a caveat.** Scheme pre-actions should run before the archive build body, and the target phases are correctly last in each target (`project.pbxproj:115-140`). There is no evidence of target phases interleaving ahead of the pre-action.

The real ordering bug is data visibility: the pre-action mutates persistent project state, while Xcode build settings and processed plists may already be resolved. The target phase must consume an explicit value from the same archive action, not infer intent from cached env vars or persistent project metadata.

### 5. "Reading project.pbxproj is better than cached env vars but not right"

**CONCEDE.** Grepping the first `CURRENT_PROJECT_VERSION` / `MARKETING_VERSION` at `apply-archive-version-to-built-plist.sh:43-46` is brittle. It assumes project-level settings always appear first and both targets inherit them forever. The current project happens to satisfy that today (`project.pbxproj:287-349`, `:422-490`), but this is not a reliable contract.

The script also treats missing `project.pbxproj` as success at lines 32-35. That is dangerous for archive correctness: "could not find source of truth" should not silently produce an uploadable archive.

### 6. "Env-file handoff is the minimal reliable fix"

**PARTIAL / CHALLENGE.** An env-file handoff can solve the root problem, but the proposed version still has failure modes:

- `PROJECT_TEMP_DIR` must be proven identical between the Archive pre-action environment and both target build phases. The scheme pre-action uses the app buildable; the extension phase may not have the same temp path. If this is wrong, the extension either no-ops or reads a stale file.
- The env file must be per-archive or freshness-checked. A stable name like `voicemix-archive-version.env` can be left over from a previous archive. A missing pre-action plus stale file is worse than the current failure because it can stamp an old but plausible value.
- For `ACTION=install`, missing or malformed env file should probably fail the archive, not no-op. A no-op re-exposes the corrupted source plist / cached setting problem and can still produce an App Store upload.
- Sourcing a shell file is avoidable risk. The pre-action writes the file, but robust parsing should still reject unexpected keys/characters and validate `CFBundleVersion` as an integer and marketing version as the expected dotted numeric form.
- The pre-action must write the final values even when the user chooses no bump. Otherwise "leave it" archives become dependent on stale env-file state.

## Stronger go-forward constraints

1. Restore both source plists to `$(CURRENT_PROJECT_VERSION)` before validating anything else.
2. Keep the pre-action prompt, but make it write an explicit archive values file to a deterministic path shared by both targets. Prefer a source-root-derived ignored path such as `${SRCROOT}/.build/voicemix-archive-version.env`, or first prove `PROJECT_TEMP_DIR` equality from actual build logs.
3. Include a nonce/timestamp and expected project path in the file; the build phase should reject stale or wrong-project files.
4. During `ACTION=install`, fail hard if the explicit version file is missing, stale, malformed, or lacks either value. Silent no-op is acceptable for normal builds only.
5. Keep the build phase last and before signing, but add input/output declarations if trying to re-enable script sandboxing later.

## Verdict pressure

Do not let the judge reduce this to "switch pbxproj grep to PROJECT_TEMP_DIR env file." The reliable fix is "pre-action emits an explicit, fresh, validated archive contract; both archive target phases fail unless they consume that contract and stamp identical values."
