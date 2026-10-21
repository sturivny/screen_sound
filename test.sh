#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx15.0 -sdk "$(xcrun --show-sdk-path)" \
  -module-cache-path "$PWD/build/module-cache" \
  Sources/RecordingSink.swift Tests/MediaIntegration.swift -o build/MediaIntegration
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ScreenSound-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
build/MediaIntegration "$TEST_DIR"
