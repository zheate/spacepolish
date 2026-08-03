#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

cd "$PROJECT_DIR"
if xcrun --find xctest >/dev/null 2>&1; then
    swift test
    exit 0
fi

print "完整 Xcode 测试运行时不可用，使用等价的独立回归入口。"
CHECK_DIRECTORY="$(mktemp -d)"
CHECK_BINARY="$CHECK_DIRECTORY/pole-checks"
CORE_SOURCES=()
for source in Sources/Pole/*.swift; do
    if [[ "${source:t}" != "main.swift" ]]; then
        CORE_SOURCES+=("$source")
    fi
done

swiftc \
    -package-name spacepolish \
    -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Vision \
    -framework Security \
    "${CORE_SOURCES[@]}" \
    Checks/PoleRegressionChecks.swift \
    Checks/StandaloneCheckMain.swift \
    -o "$CHECK_BINARY"
"$CHECK_BINARY"
