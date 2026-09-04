#!/bin/bash
set -euo pipefail

payload="$(cat)"

# Whole-payload schema gate, run BEFORE any mutation. \z (not $) as the string
# end anchor -- verified on this machine that $ matches before an embedded
# newline character, which would otherwise land inside the interpolated Lua
# string below. Duplicate names are rejected so a name appearing once enabled
# and once disabled can't defeat the "never zero enabled" check further down.
# Internal-panel names (eDP-*/LVDS-*/DSI-*) are rejected outright: the "never
# touch the internal monitor" rule (Global Constraints) is enforced here too,
# not just by the UI never constructing such a payload -- this script must
# also be safe if invoked directly.
if ! jq -e '
  type == "array" and length > 0 and
  ( [.[] | .name] | length ) == ( [.[] | .name] | unique | length ) and
  all(.[];
    (.name | type == "string" and test("^[A-Za-z0-9._-]+\\z") and (test("^(eDP|LVDS|DSI)-") | not)) and
    (.disabled | type == "boolean") and
    (if .disabled then true else
      (.mode | type == "string" and test("^[1-9][0-9]*x[1-9][0-9]*@[0-9]+([.][0-9]+)?Hz\\z")) and
      (.x | type == "number" and . == floor) and
      (.y | type == "number" and . == floor) and
      (.scale | type == "number" and . >= 1 and . <= 4) and
      (.transform | type == "number" and . == floor and . >= 0 and . <= 3)
    end)
  )
' <<<"$payload" >/dev/null; then
  echo "Invalid monitor-layout payload" >&2
  exit 1
fi

# "Never zero enabled monitors" checked against live reality: only require the
# payload itself to keep something enabled when nothing OUTSIDE the payload
# (e.g. the untouched laptop panel) is already on. No hardcoded monitor names.
live_before="$(hyprctl monitors all -j)"
other_live_enabled="$(jq -n --argjson requested "$payload" --argjson live "$live_before" '
  [$live[] | select((.name as $n | ($requested | map(.name) | index($n))) == null) | select(.disabled == false)] | length
')"
if [[ "$other_live_enabled" == "0" ]]; then
  if ! jq -e 'any(.[]; .disabled == false)' <<<"$payload" >/dev/null; then
    echo "Refusing: this would leave zero monitors enabled" >&2
    exit 1
  fi
fi

enable_items="$(echo "$payload" | jq -c '[.[] | select(.disabled == false)] | .[]')"
disable_items="$(echo "$payload" | jq -c '[.[] | select(.disabled == true)] | .[]')"

apply_one() {
  local item="$1" name mode x y scale transform
  name="$(echo "$item" | jq -r '.name')"
  if [[ "$(echo "$item" | jq -r '.disabled')" == "true" ]]; then
    hyprctl eval "hl.monitor({ output = \"$name\", disabled = true })" >/dev/null
    return
  fi
  mode="$(echo "$item" | jq -r '.mode')"
  x="$(echo "$item" | jq -r '.x')"
  y="$(echo "$item" | jq -r '.y')"
  scale="$(echo "$item" | jq -r '.scale')"
  transform="$(echo "$item" | jq -r '.transform')"
  hyprctl eval "hl.monitor({ output = \"$name\", disabled = false, mode = \"$mode\", position = \"${x}x${y}\", scale = $scale, transform = $transform })" >/dev/null
}

if [[ -n "$enable_items" ]]; then
  while IFS= read -r item; do apply_one "$item"; done <<<"$enable_items"
fi
if [[ -n "$disable_items" ]]; then
  # Confirm at least one requested-enabled monitor actually came up live
  # before disabling anything -- an enable that silently failed must not be
  # followed by disables that could leave nothing on.
  if [[ -n "$enable_items" ]]; then
    still_missing="$(jq -n --argjson requested "$payload" --argjson live "$(hyprctl monitors all -j)" '
      [$requested[] | select(.disabled == false) | . as $r |
        ($live | map(select(.name == $r.name and .disabled == false)) | length) as $n |
        select($n == 0)
      ] | length
    ')"
    if [[ "$still_missing" != "0" ]]; then
      echo "Refusing to disable: a requested enable did not take effect" >&2
      exit 1
    fi
  fi
  while IFS= read -r item; do apply_one "$item"; done <<<"$disable_items"
fi

# Full-field verification, including refresh rate (an earlier draft captured
# the rate from the mode string but never actually compared it -- caught by
# testing this exact expression, not just reading it). Scale and refresh rate
# use a small epsilon since floating point round-trips through Hyprland
# aren't guaranteed bit-exact.
for attempt in 1 2 3 4 5; do
live="$(hyprctl monitors all -j)"
mismatch="$(jq -n --argjson requested "$payload" --argjson live "$live" '
  [$requested[] as $r |
    ($live | map(select(.name == $r.name)) | first) as $l |
    select(
      ($l == null) or
      ($l.disabled != $r.disabled) or
      (($r.disabled | not) and (
        ($l.width != ($r.mode | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)@(?<r>[0-9.]+)Hz") | .w | tonumber)) or
        ($l.height != ($r.mode | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)@(?<r>[0-9.]+)Hz") | .h | tonumber)) or
        ($l.x != $r.x) or ($l.y != $r.y) or
        ($l.transform != $r.transform) or
        (( ($l.scale - $r.scale) | if . < 0 then -. else . end ) > 0.05) or
        (( ($l.refreshRate - ($r.mode | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)@(?<r>[0-9.]+)Hz") | .r | tonumber)) | if . < 0 then -. else . end ) > 0.5)
      ))
    )
  ] | length
')"
if [[ "$mismatch" == "0" ]]; then
  break
fi
if (( attempt < 5 )); then
  sleep 0.5
fi
done
if [[ "$mismatch" != "0" ]]; then
  echo "Live state did not match requested layout after apply" >&2
  exit 1
fi
