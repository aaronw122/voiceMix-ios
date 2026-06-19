# Investigator: archive version bump failure

## Bottom line

The archive shipped `1` because the build-phase script stamped `1` into both built plists. The source plist regression is real and must be fixed, but it is not enough to explain the archive result once `Apply Archive Version` ran: that script overwrites the built `CFBundleVersion` from the value it parses at runtime.

The hard evidence is:

- `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh:25` runs only for `ACTION=install`.
- `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh:29` reads `${SRCROOT}/voiceMixer.xcodeproj/project.pbxproj`.
- `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh:43` parses the first `CURRENT_PROJECT_VERSION`; `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh:50` writes it to the built plist; `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh:56` prints the stamped values.
- The prompt evidence says the archive log printed `version 1.0 build 1` for both targets, so that script's runtime `build_version` was `1`.
- The current project file now has `CURRENT_PROJECT_VERSION = 2` at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:323` and `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:458`, with `MARKETING_VERSION = 1.0` at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:338` and `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:479`.

Those facts are only consistent if the build phase, during the failing archive, saw a project file whose first `CURRENT_PROJECT_VERSION` was still `1`, or it read a different/stale project path. Xcode's cached build-setting environment cannot explain the build-phase log, because the current script does not use `$CURRENT_PROJECT_VERSION`.

## Candidate causes

### (a) Pre-action did not run for that archive

Mostly confirmed as the best explanation for the stamped `1`, with one caveat: the available files do not include the raw archive log or prompt interaction history. The scheme does define an Archive pre-action at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/xcshareddata/xcschemes/voiceMixer.xcscheme:74` through `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/xcshareddata/xcschemes/voiceMixer.xcscheme:95`, and it invokes `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/bump-build-number.sh` at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/xcshareddata/xcschemes/voiceMixer.xcscheme:82`.

But the failing archive's build-phase output says the pbxproj value at script runtime was `1`. Since the current pbxproj value is `2`, either the pre-action did not bump before that build phase, the archive log was from a different run than the current file state, or the build phase read a different checkout/path. Among the listed candidates, (a) best matches the contradiction.

### (b) Corrupted source plists are the dominant cause

Refuted for the archive where the build phase ran. The source plists are corrupted:

- `/Users/aaron/code/personal/Projects/voiceMix-ios/App/Info.plist:19` through `/Users/aaron/code/personal/Projects/voiceMix-ios/App/Info.plist:22` has `CFBundleShortVersionString = $(MARKETING_VERSION)` but `CFBundleVersion = 1`.
- `/Users/aaron/code/personal/Projects/voiceMix-ios/MessagesExtension/Info.plist:19` through `/Users/aaron/code/personal/Projects/voiceMix-ios/MessagesExtension/Info.plist:22` has the same.

That is a real regression and breaks normal non-archive builds because the archive patcher exits for non-install actions at `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh:25`. But for the failing archive, the prompt evidence says the patcher ran on both targets and stamped `1`. Therefore the archive result came from the patcher's selected value, not only from `ProcessInfoPlistFile` expanding the corrupted source plists.

### (c) Archive pre-action/build-phase ordering

No evidence of target-build-phase interleaving before the Archive pre-action. The scheme-level Archive pre-action is configured before the archive action body, not as a target phase. The fragile part is not ordinary phase ordering; it is using a scheme action to mutate project metadata and then expecting all later archive machinery, paths, and logs to line up with that mutation.

The current build phases are placed last in each target:

- Extension target phases end with `BA110000000000000000AAE1 /* Apply Archive Version */` at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:115` through `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:120`.
- App target phases end with `BA110000000000000000AAE2 /* Apply Archive Version */` at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:136` through `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:140`.

That placement is sound for patching after plist processing and before signing.

### (d) Reading project.pbxproj vs cached env vars

Cached env vars are not a reliable source for the chosen archive values after a pre-action edits the project. The previous investigation correctly identified that `ProcessInfoPlistFile` can use stale build settings; the current script comments also state that at `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh:9` through `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh:19`.

