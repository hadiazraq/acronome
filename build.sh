#!/bin/bash
# Builds Acronome.app from source and (optionally) installs it in ~/Applications.
# Usage: ./build.sh                → build/Acronome.app
#        ./build.sh --install      → also copies it to ~/Applications and opens it
#        ./build.sh --no-medline   → skip downloading the MEDLINE (ADAM) layer
# Optional: BUNDLE_ID=com.you.acronome ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0; MEDLINE=1
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --no-medline) MEDLINE=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ $MEDLINE == 1 && ! -f Resources/data/adam.json ]]; then
  echo "› Fetching the MEDLINE abbreviation layer (one time, ~4 MB)…"
  python3 scripts/fetch_data.py || echo "  (skipped — the app works without it; run scripts/fetch_data.py later)"
fi

echo "› Compiling (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Acronome"

APP="build/Acronome.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Acronome"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${BUNDLE_ID:-}" ]]; then
  plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
fi
cp Resources/data/*.json "$APP/Contents/Resources/"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "› Signing (ad hoc)…"
codesign --force --deep --sign - "$APP"
echo "✓ Built $APP"

if [[ $INSTALL == 1 ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x Acronome 2>/dev/null || true
  rm -rf "$HOME/Applications/Acronome.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "✓ Installed to ~/Applications/Acronome.app"
  open "$HOME/Applications/Acronome.app"
fi
