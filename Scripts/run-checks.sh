#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CHECK_BINARY="$(mktemp -d)/pole-checks"

cd "$PROJECT_DIR"
swiftc \
    -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Vision \
    -framework Security \
    Sources/Pole/DoubleOptionMonitor.swift \
    Sources/Pole/QwenClient.swift \
    Sources/Pole/KeychainStore.swift \
    Sources/Pole/ApplicationContext.swift \
    Sources/Pole/PromptPolicy.swift \
    Sources/Pole/SemanticLibrary.swift \
    Sources/Pole/CommunicationIntelligence.swift \
    Sources/Pole/ExternalConversationHelper.swift \
    Sources/Pole/RewriteGuards.swift \
    Sources/Pole/RewriteHighlightOverlay.swift \
    Sources/Pole/InputProgressIndicator.swift \
    Sources/Pole/ConversationContext.swift \
    Sources/Pole/TextEditing.swift \
    Checks/main.swift \
    -o "$CHECK_BINARY"
"$CHECK_BINARY"
