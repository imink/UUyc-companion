#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/UUDisplay/UUConnectionState.swift tests/connection-main.swift -o "$TEST_DIR/connection-tests"
"$TEST_DIR/connection-tests"
swiftc Sources/UUDisplay/UUConnectionState.swift Sources/UUDisplay/UUMonitor.swift tests/monitor-main.swift -o "$TEST_DIR/monitor-tests"
"$TEST_DIR/monitor-tests"
swiftc Sources/UUDisplay/Config.swift Sources/UUDisplay/DisplaySelection.swift \
  Sources/UUDisplay/RustDeskIPC.swift Sources/UUDisplay/RustDeskMonitor.swift Sources/UUDisplay/Watchdog.swift \
  tests/rustdesk-main.swift -o "$TEST_DIR/rustdesk-tests"
"$TEST_DIR/rustdesk-tests"
swiftc Sources/UUDisplay/Config.swift Sources/UUDisplay/DisplaySelection.swift \
  Sources/UUDisplay/RustDeskIPC.swift Sources/UUDisplay/RustDeskMonitor.swift \
  Sources/UUDisplay/Coordinator.swift tests/coordinator-main.swift -o "$TEST_DIR/coordinator-tests"
"$TEST_DIR/coordinator-tests"
