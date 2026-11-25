#!/bin/bash
set -eu
cd "$(dirname "$0")"
appdir="$HOME/Applications"
mkdir -p "$appdir" "$HOME/.local/bin"
stage=$(mktemp -d "$appdir/.vd-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Virtual Display.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp vd viewer.py chrome.cjs "$bundle/Contents/Resources/"
swiftc -O Launcher.swift -o "$bundle/Contents/Resources/launcher"
clang -fobjc-arc -O2 -Wno-incompatible-pointer-types -framework Cocoa -framework ApplicationServices -framework ScreenCaptureKit -framework CoreMedia -framework CoreImage Host.m Viewer.m -o "$bundle/Contents/MacOS/Virtual Display"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.vd.host</string>
<key>CFBundleName</key><string>Virtual Display</string>
<key>CFBundleExecutable</key><string>Virtual Display</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Capture windows on the VD workspace when you request a screenshot.</string>
</dict></plist>
PLIST
fingerprint=$(./local-signing.sh)
[[ "$fingerprint" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo "No local signing identity found" >&2; exit 1; }
sign() {
    local target=$1 identifier=$2
    codesign --force --timestamp=none --sign "$fingerprint" --identifier "$identifier" \
        --requirements "=designated => identifier \"$identifier\" and certificate leaf = H\"$fingerprint\"" "$target"
}
sign "$bundle/Contents/Resources/launcher" local.vd.launcher
sign "$bundle" local.vd.host
codesign --verify --deep --strict "$bundle"
dest="$appdir/Virtual Display.app"
if [[ -e "$dest" ]]; then mv "$dest" "$stage/previous.app"; fi
if ! mv "$bundle" "$dest"; then mv "$stage/previous.app" "$dest"; exit 1; fi
ln -sfn "$dest/Contents/Resources/vd" "$HOME/.local/bin/vd"
