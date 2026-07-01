#!/usr/bin/env bash
set -euo pipefail

# Build an INSTRUMENTED Tome.app for crash diagnosis.
#
# Adds, on top of the normal signed build:
#   • -enable-actor-data-race-checks — traps at the exact main-actor / executor
#     isolation violation instead of corrupting memory and dying later inside an
#     Apple framework. This directly targets the `swift_task_isCurrentExecutor`
#     SIGBUS seen on 2026-07-01 (DesignLibrary → ZStack render).
#   • -g — full debug info so the captured backtrace symbolicates cleanly.
#
# The app also installs CrashBreadcrumb (App/CrashBreadcrumb.swift) at launch,
# which writes the faulting backtrace to:
#   ~/Library/Application Support/Tome/last-crash.log
# and to the unified log (subsystem com.dloomis.tome, category "crash").
#
# Usage:
#   ./scripts/build_instrumented.sh
# then launch dist/Tome.app. After any crash:
#   cat "$HOME/Library/Application Support/Tome/last-crash.log"
#   log show --predicate 'subsystem == "com.dloomis.tome"' --info --last 30m

cd "$(dirname "$0")/.."

echo "=== Building INSTRUMENTED Tome (actor-data-race checks + crash breadcrumbs) ==="
EXTRA_SWIFT_BUILD_FLAGS="-Xswiftc -enable-actor-data-race-checks -Xswiftc -g" \
  ./scripts/build_swift_app.sh

echo
echo "Instrumented Tome.app built at dist/Tome.app"
echo "After a crash, read:  \$HOME/Library/Application Support/Tome/last-crash.log"