Reading `project.pbxproj` is better than cached env vars for the intended design, but it is still not the right source of truth. In this repo it happens to work structurally because `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` exist only at project-config level and both targets inherit them: project Release at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:287` through `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:349`, project Debug at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:422` through `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:490`, while target configs only set plist file/bundle settings at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:350` through `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:420`.

However, `grep -m1` over pbxproj is brittle if a future target override, xcconfig, or reordered object appears. More importantly, this failure shows that "current checked file after the run" is not necessarily the file state the archive patcher used during the run. The source of truth should be an explicit per-archive values file written by the pre-action.

## Is the split sound?

The split is sound only if the pre-action records the selected final values in an explicit artifact and the build phases consume that artifact. The current version of the split is not reliable enough because it uses `project.pbxproj` both as persistent state and as inter-phase communication.

A single build-phase-only mechanism is worse here: both targets would run it, parallel target builds could duplicate prompts or race, and the extension must be patched before it is signed/embedded. A wrapper around `xcodebuild archive CURRENT_PROJECT_VERSION=... MARKETING_VERSION=...` would be cleaner technically, but it does not satisfy the Product -> Archive interactive Xcode UX.

The minimal reliable Xcode UX is therefore still:

1. Archive pre-action prompts once.
2. Pre-action persists the project bump for future builds.
3. Pre-action writes the final chosen values to a shared per-archive file.
4. Both target build phases read that file and patch their built plists.

`PROJECT_TEMP_DIR` is a reasonable location for that file because the pre-action is tied to the app buildable at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/xcshareddata/xcschemes/voiceMixer.xcscheme:83` through `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/xcshareddata/xcschemes/voiceMixer.xcscheme:91`, and both targets are in the same project archive. If there is lingering concern, use a path derived from `SRCROOT` plus a generated ignored file, but `PROJECT_TEMP_DIR` avoids dirtying the source tree.

## Minimal reliable fix

1. Restore source plists:
   - `/Users/aaron/code/personal/Projects/voiceMix-ios/App/Info.plist:21` through `/Users/aaron/code/personal/Projects/voiceMix-ios/App/Info.plist:22` should be `<key>CFBundleVersion</key>` / `<string>$(CURRENT_PROJECT_VERSION)</string>`.
   - `/Users/aaron/code/personal/Projects/voiceMix-ios/MessagesExtension/Info.plist:21` through `/Users/aaron/code/personal/Projects/voiceMix-ios/MessagesExtension/Info.plist:22` should match.
2. Change `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/bump-build-number.sh` so after applying optional bumps it computes final `build_final` and `mv_final`, then writes them to something like `${PROJECT_TEMP_DIR}/voicemix-archive-version.env`. The existing no-GUI behavior already defaults to no bump at `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/bump-build-number.sh:50` through `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/bump-build-number.sh:72`, so the file should still be written with unchanged values.
3. Change `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh` to read that env file instead of grepping pbxproj at `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh:41` through `/Users/aaron/code/personal/Projects/voiceMix-ios/scripts/apply-archive-version-to-built-plist.sh:46`.
4. Keep both build phases where they are and keep `alwaysOutOfDate = 1` at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:159` and `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:174`.
5. Optionally declare the env file as an input and the built plist as an output. With `ENABLE_USER_SCRIPT_SANDBOXING = NO` at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:328` and `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:463`, sandbox declarations are not currently required, but they document the contract and allow re-enabling sandboxing later.

## Risks

`ENABLE_USER_SCRIPT_SANDBOXING = NO` is not the root cause. It broadens what user scripts can read/write, so the better long-term shape is explicit input/output paths with sandboxing re-enabled if Xcode permits the plist patch. For the immediate fix, leaving it `NO` is acceptable and reduces one variable.

Editing the built plist before signing is the right place to patch archive metadata. The script phase appears last in both target phase lists, and Xcode code signing is after target build phases. The extension target is also an app dependency at `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:144` through `/Users/aaron/code/personal/Projects/voiceMix-ios/voiceMixer.xcodeproj/project.pbxproj:146`, so the extension gets patched before the app embeds/signs the product.
