#!/usr/bin/env bash
#
# check-release-zip.sh - Check that a zip holds the notarized Histq release build.
#
# scripts/publish-release.sh and scripts/publish-appcast.sh run it before they publish a zip, so a
# stale, pre-staple or foreign zip is never uploaded or EdDSA-signed into the appcast. It only
# reads the zip: it unpacks it into a temp dir (removed on exit) and checks that:
#   - the zip holds exactly one Histq.app at its top level
#   - the app has its notarization ticket stapled (xcrun stapler validate)
#   - the app's signature verifies (codesign --verify --strict --deep)
#   - the app's TeamIdentifier is TEAM_ID (default 86H6CNLN4C)
#   - the app's CFBundleShortVersionString is the given version
#
# Usage:
#   scripts/check-release-zip.sh release/export/Histq-1.0.0.zip 1.0.0
#   TEAM_ID=ABCDE12345 scripts/check-release-zip.sh <zip> <X.Y.Z>
#
set -euo pipefail

TEAM_ID="${TEAM_ID:-86H6CNLN4C}"

[[ $# -eq 2 && -n "$1" && -n "$2" ]] \
  || { echo "usage: scripts/check-release-zip.sh <zip> <X.Y.Z>" >&2; exit 1; }
ZIP="$1"
VERSION="$2"
[[ -f "$ZIP" ]] || { echo "error: zip not found: $ZIP" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP" \
  || { echo "error: cannot unzip $ZIP" >&2; exit 1; }

# Exactly one top-level entry, and it is Histq.app (ditto -c -k --keepParent Histq.app).
TOP="$(ls -A "$TMP" | tr '\n' ' ' | sed 's/ $//')"
[[ "$TOP" == "Histq.app" && -d "$TMP/Histq.app" ]] \
  || { echo "error: $ZIP must hold exactly one Histq.app at its top level (found: ${TOP:-nothing})" >&2; exit 1; }
APP="$TMP/Histq.app"

xcrun stapler validate "$APP" \
  || { echo "error: Histq.app in $ZIP has no valid stapled notarization ticket - not the notarized build" >&2; exit 1; }
codesign --verify --strict --deep "$APP" \
  || { echo "error: Histq.app in $ZIP fails codesign --verify --strict --deep" >&2; exit 1; }
# codesign -dv writes to stderr; capture it first (grep in a pipe trips pipefail).
SIGN_INFO="$(codesign -dv "$APP" 2>&1 || true)"
APP_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGN_INFO" | head -1)"
[[ "$APP_TEAM" == "$TEAM_ID" ]] \
  || { echo "error: Histq.app in $ZIP is signed by team '${APP_TEAM:-none}', expected '$TEAM_ID'" >&2; exit 1; }
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$APP_VERSION" == "$VERSION" ]] \
  || { echo "error: Histq.app in $ZIP is version '${APP_VERSION:-unknown}', expected '$VERSION'" >&2; exit 1; }

echo "==> $ZIP is the notarized Histq $VERSION (team $TEAM_ID)"
