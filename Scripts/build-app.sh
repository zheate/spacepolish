#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/dist/Pole.app"
CONTENTS_DIR="$APP_DIR/Contents"
SIGNING_IDENTITY="${POLE_CODESIGN_IDENTITY:-${SPACEPOLISH_CODESIGN_IDENTITY:-}}"

cd "$PROJECT_DIR"
swift build -c release

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/.build/release/Pole" "$CONTENTS_DIR/MacOS/Pole"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/Pole.icns" "$CONTENTS_DIR/Resources/Pole.icns"

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
            | head -n 1
    )"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    echo "未找到开发者签名证书，使用临时签名。系统更新后可能需要重新授予辅助功能权限。"
else
    echo "使用稳定签名：$SIGNING_IDENTITY"
fi

codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"

echo "$APP_DIR"
