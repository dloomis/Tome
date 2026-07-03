#!/usr/bin/env bash
set -euo pipefail

# Compile + run the MicCapture multi-channel check against the REAL
# Sources/Tome/Audio/MicCapture.swift (plus WAVStreamWriter, which it references).
# Uses swiftc directly (the CLT toolchain that builds Tome has no XCTest).
# Exits non-zero if any check fails.

cd "$(dirname "$0")/.."
SWIFTC="${TOOLCHAINS_SWIFTC:-/Library/Developer/CommandLineTools/usr/bin/swiftc}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="$(mktemp -d)/miccapturecheck"

"$SWIFTC" -sdk "$SDK" -O \
  Tome/Sources/Tome/Audio/MicCapture.swift \
  Tome/Sources/Tome/Recovery/WAVStreamWriter.swift \
  scripts/miccapture_check/main.swift \
  -o "$OUT"

"$OUT"
