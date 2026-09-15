#!/bin/zsh
# Builds build/SyncSpeaker.app: release binary + web UI + Info.plist, then signs it.
#
#   SIGN_ID="Apple Development: you@example.com (TEAMID)" scripts/build-app.sh
#
# Without SIGN_ID the app is ad-hoc signed. That works, but macOS privacy grants (System Audio
# Recording, Microphone, Automation) are tied to the signature and must be re-approved after each build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/SyncSpeaker.app
SUPPORT=Apps/Mac/Support

if command -v npm >/dev/null; then
  (cd web && npm install --no-audit --no-fund && npm run build)
else
  echo "npm not found; using existing web/dist" >&2
fi
[[ -f web/dist/index.html ]] || { echo "web/dist is missing; install Node and rerun" >&2; exit 1; }

swift build -c release --product SyncSpeaker
BIN="$(swift build -c release --show-bin-path)/SyncSpeaker"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SyncSpeaker"
cp "$SUPPORT/Info.plist" "$APP/Contents/Info.plist"
cp -R web/dist "$APP/Contents/Resources/web"

sign_args=(--force --sign "${SIGN_ID:--}" --entitlements "$SUPPORT/SyncSpeaker.entitlements")
[[ -n "${SIGN_ID:-}" ]] && sign_args+=(--options runtime)
codesign "${sign_args[@]}" "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $APP"
