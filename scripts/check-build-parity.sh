#!/usr/bin/env bash
#
# check-build-parity.sh - Check that a Debug and a Release Histq.app are signed and configured alike.
#
# Debug is Developer ID-signed like Release, so Keychain items and macOS grants made by one are
# trusted by the other. This script checks that this still holds. It only reads the two apps:
#   - codesign: Identifier, TeamIdentifier, the first Authority line and the hardened runtime flag
#   - the entitlements, after removing the keys Xcode injects into Debug builds
#     (com.apple.security.get-task-allow and every com.apple.security.temporary-exception.*)
#   - the designated requirements, cross-checked both ways (each app must satisfy the other's DR;
#     Keychain access rests on it, and Xcode and the export write the DR differently)
#   - Info.plist keys CFBundleIdentifier, CFBundleShortVersionString, CFBundleVersion,
#     LSMinimumSystemVersion, SUFeedURL, SUPublicEDKey, HistqGitHubClientID
# It prints every mismatch and exits 1, else prints "PARITY OK".
#
# The local Release build is not the notarized export that ships; the export can be checked the
# same way once a release exists (release/export/Histq.app).
#
# Usage:
#   scripts/check-build-parity.sh <debug Histq.app> <release Histq.app>
#
set -euo pipefail

[[ $# -eq 2 && -n "$1" && -n "$2" ]] \
  || { echo "usage: scripts/check-build-parity.sh <debug.app> <release.app>" >&2; exit 1; }
D="$1"
R="$2"
for app in "$D" "$R"; do
  [[ -f "$app/Contents/Info.plist" ]] || { echo "error: not an app bundle: $app" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
mismatch() { echo "MISMATCH $*"; FAILS=$((FAILS + 1)); }

# compare <what> <debug value> <release value>
compare() {
  [[ "$2" == "$3" ]] || mismatch "$1: debug='$2' release='$3'"
}

# --- codesign fields ---------------------------------------------------------
codesign -dv --verbose=2 "$D" > "$TMP/d.sig" 2>&1 || mismatch "codesign -dv failed on debug: $(tail -1 "$TMP/d.sig")"
codesign -dv --verbose=2 "$R" > "$TMP/r.sig" 2>&1 || mismatch "codesign -dv failed on release: $(tail -1 "$TMP/r.sig")"

# sig_field <file> <field>: the first "<field>=" line's value.
sig_field() { sed -n "s/^$2=//p" "$1" | head -1; }
# runtime_flag <file>: "yes" when the CodeDirectory flags include runtime.
runtime_flag() { if grep -q '^CodeDirectory .*flags=0x[0-9a-f]*([^)]*runtime' "$1"; then echo yes; else echo no; fi; }

for field in Identifier TeamIdentifier Authority; do
  compare "$field" "$(sig_field "$TMP/d.sig" "$field")" "$(sig_field "$TMP/r.sig" "$field")"
done
compare "hardened runtime" "$(runtime_flag "$TMP/d.sig")" "$(runtime_flag "$TMP/r.sig")"

# --- entitlements ------------------------------------------------------------
# entitlements <app> <out.plist>: the app's entitlements as sorted XML, without the Debug-only keys.
entitlements() {
  local raw="$2.raw" key
  if ! codesign -d --entitlements - --xml "$1" > "$raw" 2> "$2.err"; then
    echo "<codesign failed: $(tail -1 "$2.err")>" > "$2"
    return
  fi
  if [[ -s "$raw" ]]; then
    plutil -convert xml1 -o "$2" "$raw" > "$2.err" 2>&1 \
      || { echo "<unreadable entitlements: $(tail -1 "$2.err")>" > "$2"; return; }
  else
    plutil -create xml1 "$2"
  fi
  # plutil writes top-level keys with exactly one tab of indentation.
  while IFS= read -r key; do
    case "$key" in
      com.apple.security.get-task-allow | com.apple.security.temporary-exception.*)
        /usr/libexec/PlistBuddy -c "Delete :$key" "$2" > /dev/null 2>&1 \
          || { echo "<cannot remove $key>" > "$2"; return; } ;;
    esac
  done < <(sed -n $'s/^\t<key>\\(.*\\)<\\/key>$/\\1/p' "$2")
  plutil -convert xml1 "$2"
}
entitlements "$D" "$TMP/d.ent"
entitlements "$R" "$TMP/r.ent"
if ! diff -u "$TMP/d.ent" "$TMP/r.ent" > "$TMP/ent.diff"; then
  mismatch "entitlements (without get-task-allow and temporary-exception.*), debug vs release:"
  sed -n '3,$p' "$TMP/ent.diff"
fi

# --- designated requirements, cross-checked ----------------------------------
# dr_check <name of the DR's app> <app with the DR> <name of the checked app> <checked app>
dr_check() {
  local dr
  dr="$(codesign -d -r- "$2" 2>&1 | sed -n 's/^designated => //p')" || true
  if [[ -z "$dr" ]]; then
    mismatch "designated requirement: $1 has none"
  elif ! codesign -v -R="$dr" "$4" > "$TMP/dr.out" 2>&1; then
    mismatch "designated requirement: $3 does not satisfy $1's DR: $(head -1 "$TMP/dr.out")"
  fi
}
dr_check release "$R" debug "$D"
dr_check debug "$D" release "$R"

# --- Info.plist keys ---------------------------------------------------------
# plist_value <app> <key>: the key's value, or "<missing>".
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2> /dev/null || echo "<missing>"
}
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion \
  SUFeedURL SUPublicEDKey HistqGitHubClientID; do
  compare "Info.plist $key" "$(plist_value "$D" "$key")" "$(plist_value "$R" "$key")"
done

if [[ $FAILS -gt 0 ]]; then
  echo "PARITY FAILED: $FAILS mismatch(es)"
  exit 1
fi
echo "PARITY OK"
