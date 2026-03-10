#!/bin/zsh
# start_amfidont_for_vphone.sh — Start amfidont for the current vphone build.
#
# This is the README "Option 2" host workaround packaged for this repo:
# - computes the signed release binary CDHash
# - uses the URL-encoded project path form observed by AMFIPathValidator
# - starts amfidont in daemon mode so signed vphone-cli launches are allowlisted

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
RELEASE_BIN="${PROJECT_ROOT}/.build/release/vphone-cli"
AMFIDONT_BIN="${HOME}/Library/Python/3.9/bin/amfidont"

[[ -x "$AMFIDONT_BIN" ]] || {
  echo "amfidont not found at $AMFIDONT_BIN" >&2
  echo "Install it first: xcrun python3 -m pip install --user amfidont" >&2
  exit 1
}

[[ -x "$RELEASE_BIN" ]] || {
  echo "Missing release binary: $RELEASE_BIN" >&2
  echo "Run 'make build' first." >&2
  exit 1
}

CDHASH="$(
  codesign -dv --verbose=4 "$RELEASE_BIN" 2>&1 \
    | sed -n 's/^CDHash=//p' \
    | head -n1
)"
[[ -n "$CDHASH" ]] || {
  echo "Failed to extract CDHash for $RELEASE_BIN" >&2
  exit 1
}

ENCODED_PROJECT_ROOT="${PROJECT_ROOT// /%20}"

echo "[*] Project root:      $PROJECT_ROOT"
echo "[*] Encoded AMFI path: $ENCODED_PROJECT_ROOT"
echo "[*] Release CDHash:    $CDHASH"

exec sudo "$AMFIDONT_BIN" daemon \
  --path "$ENCODED_PROJECT_ROOT" \
  --cdhash "$CDHASH" \
  --verbose
