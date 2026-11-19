#!/bin/bash
set -euo pipefail

PYTHON_ROOT="$PROJECT_DIR/Runtime/PythonResources"
UPSTREAM="$PYTHON_ROOT/Python.xcframework/build/utils.sh"
EXPECTED_UTILS_SHA256="f62be20f4a17ba3a7ff1b1765b5ad0edca203ddc0f26a607e634d5f588b5e15d"

test -f "$UPSTREAM"
ACTUAL_UTILS_SHA256="$(shasum -a 256 "$UPSTREAM" | awk '{print $1}')"
test "$ACTUAL_UTILS_SHA256" = "$EXPECTED_UTILS_SHA256" || {
  echo "Unexpected Python packaging helper; refusing to patch it." >&2
  exit 1
}

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  source "$UPSTREAM"
else
  test "$(grep -Fc 'echo "Signing framework as $EXPANDED_CODE_SIGN_IDENTITY_NAME ($EXPANDED_CODE_SIGN_IDENTITY)..."' "$UPSTREAM")" -eq 1
  test "$(grep -Fc '/usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY"' "$UPSTREAM")" -eq 1
  PATCHED="$(mktemp)"
  trap 'rm -f "$PATCHED"' EXIT
  sed '/    echo "Signing framework as \$EXPANDED_CODE_SIGN_IDENTITY_NAME/,/    \/usr\/bin\/codesign --force --sign "\$EXPANDED_CODE_SIGN_IDENTITY"/d' "$UPSTREAM" > "$PATCHED"
  ! grep -Fq '/usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY"' "$PATCHED"
  source "$PATCHED"
fi

rsync -a --delete "$PYTHON_ROOT/app/" "$CODESIGNING_FOLDER_PATH/app/"
rsync -a --delete "$PYTHON_ROOT/app_packages/" "$CODESIGNING_FOLDER_PATH/app_packages/"
install_python "Runtime/PythonResources/Python.xcframework" "Runtime/PythonResources/app" "Runtime/PythonResources/app_packages"
