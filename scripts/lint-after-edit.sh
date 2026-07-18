#!/usr/bin/env bash
# PostToolUse guard for Edit|Write. Reads the hook JSON on stdin.
#
# Runs the RIGHT check for the edited file only:
#   .py      -> ruff check <file>            (skipped if ruff not installed)
#   .ts/.tsx -> tsc --noEmit --incremental at the nearest tsconfig.json,
#               with build state stored OUTSIDE the repo so it never
#               dirties git status (prefers project-local tsc)
# Any other extension, missing tool, or missing config -> no-op (exit 0).
#
# On failure: prints errors to stderr and exits 2, which feeds the output
# back to Claude as a blocking error so it fixes before declaring done.
#
# Install:
#   cp lint-after-edit.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/lint-after-edit.sh
# Then in ~/.claude/settings.json (use your absolute home path in "command"):
#   "hooks": { "PostToolUse": [ { "matcher": "Edit|Write", "hooks": [ {
#     "type": "command", "command": "/path/to/home/.claude/hooks/lint-after-edit.sh",
#     "timeout": 120, "statusMessage": "Lint/typecheck edited file..." } ] } ] }

f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)
[ -z "$f" ] && exit 0
[ -f "$f" ] || exit 0

status=0
out=""

case "$f" in
  *.py)
    if command -v ruff >/dev/null 2>&1; then
      out=$(ruff check "$f" 2>&1) || status=2
    fi
    ;;
  *.ts|*.tsx)
    dir=$(dirname "$f")
    tsconfig=""
    while [ "$dir" != "/" ] && [ -n "$dir" ]; do
      if [ -f "$dir/tsconfig.json" ]; then tsconfig="$dir/tsconfig.json"; break; fi
      dir=$(dirname "$dir")
    done
    [ -z "$tsconfig" ] && exit 0
    pdir=$(dirname "$tsconfig")
    # Incremental state lives outside the repo so .tsbuildinfo never dirties git status.
    cachedir="$HOME/.claude/cache/tsbuildinfo"
    mkdir -p "$cachedir"
    tsbi="$cachedir/$(printf '%s' "$pdir" | shasum | cut -d' ' -f1).tsbuildinfo"
    tscbin=""
    if [ -x "$pdir/node_modules/.bin/tsc" ]; then
      tscbin="./node_modules/.bin/tsc"
    elif command -v tsc >/dev/null 2>&1; then
      tscbin="tsc"
    fi
    if [ -n "$tscbin" ]; then
      out=$(cd "$pdir" && "$tscbin" --noEmit --incremental --tsBuildInfoFile "$tsbi" 2>&1) || status=2
      # tsc too old for --incremental with --noEmit rejects the flags with a TS5xxx
      # config error; retry without them (plain full check, same as before).
      if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qE 'error TS5[0-9]{3}'; then
        status=0
        out=$(cd "$pdir" && "$tscbin" --noEmit 2>&1) || status=2
      fi
    fi
    ;;
esac

if [ "$status" -ne 0 ]; then
  echo "Check failed for $f:" >&2
  echo "$out" >&2
  exit 2
fi
exit 0
