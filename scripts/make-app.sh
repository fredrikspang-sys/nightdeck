#!/bin/bash
# Build a release Nightdeck.app with ad-hoc signature. No Xcode, no install.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release -Xswiftc -Osize -Xlinker -dead_strip --disable-sandbox

BIN=""
for candidate in \
    ".build/release/Nightdeck" \
    ".build/arm64-apple-macosx/release/Nightdeck" \
    ".build/out/Products/Release/Nightdeck"
do
    if [[ -x "$candidate" ]]; then
        BIN="$candidate"
        break
    fi
done
if [[ -z "$BIN" ]]; then
    echo "release binary not found" >&2
    exit 1
fi

APP="build/Nightdeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nightdeck"
cp "scripts/Info.plist" "$APP/Contents/Info.plist"
swift "scripts/make-icon.swift" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/Nightdeck"
codesign -s - --force "$APP"

echo "Built $APP"
du -sh "$APP"
stat -f '%z bytes' "$APP/Contents/MacOS/Nightdeck"
