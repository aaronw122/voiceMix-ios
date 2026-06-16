# Version bump investigation

## Finding

The reproduced root cause is credible and matches the repo state.

The archive pre-action is wired correctly in `voiceMixer.xcodeproj/xcshareddata/xcschemes/voiceMixer.xcscheme` under `ArchiveAction > PreActions`, and it runs `scripts/bump-build-number.sh` with build settings from the `voiceMixer` target. The source plists also use build-setting substitution exactly as described:

- `App/Info.plist`: `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`, `CFBundleShortVersionString = $(MARKETING_VERSION)`
- `MessagesExtension/Info.plist`: same substitutions

The project now has `CURRENT_PROJECT_VERSION = 2` and `MARKETING_VERSION = 1.0`, proving the pre-action edited `project.pbxproj`. If the produced archive still showed `1.0 (1)`, then Xcode had already resolved the build settings for the archive before re-reading the on-disk project mutation. In other words: the pre-action is not a reliable point to mutate project build settings for the archive currently being produced.

## Recommendation

Use a two-stage archive flow:

1. Keep the interactive `osascript` UX in the Archive pre-action.
2. Have the pre-action write the final selected values to a per-archive env file under `$(PROJECT_TEMP_DIR)`.
3. Keep the source project bump for persistence/future builds.
4. Add a final Run Script build phase to both app targets that runs only for archive/install builds, reads the env file, and patches the already-processed bundle `Info.plist` at:

   ```sh
   "${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
   ```

This is more robust than relying on Xcode to re-resolve build settings mid-archive. The build phase mutates the actual product artifact after `ProcessInfoPlistFile` has expanded substitutions and before code signing seals the bundle. Run Script build phases execute before the target's code signing step, so patching the processed plist here should not invalidate the signature.

For this app specifically:

- Add the phase to `voiceMixerMessages` after `Resources`.
- Add the phase to `voiceMixer` after `Embed Foundation Extensions`.
- The extension target will patch/sign its own `.appex` before the app target embeds it.
- The app target will patch its own app plist after embedding the extension and before app signing.

This avoids App Store Connect build-number mismatch because both targets read the same chosen env file.

## Concrete implementation

### 1. Update the pre-action script

Modify `scripts/bump-build-number.sh` so it always writes an archive version env file. Use `PROJECT_TEMP_DIR` first because the pre-action has build settings from the app target; fall back to `TMPDIR` for safety.

Add near the top, after `PBXPROJ=...`:

```sh
VERSION_FILE="${PROJECT_TEMP_DIR:-${TMPDIR:-/tmp}}/voicemix-archive-version.env"
```

After applying the build and marketing changes, compute the final values and write:

```sh
build_final=$(xcrun agvtool what-version -terse 2>/dev/null || echo "$build_current")
mv_final="$mv_current"
if [ -n "$mv_new" ]; then
	mv_final="$mv_new"
fi

mkdir -p "$(dirname "$VERSION_FILE")"
cat > "$VERSION_FILE" <<EOF
VOICE_MIX_ARCHIVE_VERSION_FILE=1
VOICE_MIX_PROJECT_DIR=${PROJECT_DIR:-${SRCROOT:-}}
VOICE_MIX_BUILD_VERSION=$build_final
VOICE_MIX_MARKETING_VERSION=$mv_final
EOF

echo "voiceMix: wrote archive version choices to ${VERSION_FILE}."
```

Important behavior:

- If GUI prompts fail in CI/headless `xcodebuild`, the existing script already defaults to build bump `0` and marketing `None`; this file will contain the unchanged current values.
- If a build phase cannot find the file, it should no-op rather than fail. That lets non-scheme builds and normal Debug builds keep working.
- Keep avoiding `agvtool -all`; the current `agvtool next-version` loop preserves `$(CURRENT_PROJECT_VERSION)` in both source plists.

### 2. Add a build-phase script file

Create `scripts/apply-archive-version-to-built-plist.sh`:

