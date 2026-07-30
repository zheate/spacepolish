#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
EVALUATION_DIR="$(mktemp -d)"
EVALUATION_BINARY="$EVALUATION_DIR/pole-quality-evaluation"

cd "$PROJECT_DIR"
swiftc \
    -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Vision \
    -framework Security \
    Sources/Pole/QwenClient.swift \
    Sources/Pole/KeychainStore.swift \
    Sources/Pole/ApplicationContext.swift \
    Sources/Pole/PromptPolicy.swift \
    Sources/Pole/SemanticLibrary.swift \
    Sources/Pole/CommunicationIntelligence.swift \
    Sources/Pole/ExternalConversationHelper.swift \
    Sources/Pole/RewriteGuards.swift \
    Sources/Pole/ConversationContext.swift \
    Checks/RewriteQualityCorpus.swift \
    Checks/QualityEvaluationMain.swift \
    -o "$EVALUATION_BINARY"

"$EVALUATION_BINARY" "${1:-40}"
