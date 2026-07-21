#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CHECK_BINARY="$(mktemp -d)/pole-checks"

cd "$PROJECT_DIR"
swiftc \
    -framework AppKit \
    -framework ApplicationServices \
    Sources/Pole/DoubleOptionMonitor.swift \
    Sources/Pole/QwenClient.swift \
    Sources/Pole/PromptPolicy.swift \
    Sources/Pole/TextEditing.swift \
    Checks/main.swift \
    -o "$CHECK_BINARY"
"$CHECK_BINARY"
