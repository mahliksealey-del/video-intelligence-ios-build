#!/bin/bash
set -euo pipefail

EXPECTED="$(mktemp)"
ACTUAL="$(mktemp)"
trap 'rm -f "$EXPECTED" "$ACTUAL"' EXIT

grep -v '^[[:space:]]*$' SOURCE_ALLOWLIST.txt | LC_ALL=C sort > "$EXPECTED"
git ls-files | LC_ALL=C sort > "$ACTUAL"
diff -u "$EXPECTED" "$ACTUAL"

if git ls-files | grep -Eq '(^|/)(node_modules|dist|DerivedData|Artifacts|build|models|private-media|transcripts|downloads|cache)(/|$)'; then
  echo 'Forbidden generated, private, or model directory is tracked.' >&2
  exit 1
fi

if git ls-files | grep -Eiq '\.(p12|pfx|mobileprovision|cer|key|pem|mlmodel|mlmodelc|onnx|safetensors|gguf|mp3|m4a|wav|mov|mp4|ipa|xcresult)$'; then
  echo 'Forbidden credential, model, media, or build artifact is tracked.' >&2
  exit 1
fi

if git grep -nIE '([A-Za-z]:\\Users\\|/Users/[^/]+/|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,})' -- . ':!scripts/audit-public-snapshot.sh'; then
  echo 'Potential local path, private key, or credential found.' >&2
  exit 1
fi

if git ls-files | grep -Eiq '(^|/)(package-lock\.json|node_modules|wrangler\.jsonc|service-worker\.js|manifest\.webmanifest)$'; then
  echo 'Unexpected PWA or JavaScript build input is tracked.' >&2
  exit 1
fi

echo 'Public snapshot allowlist and forbidden-content audit passed.'
