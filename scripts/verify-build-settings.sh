#!/bin/bash
set -euo pipefail

PROJECT_PATH="${1:?usage: verify-build-settings.sh project.xcodeproj app-target output.json}"
APP_TARGET="${2:?missing app target}"
OUTPUT_JSON="${3:?missing output path}"

mkdir -p "$(dirname "$OUTPUT_JSON")"
APP_JSON="$(mktemp)"
TEST_JSON="$(mktemp)"
trap 'rm -f "$APP_JSON" "$TEST_JSON"' EXIT

xcodebuild \
  -project "$PROJECT_PATH" \
  -target "$APP_TARGET" \
  -configuration Debug \
  -showBuildSettings \
  -json > "$APP_JSON"
xcodebuild \
  -project "$PROJECT_PATH" \
  -target VideoIntelligenceNativeTests \
  -configuration Debug \
  -showBuildSettings \
  -json > "$TEST_JSON"
jq -s 'add' "$APP_JSON" "$TEST_JSON" > "$OUTPUT_JSON"

jq -e '
  def settings($target):
    [.[] | select(.target == $target)]
    | if length == 1 then .[0].buildSettings
      else error("Expected exactly one build-settings entry for \($target)")
      end;

  settings("VideoIntelligenceNative") as $app
  | settings("VideoIntelligenceNativeTests") as $tests
  | ($app.PRODUCT_NAME == "VideoIntelligence")
    and ($app.PRODUCT_MODULE_NAME == "VideoIntelligenceNative")
    and ($app.EXECUTABLE_NAME == "VideoIntelligence")
    and ($app.WRAPPER_NAME == "VideoIntelligence.app")
    and ($tests.TEST_HOST | endswith("/VideoIntelligence.app/VideoIntelligence"))
    and ($tests.BUNDLE_LOADER | endswith("/VideoIntelligence.app/VideoIntelligence"))
' "$OUTPUT_JSON" > /dev/null

echo 'Verified generated app product, executable, module, wrapper, test host, and bundle loader settings.'
