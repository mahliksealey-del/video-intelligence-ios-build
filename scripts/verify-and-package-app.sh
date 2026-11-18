#!/bin/bash
set -euo pipefail

APP_PATH="${1:?usage: verify-and-package-app.sh path/to/App.app output.ipa}"
OUTPUT_IPA="${2:?missing output IPA path}"
EXPECTED_BUNDLE_ID='com.example.videointelligence.nativeprototype'
EXPECTED_EXECUTABLE='VideoIntelligence'

test -d "$APP_PATH"
PLIST="$APP_PATH/Info.plist"
BINARY="$APP_PATH/$EXPECTED_EXECUTABLE"
test -f "$PLIST"
test -f "$BINARY"

file "$BINARY" | grep -Fq 'Mach-O 64-bit executable arm64'
test "$(lipo -archs "$BINARY")" = 'arm64'
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "$EXPECTED_BUNDLE_ID"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" = "$EXPECTED_EXECUTABLE"
test "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")" = '16.0'

if [[ -e "$APP_PATH/embedded.mobileprovision" ]]; then
  echo 'Unexpected provisioning profile found.' >&2
  exit 1
fi
if find "$APP_PATH" -type d -name _CodeSignature -print -quit | grep -q .; then
  echo 'Unexpected code-signature directory found.' >&2
  exit 1
fi
if /usr/bin/codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
  echo 'Application unexpectedly has a valid signature.' >&2
  exit 1
fi
if /usr/bin/codesign -d "$APP_PATH" 2>/dev/null; then
  echo 'Application unexpectedly contains signing information.' >&2
  exit 1
fi

while IFS= read -r bundle; do
  if /usr/bin/codesign -d "$bundle" 2>/dev/null; then
    echo "Embedded code is unexpectedly signed: $bundle" >&2
    exit 1
  fi
done < <(find "$APP_PATH" \( -type d \( -name '*.framework' -o -name '*.appex' \) -o -type f -name '*.dylib' \) -print)

if find "$APP_PATH" \( \
  -name '*.mlmodel' -o -name '*.mlmodelc' -o -name '*.onnx' -o \
  -name '*.safetensors' -o -name '*.gguf' -o -name '*.mp3' -o \
  -name '*.m4a' -o -name '*.wav' -o -name '*.mov' -o -name '*.mp4' \
\) -print -quit | grep -q .; then
  echo 'Unexpected model weight or private-media-like file found in application bundle.' >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/Payload"
cp -R "$APP_PATH" "$WORK_DIR/Payload/"
(
  cd "$WORK_DIR"
  /usr/bin/zip -qry "$OUTPUT_IPA" Payload
)
test -s "$OUTPUT_IPA"
/usr/bin/unzip -Z1 "$OUTPUT_IPA" | grep -Fxq 'Payload/VideoIntelligence.app/'
echo "Created verified unsigned signing input: $OUTPUT_IPA"
