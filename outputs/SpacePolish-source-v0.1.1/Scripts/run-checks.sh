#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CHECK_BINARY="$(mktemp -d)/spacepolish-checks"

cd "$PROJECT_DIR"
swiftc \
    -framework ApplicationServices \
    Sources/SpacePolish/TextEditing.swift \
    Checks/main.swift \
    -o "$CHECK_BINARY"
"$CHECK_BINARY"
