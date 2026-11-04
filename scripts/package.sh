#!/bin/bash
# Builds a release and zips it for GitHub Releases:
#   dist/Floatask-<version>-macos-arm64.zip  (+ .sha256)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
scripts/build.sh

mkdir -p dist
ZIP="dist/Floatask-$VERSION-macos-arm64.zip"
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps the bundle's symlinks, permissions and signature intact.
ditto -c -k --sequesterRsrc --keepParent build/Floatask.app "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "✓ $ZIP"
cat "$ZIP.sha256"
