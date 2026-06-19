#!/bin/bash
#
# Archive helper — bump the version (optional), then build the archive.
#
# Run this INSTEAD of Xcode's Product → Archive when you want to bump the
# version, e.g.  ./scripts/archive.sh
#
# Why a CLI wrapper and not an Xcode Archive pre-action: in Xcode 26.3 the
# Archive pre-action runs in parallel with (effectively AFTER) the build — the
# build races ahead while the prompt is still open — so a pre-action bump never
# lands in the archive being produced. Bumping here, BEFORE xcodebuild starts,
# guarantees the chosen numbers are baked into this archive. Both targets read
# $(CURRENT_PROJECT_VERSION) / $(MARKETING_VERSION), so the app and the iMessage
# extension stay in lockstep automatically.
#
# Build number  : looped `agvtool next-version` (never -all, which would clobber
#                 the $(CURRENT_PROJECT_VERSION) substitution in the source plists).
# Marketing ver : edited straight in project.pbxproj (agvtool chokes on the
#                 $(MARKETING_VERSION) substitution).
#
# Set VM_DRY_RUN=1 to walk the prompts and print what WOULD happen without
# touching the project or running xcodebuild.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

PROJECT="voiceMixer.xcodeproj"
SCHEME="voiceMixer"
PBXPROJ="${PROJECT}/project.pbxproj"
DRY_RUN="${VM_DRY_RUN:-0}"

# --- Current values -------------------------------------------------------
build_current=$(xcrun agvtool what-version -terse 2>/dev/null || echo "?")
mv_current=$(grep -m1 -oE 'MARKETING_VERSION = [^;]+;' "$PBXPROJ" \
	| sed -E 's/MARKETING_VERSION = (.*);/\1/' || echo "")
[ -z "$mv_current" ] && mv_current="0.0.0"

# Parse marketing version into MAJOR.MINOR.PATCH, defaulting missing parts to 0.
IFS='.' read -r MA MI PA <<<"$mv_current"
MA=${MA:-0}; MI=${MI:-0}; PA=${PA:-0}
case "$MA" in *[!0-9]*) MA=0 ;; esac
case "$MI" in *[!0-9]*) MI=0 ;; esac
case "$PA" in *[!0-9]*) PA=0 ;; esac
next_patch="$MA.$MI.$((PA + 1))"
next_minor="$MA.$((MI + 1)).0"
next_major="$((MA + 1)).0.0"

echo "voiceMix archive — current version ${mv_current} (${build_current})"
echo

# --- Prompt 1: build number ----------------------------------------------
read -r -p "Bump build number by how much? (0 to keep ${build_current}) [1]: " bump
bump="${bump:-1}"
case "$bump" in '' | *[!0-9]*) bump=0 ;; esac

# --- Prompt 2: marketing version -----------------------------------------
echo "Marketing version (currently ${mv_current}):"
echo "  0) None   1) Patch → ${next_patch}   2) Minor → ${next_minor}   3) Major → ${next_major}"
read -r -p "Choose [0]: " mv_choice
mv_new=""
case "${mv_choice:-0}" in
	1) mv_new="$next_patch" ;;
	2) mv_new="$next_minor" ;;
	3) mv_new="$next_major" ;;
esac

# --- Apply the bump BEFORE building --------------------------------------
if [ "$DRY_RUN" = "1" ]; then
	echo
	echo "[dry-run] would bump build by ${bump} and marketing to '${mv_new:-unchanged}'"
	final_build=$((build_current + bump))
	echo "[dry-run] would archive ${mv_new:-$mv_current} (${final_build}) via:"
	echo "          xcodebuild archive -project ${PROJECT} -scheme ${SCHEME} -configuration Release"
	exit 0
fi

if [ "$bump" -gt 0 ]; then
	i=0
	while [ "$i" -lt "$bump" ]; do
		xcrun agvtool next-version >/dev/null
		i=$((i + 1))
	done
	echo "→ build number ${build_current} → $(xcrun agvtool what-version -terse)"
else
	echo "→ build number unchanged (${build_current})"
fi

if [ -n "$mv_new" ]; then
	sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${mv_new};/g" "$PBXPROJ"
	echo "→ marketing ${mv_current} → ${mv_new}"
else
	echo "→ marketing unchanged (${mv_current})"
fi

build_final=$(xcrun agvtool what-version -terse 2>/dev/null)
mv_final="${mv_new:-$mv_current}"

# --- Archive --------------------------------------------------------------
day=$(date +%Y-%m-%d)
clock=$(date +%H.%M)
archive_dir="${HOME}/Library/Developer/Xcode/Archives/${day}"
mkdir -p "$archive_dir"
archive_path="${archive_dir}/voiceMixer ${mv_final} (${build_final}) ${clock}.xcarchive"

echo
echo "→ archiving ${mv_final} (${build_final}) …"
xcodebuild archive \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$archive_path" \
	-allowProvisioningUpdates

echo
echo "✅ Archived ${mv_final} (${build_final}) — app + iMessage extension in sync."
echo "   ${archive_path}"
echo "   Open Xcode → Window → Organizer to Validate / Distribute."
