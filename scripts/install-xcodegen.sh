#!/bin/bash
set -euo pipefail

VERSION='2.47.0'
EXPECTED_SHA256='6ef12a3ef5327c2c713397f46d9160550f8b1cdc5c925cd884d65c77c9f696cd'
ARCHIVE="$RUNNER_TEMP/xcodegen-$VERSION.zip"
INSTALL_ROOT="$RUNNER_TEMP/xcodegen-$VERSION"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"

curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$ARCHIVE" "$URL"
echo "$EXPECTED_SHA256  $ARCHIVE" | shasum -a 256 --check
mkdir -p "$INSTALL_ROOT"
/usr/bin/unzip -q "$ARCHIVE" -d "$INSTALL_ROOT"
test -x "$INSTALL_ROOT/xcodegen/bin/xcodegen"
echo "$INSTALL_ROOT/xcodegen/bin" >> "$GITHUB_PATH"
"$INSTALL_ROOT/xcodegen/bin/xcodegen" --version | grep -Fx "Version: $VERSION"
