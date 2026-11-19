#!/bin/bash
set -euo pipefail

ROOT="${1:-NativePrototype}"
RUNTIME="$ROOT/Runtime/PythonResources"
KERAUNOS_COMMIT="863a436cfc3028f38ff8e1f940a66a3e68c53104"
KERAUNOS_SHA256="a3c8a353a650ce79b51db58e798d0f81ef6ea34847e7eb4c6bbd532b0f63b8fc"
PYTHON_TAG="3.13-b14"
PYTHON_SHA256="8b5cb76ef8d8a2946052479358eeec9d54b4496cb60920e175ec1489b5cf7963"

mkdir -p "$RUNTIME"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

verify() {
  local file="$1" expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  test "$actual" = "$expected" || { echo "Integrity mismatch for $file" >&2; exit 1; }
}

if [[ ! -d "$RUNTIME/Python.xcframework" ]]; then
  curl --fail --location --retry 3 \
    "https://github.com/beeware/Python-Apple-support/releases/download/$PYTHON_TAG/Python-3.13-iOS-support.b14.tar.gz" \
    --output "$WORK/python.tar.gz"
  verify "$WORK/python.tar.gz" "$PYTHON_SHA256"
  tar -xzf "$WORK/python.tar.gz" -C "$WORK"
  cp -R "$WORK/Python.xcframework" "$RUNTIME/"
fi

if [[ ! -d "$RUNTIME/app_packages/yt_dlp" ]]; then
  curl --fail --location --retry 3 \
    "https://github.com/LiLiKazine/Keraunos/archive/$KERAUNOS_COMMIT.tar.gz" \
    --output "$WORK/keraunos.tar.gz"
  verify "$WORK/keraunos.tar.gz" "$KERAUNOS_SHA256"
  tar -xzf "$WORK/keraunos.tar.gz" -C "$WORK"
  SOURCE="$WORK/Keraunos-$KERAUNOS_COMMIT/app/Keraunos/PythonResources"
  rm -rf "$RUNTIME/app" "$RUNTIME/app_packages"
  cp -R "$SOURCE/app" "$RUNTIME/app"
  cp -R "$SOURCE/app_packages" "$RUNTIME/app_packages"
fi

test -f "$RUNTIME/app/keraunos_extract.py"
test -f "$RUNTIME/app/cacert.pem"
test -f "$RUNTIME/app_packages/yt_dlp/version.py"
test -d "$RUNTIME/Python.xcframework"
echo "Verified embedded social runtime assets."
