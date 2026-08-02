#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/dist/Pole.app"
CONTENTS_DIR="$APP_DIR/Contents"
SIGNING_IDENTITY="${POLE_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${POLE_NOTARY_PROFILE:-}"
VERSION="${POLE_VERSION:-}"
BUILD_NUMBER="${POLE_BUILD_NUMBER:-}"

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "正式发布已拒绝：工作树必须干净，先提交或移走全部改动。" >&2
    exit 1
fi
if [[ "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "正式发布已拒绝：POLE_CODESIGN_IDENTITY 必须是 Developer ID Application 证书。" >&2
    exit 1
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "正式发布已拒绝：请设置 POLE_NOTARY_PROFILE（notarytool 钥匙串配置名）。" >&2
    exit 1
fi
if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
    echo "正式发布已拒绝：请显式设置 POLE_VERSION 和 POLE_BUILD_NUMBER。" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ '^[0-9A-Za-z._-]+$' || ! "$BUILD_NUMBER" =~ '^[0-9A-Za-z._-]+$' ]]; then
    echo "正式发布已拒绝：版本号和构建号只能包含字母、数字、点、下划线或连字符。" >&2
    exit 1
fi

GIT_COMMIT="$(git rev-parse --verify HEAD)"
BUILD_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
ARCHITECTURE="$(uname -m)"
ZIP_PATH="$PROJECT_DIR/dist/Pole-$VERSION-$ARCHITECTURE.zip"

swift build -c release

rm -rf "$APP_DIR"
rm -f "$ZIP_PATH"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/.build/release/Pole" "$CONTENTS_DIR/MacOS/Pole"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/Pole.icns" "$CONTENTS_DIR/Resources/Pole.icns"
cp -R "$PROJECT_DIR/Resources/Sounds" "$CONTENTS_DIR/Resources/Sounds"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PoleBuildCommit string $GIT_COMMIT" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PoleBuildState string clean" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PoleBuildTimestamp string $BUILD_TIMESTAMP" "$CONTENTS_DIR/Info.plist"

codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
spctl --assess --type execute --verbose=2 "$APP_DIR"
shasum -a 256 "$ZIP_PATH"

echo "$ZIP_PATH"
