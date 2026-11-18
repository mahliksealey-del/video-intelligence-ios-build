#!/bin/bash
set -euo pipefail

DEVICES_JSON="$(mktemp)"
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun simctl list devices available -j > "$DEVICES_JSON"

SELECTED="$(jq -r '
  [.devices | to_entries[] as $runtime
    | select($runtime.key | startswith("com.apple.CoreSimulator.SimRuntime.iOS-"))
    | $runtime.value[]
    | select((.isAvailable // true) == true and (.name | startswith("iPhone")))
    | {udid: .udid, name: .name, runtime: $runtime.key}]
  | sort_by(.runtime, .name) | reverse | first // empty
  | [.udid, .name, .runtime] | @tsv
' "$DEVICES_JSON")"

if [[ -z "$SELECTED" ]]; then
  echo 'No available iPhone simulator was found.' >&2
  exit 1
fi

IFS=$'\t' read -r SIMULATOR_UDID SIMULATOR_NAME SIMULATOR_RUNTIME <<< "$SELECTED"
test -n "$SIMULATOR_UDID"
{
  echo "SIMULATOR_UDID=$SIMULATOR_UDID"
  echo "SIMULATOR_NAME=$SIMULATOR_NAME"
  echo "SIMULATOR_RUNTIME=$SIMULATOR_RUNTIME"
} >> "$GITHUB_ENV"
echo "Selected simulator: $SIMULATOR_NAME ($SIMULATOR_RUNTIME, $SIMULATOR_UDID)"
