#!/bin/bash
set -euo pipefail

ROOT="${1:-NativePrototype}"
RUNTIME="$ROOT/Runtime/PythonResources"
KERAUNOS_COMMIT="863a436cfc3028f38ff8e1f940a66a3e68c53104"
KERAUNOS_SHA256="a3c8a353a650ce79b51db58e798d0f81ef6ea34847e7eb4c6bbd532b0f63b8fc"
YTDLP_TAG="2026.10.26"
YTDLP_SHA256="21f942d258d25cc4e60b4982a25c423460f0bebb835f38e6dfd1fcb140087f95"
# yt-dlp 2026.10.26 uses EJS v0.8.0 for YouTube n/sig challenges.
# The upstream yt-dlp archive contains the core JS but intentionally omits
# the complete solver library. Without this pinned companion asset the native
# JavaScriptCore challenge provider cannot supply reliable YouTube formats.
EJS_TAG="0.8.0"
EJS_LIB_SHA256="770831df5c46474fbff06732315b28f4fb090e427ca669a51da61e2457d41c82"
EJS_LIB_SHA3_512="1ee3753a8222fc855f5c39db30a9ccbb7967dbe1fb810e86dc9a89aa073a0907f294c720e9b65427d560a35aa1ce6af19ef854d9126a05ca00afe03f72047733"
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

# Official checksum-pinned yt-dlp source. Preserve the proven Keraunos
# iOS Python bridge and other vendored helper packages.
curl --fail --location --retry 3 \
  "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_TAG/yt-dlp.tar.gz" \
  --output "$WORK/yt-dlp.tar.gz"
verify "$WORK/yt-dlp.tar.gz" "$YTDLP_SHA256"
mkdir -p "$WORK/new-ytdlp"
tar -xzf "$WORK/yt-dlp.tar.gz" -C "$WORK/new-ytdlp"
NEW_VERSION_FILE="$(find "$WORK/new-ytdlp" -type f -path '*/yt_dlp/version.py' -print -quit)"
test -n "$NEW_VERSION_FILE"
NEW_PACKAGE="$(dirname "$NEW_VERSION_FILE")"
grep -Fq "__version__ = '$YTDLP_TAG'" "$NEW_PACKAGE/version.py"
test -f "$NEW_PACKAGE/extractor/tiktok.py"
test -f "$NEW_PACKAGE/extractor/instagram.py"
rm -rf "$RUNTIME/app_packages/yt_dlp"
cp -R "$NEW_PACKAGE" "$RUNTIME/app_packages/yt_dlp"

# Fix the otherwise silent bundled YouTube JS challenge-solver regression:
# Keraunos' in-process JavaScriptCore provider subclasses EJSBaseJCP. That
# provider uses the yt-dlp vendored library path. yt-dlp intentionally ships
# core.js but does not include yt.solver.lib.js in its source release.
EJS_DIR="$RUNTIME/app_packages/yt_dlp/extractor/youtube/jsc/_builtin/vendor"
test -f "$EJS_DIR/yt.solver.core.js"
test ! -f "$EJS_DIR/yt.solver.lib.js"
test "$(grep -F "VERSION = '$EJS_TAG'" "$EJS_DIR/_info.py" | wc -l | tr -d ' ')" = "1"

curl --fail --location --retry 3 \
  "https://github.com/yt-dlp/ejs/releases/download/$EJS_TAG/yt.solver.lib.js" \
  --output "$WORK/yt.solver.lib.js"
verify "$WORK/yt.solver.lib.js" "$EJS_LIB_SHA256"
python3 - "$WORK/yt.solver.lib.js" "$EJS_LIB_SHA3_512" <<'PY'
import hashlib
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_bytes()
actual = hashlib.sha3_512(source).hexdigest()
if actual != sys.argv[2]:
    raise SystemExit("EJS solver-library hash mismatch against yt-dlp's vendor manifest")
PY
install -m 0644 "$WORK/yt.solver.lib.js" "$EJS_DIR/yt.solver.lib.js"
test -s "$EJS_DIR/yt.solver.lib.js"

# Host-side import smoke check before waiting for the full iOS build. The
# JavaScriptCore bridge itself is exercised on device; this verifies yt-dlp
# and the Keraunos provider can actually import from this exact IPA runtime.
PYTHONPATH="$RUNTIME/app_packages:$RUNTIME/app" python3 - <<'PY'
from yt_dlp.extractor.youtube.jsc._builtin import vendor
from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
from keraunos_youtube_jsc import KeraunosJavaScriptCoreJCP
assert vendor.VERSION == "0.8.0"
assert vendor.load_script("yt.solver.lib.js")
assert vendor.load_script("yt.solver.core.js")
assert issubclass(KeraunosJavaScriptCoreJCP, EJSBaseJCP)
print("Verified bundled EJS core/library and native JavaScriptCore provider.")
PY

python3 scripts/patch-social-runtime.py "$RUNTIME/app/keraunos_extract.py"
PYTHONPATH="$RUNTIME/app_packages:$RUNTIME/app" python3 scripts/test-youtube-provider-path.py
test -f "$RUNTIME/app/keraunos_extract.py"
test -f "$RUNTIME/app/cacert.pem"
test -f "$RUNTIME/app_packages/yt_dlp/version.py"
test -s "$RUNTIME/app_packages/yt_dlp/extractor/youtube/jsc/_builtin/vendor/yt.solver.lib.js"
test -d "$RUNTIME/Python.xcframework"
echo "Verified embedded social runtime assets."
