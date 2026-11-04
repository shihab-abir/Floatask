#!/bin/bash
# Builds and runs the core test suite (no Xcode/SwiftPM needed).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/gen-buildinfo.sh
swiftc -swift-version 5 -target arm64-apple-macos26.0 -parse-as-library \
  Sources/TaskflowCore/*.swift Sources/TaskflowCore/AI/*.swift build/generated/BuildInfo.swift Tests/*.swift \
  -o build/core-tests
./build/core-tests
