#!/bin/bash
# Builds build/Taskflow.app (the app plus the `taskflow` CLI inside it).
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
APP="build/Taskflow.app"

scripts/gen-buildinfo.sh
CORE=(Sources/TaskflowCore/*.swift Sources/TaskflowCore/AI/*.swift build/generated/BuildInfo.swift)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ compiling Taskflow.app ($VERSION)"
"${SWIFTC[@]}" "${OPT[@]}" -parse-as-library "${CORE[@]}" Sources/TaskflowApp/*.swift \
  -o "$APP/Contents/MacOS/Taskflow"

echo "→ compiling taskflow CLI"
"${SWIFTC[@]}" "${OPT[@]}" "${CORE[@]}" Sources/TaskflowCLI/main.swift \
  -o "$APP/Contents/MacOS/taskflow-cli"

sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc signature: required to run on Apple silicon; no Apple Developer account needed.
codesign --force --deep --sign - "$APP" >/dev/null
echo "✓ built $APP"
