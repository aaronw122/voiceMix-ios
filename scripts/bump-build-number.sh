#!/bin/bash
#
# Archive POST-action: optionally bump the build number and/or marketing version.
#
# Wired into the voiceMixer scheme under Archive > Post-actions. On each archive
# it asks TWO independent questions, each of which can be answered "leave it":
#
#   1. Build number  (CFBundleVersion / CURRENT_PROJECT_VERSION) — an integer
#      counter. Enter how much to add (0 = no change).
#   2. Marketing version (CFBundleShortVersionString / MARKETING_VERSION) —
#      semantic MAJOR.MINOR.PATCH. Choose None / Patch / Minor / Major.
#
# Build number: looped `agvtool next-version` (never -all) so App/Info.plist and
# MessagesExtension/Info.plist keep their literal $(CURRENT_PROJECT_VERSION).
# agvtool writes both targets, keeping app + iMessage extension in sync.
#
# Marketing version: agvtool is unreliable here (it chokes on the
# $(MARKETING_VERSION) substitution), so we edit MARKETING_VERSION directly in
# project.pbxproj — a global replace covers every target/config at once.
#
# This is a POST-action: the archive you just built keeps its current numbers;
# changes prepare the NEXT archive. Each change leaves a diff in
# project.pbxproj to commit. With no GUI (CI) both prompts default to "leave it".

set -euo pipefail

cd "${PROJECT_DIR:-${SRCROOT:-.}}" || exit 0

PBXPROJ="voiceMixer.xcodeproj/project.pbxproj"

# --- Current values -------------------------------------------------------
build_current=$(xcrun agvtool what-version -terse 2>/dev/null || echo "?")
mv_current=$(grep -m1 -oE 'MARKETING_VERSION = [^;]+;' "$PBXPROJ" 2>/dev/null \
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

# --- Prompt 1: build number ----------------------------------------------
bump=$(osascript <<OSA 2>/dev/null || echo 0
try
	set dlg to display dialog "Build number (currently ${build_current}). Increment by how much? Enter 0 or click Skip to leave it." default answer "1" with title "voiceMix — build number" buttons {"Skip", "Bump"} default button "Bump"
	if button returned of dlg is "Skip" then return "0"
	return text returned of dlg
on error
	return "0"
end try
OSA
)
case "$bump" in '' | *[!0-9]*) bump=0 ;; esac

# --- Prompt 2: marketing version -----------------------------------------
mv_choice=$(osascript <<OSA 2>/dev/null || echo "None"
try
	set opts to {"None (keep ${mv_current})", "Patch -> ${next_patch}", "Minor -> ${next_minor}", "Major -> ${next_major}"}
	set sel to choose from list opts with title "voiceMix — marketing version" with prompt "Marketing version is ${mv_current}. Bump it?" default items {"None (keep ${mv_current})"}
	if sel is false then return "None"
	return item 1 of sel
on error
	return "None"
end try
OSA
)

mv_new=""
case "$mv_choice" in
	Patch*) mv_new="$next_patch" ;;
	Minor*) mv_new="$next_minor" ;;
	Major*) mv_new="$next_major" ;;
esac

# --- Apply ----------------------------------------------------------------
if [ "$bump" -gt 0 ]; then
	i=0
	while [ "$i" -lt "$bump" ]; do
		xcrun agvtool next-version
		i=$((i + 1))
	done
	echo "voiceMix: build number bumped by ${bump} (now $(xcrun agvtool what-version -terse 2>/dev/null))."
else
	echo "voiceMix: build number unchanged (still ${build_current})."
fi

if [ -n "$mv_new" ]; then
	sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${mv_new};/g" "$PBXPROJ"
	echo "voiceMix: marketing version ${mv_current} -> ${mv_new}."
else
	echo "voiceMix: marketing version unchanged (still ${mv_current})."
fi
