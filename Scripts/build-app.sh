#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/dist/Pole.app"
CONTENTS_DIR="$APP_DIR/Contents"
SIGNING_IDENTITY="${POLE_CODESIGN_IDENTITY:-${SPACEPOLISH_CODESIGN_IDENTITY:-}}"

cd "$PROJECT_DIR"
GIT_COMMIT="$(git rev-parse --verify HEAD 2>/dev/null || true)"
if [[ -z "$GIT_COMMIT" ]]; then
    GIT_COMMIT="unknown"
fi
BUILD_STATE="clean"
if [[ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
    BUILD_STATE="dirty"
fi
BUILD_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

swift build -c release --product Pole

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/.build/release/Pole" "$CONTENTS_DIR/MacOS/Pole"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/Pole.icns" "$CONTENTS_DIR/Resources/Pole.icns"
cp -R "$PROJECT_DIR/Resources/Sounds" "$CONTENTS_DIR/Resources/Sounds"
/usr/libexec/PlistBuddy -c "Add :PoleBuildCommit string $GIT_COMMIT" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PoleBuildState string $BUILD_STATE" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PoleBuildTimestamp string $BUILD_TIMESTAMP" "$CONTENTS_DIR/Info.plist"

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
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
APP_CDHASH="$(
    codesign -dv --verbose=4 "$APP_DIR" 2>&1 \
        | sed -n 's/^CDHash=//p' \
        | head -n 1
)"

echo "$APP_DIR · commit $GIT_COMMIT · $BUILD_STATE · cdhash $APP_CDHASH"
