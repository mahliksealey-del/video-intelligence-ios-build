#!/bin/bash
set -euo pipefail

LOCKFILE="${1:?usage: verify-package-resolved.sh Package.resolved expected-version expected-revision}"
EXPECTED_VERSION="${2:?missing expected version}"
EXPECTED_REVISION="${3:?missing expected revision}"

test -s "$LOCKFILE"
jq -e --arg version "$EXPECTED_VERSION" --arg revision "$EXPECTED_REVISION" '
  [.pins[] | select(.identity == "argmax-oss-swift")] as $matches
  | ($matches | length) == 1
  and $matches[0].location == "https://github.com/argmaxinc/argmax-oss-swift.git"
  and $matches[0].state.version == $version
  and $matches[0].state.revision == $revision
' "$LOCKFILE" > /dev/null

echo "Verified argmax-oss-swift $EXPECTED_VERSION at $EXPECTED_REVISION"
