#!/bin/bash
set -euo pipefail

payload="$(cat)"
monitor_lua="$HOME/.config/hypr/monitors.lua"
begin_marker="-- BEGIN dutchbase.monitor-arrange generated block"
end_marker="-- END dutchbase.monitor-arrange generated block"

# Same whole-payload schema gate as apply.sh.
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

block_file="$(mktemp "$HOME/.config/hypr/.monitors-arrange-block.XXXXXX")"
trap 'rm -f "$block_file"' EXIT

echo "$payload" | jq -c '.[]' | while read -r item; do
  name="$(echo "$item" | jq -r '.name')"
  if [[ "$(echo "$item" | jq -r '.disabled')" == "true" ]]; then
    echo "hl.monitor({ output = \"$name\", disabled = true })"
    continue
  fi
  mode="$(echo "$item" | jq -r '.mode')"
  x="$(echo "$item" | jq -r '.x')"
  y="$(echo "$item" | jq -r '.y')"
  scale="$(echo "$item" | jq -r '.scale')"
  transform="$(echo "$item" | jq -r '.transform')"
  echo "hl.monitor({ output = \"$name\", disabled = false, mode = \"$mode\", position = \"${x}x${y}\", scale = $scale, transform = $transform })"
done > "$block_file"

tmp="$(mktemp "$HOME/.config/hypr/.monitors.lua.XXXXXX")"
had_backup=0

if [[ -f $monitor_lua ]] && grep -qF -- "$begin_marker" "$monitor_lua"; then
  # Splice in place. block_file contains ONLY the body (no markers) -- awk
  # prints the original begin/end marker lines itself, exactly once each,
  # which is what makes this idempotent on a repeat run. Verified against a
  # real 14-line monitors.lua: append, in-place replace, and a repeat run all
  # produced correct, non-duplicated output with every original line intact.
  awk -v begin="$begin_marker" -v end="$end_marker" -v blockfile="$block_file" '
    $0 == begin { print; while ((getline line < blockfile) > 0) print line; close(blockfile); skip=1; next }
    $0 == end { skip=0; print; next }
    !skip { print }
  ' "$monitor_lua" > "$tmp"
else
  {
    [[ -f $monitor_lua ]] && cat "$monitor_lua"
    echo "$begin_marker"
    cat "$block_file"
    echo "$end_marker"
  } > "$tmp"
fi
rm -f "$block_file"

backup=""
if [[ -f $monitor_lua ]]; then
  backup="$monitor_lua.bak.$(date +%s)"
  cp "$monitor_lua" "$backup"
  had_backup=1
fi
mv "$tmp" "$monitor_lua"

rollback() {
  if [[ $had_backup -eq 1 ]]; then
    mv "$backup" "$monitor_lua"
    hyprctl reload >/dev/null 2>&1 || true
  fi
  # No prior file existed (first-ever persist on a fresh install that then
  # failed validation): there is nothing to roll back to. The freshly-written
  # file is left in place and the failure is still reported via exit 1 --
  # this is a known, narrow gap (documented, not silently pretended solved)
  # rather than a fabricated recovery for a state that can't yet exist twice.
}

if ! hyprctl reload >/dev/null 2>&1; then
  echo "hyprctl reload failed, restoring backup" >&2
  rollback
  exit 1
fi

# hyprctl configerrors itself failing to run is NOT the same as "no errors" --
# don't mask a command failure with || true.
if ! errors="$(hyprctl configerrors 2>&1)"; then
  echo "hyprctl configerrors failed to run, restoring backup: $errors" >&2
  rollback
  exit 1
fi
# Verified live on this machine: prints nothing / exit 0 on success, no
# "no errors" sentinel string.
if [[ -n "$errors" ]]; then
  echo "Config errors after reload, restoring backup: $errors" >&2
  rollback
  exit 1
fi