```sh
#!/bin/bash
set -euo pipefail

if [ "${ACTION:-}" != "install" ]; then
	exit 0
fi

VERSION_FILE="${PROJECT_TEMP_DIR:-${TMPDIR:-/tmp}}/voicemix-archive-version.env"
if [ ! -f "$VERSION_FILE" ]; then
	echo "voiceMix: no archive version file at ${VERSION_FILE}; leaving ${TARGET_NAME:-target} Info.plist unchanged."
	exit 0
fi

# shellcheck disable=SC1090
. "$VERSION_FILE"

if [ "${VOICE_MIX_ARCHIVE_VERSION_FILE:-}" != "1" ]; then
	echo "voiceMix: ignoring malformed archive version file: ${VERSION_FILE}"
	exit 0
fi

build_version="${VOICE_MIX_BUILD_VERSION:-}"
marketing_version="${VOICE_MIX_MARKETING_VERSION:-}"

if [ -z "$build_version" ] && [ -z "$marketing_version" ]; then
	echo "voiceMix: archive version file had no values; leaving ${TARGET_NAME:-target} Info.plist unchanged."
	exit 0
fi

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$plist" ]; then
	echo "voiceMix: built Info.plist not found at ${plist}" >&2
	exit 1
fi

plistbuddy=/usr/libexec/PlistBuddy

if [ -n "$build_version" ]; then
	"$plistbuddy" -c "Set :CFBundleVersion ${build_version}" "$plist"
fi

if [ -n "$marketing_version" ]; then
	"$plistbuddy" -c "Set :CFBundleShortVersionString ${marketing_version}" "$plist"
fi

echo "voiceMix: patched ${TARGET_NAME:-target} Info.plist to ${marketing_version:-unchanged} (${build_version:-unchanged})."
```

Make it executable:

```sh
chmod +x scripts/apply-archive-version-to-built-plist.sh
```

### 3. Add the Run Script build phase in Xcode

Do this for both targets:

- `voiceMixerMessages`
- `voiceMixer`

Xcode UI steps:

1. Select the project.
2. Select target `voiceMixerMessages`.
3. Open `Build Phases`.
4. Add `New Run Script Phase`.
5. Name it `Apply Archive Version to Built Info.plist`.
6. Move it to the bottom, after `Resources`.
7. Shell: `/bin/sh`
8. Script:

   ```sh
   "${PROJECT_DIR}/scripts/apply-archive-version-to-built-plist.sh"
   ```

9. Uncheck `Based on dependency analysis` so it runs on every archive.
10. Add Input Files:

    ```text
    $(PROJECT_TEMP_DIR)/voicemix-archive-version.env
    ```

11. Add Output Files:

    ```text
    $(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)
    ```

Repeat for target `voiceMixer`, but move the phase to the bottom after `Embed Foundation Extensions`.

The input/output declarations matter because this project has `ENABLE_USER_SCRIPT_SANDBOXING = YES`. Declaring the temp env file as an input and the built plist as an output should allow the script to read/write only the intended files. If Xcode still denies access, the fallback is to set `ENABLE_USER_SCRIPT_SANDBOXING = NO` for the app and extension targets, but I would try declared paths first.

Do not use Xcode's "Run script only when installing" checkbox as the primary guard. Keep the explicit script guard:

```sh
[ "$ACTION" = install ] || exit 0
```

That makes normal Debug/Run builds cheap and harmless even if the phase exists.

## Alternatives considered

### Wrapper before `xcodebuild`

A wrapper script that prompts first and then invokes `xcodebuild archive` would avoid the Xcode pre-action cache race, because the project file is changed before Xcode starts resolving build settings. It is robust for CLI archives but does not preserve the desired Product -> Archive UX inside Xcode unless the user stops using the menu.

### xcconfig indirection

Writing selected values to an included `.xcconfig` before archive could work only if Xcode reads that file before resolving settings. From an Archive pre-action it has the same timing risk as editing `project.pbxproj`.

### Editing source Info.plists

Do not do this. It would clobber the `$(CURRENT_PROJECT_VERSION)` / `$(MARKETING_VERSION)` substitutions and risks divergence between app and extension. It also conflicts with the explicit constraint to avoid `agvtool -all`.

## Verification plan

After adding the scripts/phases:

1. Set `CURRENT_PROJECT_VERSION = 1` in both project-level build configurations, or use the current value as the baseline.
2. Quit and reopen Xcode so the scheme and phases are definitely reloaded.
3. Product -> Archive.
4. Choose build `+1`, marketing `None`.
5. Inspect the built archive plists:

   ```sh
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' path/to/voiceMixer.xcarchive/Products/Applications/voiceMixer.app/Info.plist
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' path/to/voiceMixer.xcarchive/Products/Applications/voiceMixer.app/PlugIns/voiceMixerMessages.appex/Info.plist
   ```

Both should print the chosen final build number. Also check:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' path/to/voiceMixer.xcarchive/Products/Applications/voiceMixer.app/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' path/to/voiceMixer.xcarchive/Products/Applications/voiceMixer.app/PlugIns/voiceMixerMessages.appex/Info.plist
```

Both targets must match before upload to App Store Connect.
