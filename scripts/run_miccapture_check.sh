#!/usr/bin/env bash
set -euo pipefail

# Compile + run the MicCapture multi-channel check against the REAL
# Sources/Tome/Audio/MicCapture.swift (plus WAVStreamWriter, which it references).
# Uses swiftc directly (the CLT toolchain that builds Tome has no XCTest).
# Exits non-zero if any check fails.

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
SWIFTC="${TOOLCHAINS_SWIFTC:-/Library/Developer/CommandLineTools/usr/bin/swiftc}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
WORK="$(mktemp -d)"
OUT="$WORK/miccapturecheck"

# MicCapture imports the local ObjCExceptionGuard SPM target (the NSException
# guard around installTap). Compile its .m and synthesize a module map so the
# plain-swiftc build can `import ObjCExceptionGuard` like the app does.
GUARD_DIR="$ROOT_DIR/Tome/Sources/ObjCExceptionGuard"
cat > "$WORK/module.modulemap" <<EOF
module ObjCExceptionGuard {
    header "$GUARD_DIR/include/ObjCExceptionGuard.h"
    export *
}
EOF
xcrun clang -c -fobjc-arc -isysroot "$SDK" \
  "$GUARD_DIR/ObjCExceptionGuard.m" -I "$GUARD_DIR/include" -o "$WORK/guard.o"

"$SWIFTC" -sdk "$SDK" -O -I "$WORK" \
  Tome/Sources/Tome/Audio/MicCapture.swift \
  Tome/Sources/Tome/Recovery/WAVStreamWriter.swift \
  scripts/miccapture_check/main.swift \
  "$WORK/guard.o" \
  -o "$OUT"

"$OUT"
