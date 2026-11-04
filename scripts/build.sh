#!/bin/bash
# Builds build/Floatask.app (the app plus the `floatask` CLI inside it).
# Works with just the Xcode Command Line Tools — no Xcode project or SwiftPM needed.
#
#   scripts/build.sh           optimised build
#   scripts/build.sh --debug   faster compile, debug symbols
set -euo pipefail
cd "$(dirname "$0")/.."

OPT=(-O)
[[ "${1:-}" == "--debug" ]] && OPT=(-Onone -g)
SWIFTC=(swiftc -swift-version 5 -target arm64-apple-macos26.0)
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/Floatask.app"

scripts/gen-buildinfo.sh
CORE=(Sources/FloataskCore/*.swift Sources/FloataskCore/AI/*.swift build/generated/BuildInfo.swift)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ compiling Floatask.app ($VERSION)"
"${SWIFTC[@]}" "${OPT[@]}" -parse-as-library "${CORE[@]}" Sources/FloataskApp/*.swift \
  -o "$APP/Contents/MacOS/Floatask"

echo "→ compiling floatask CLI"
"${SWIFTC[@]}" "${OPT[@]}" "${CORE[@]}" Sources/FloataskCLI/main.swift \
  -o "$APP/Contents/MacOS/floatask-cli"

sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/LogoFrame.svg Resources/LogoWave.svg "$APP/Contents/Resources/"

# Ad-hoc signature: required to run on Apple silicon; no Apple Developer account needed.
codesign --force --deep --sign - "$APP" >/dev/null
echo "✓ built $APP"
