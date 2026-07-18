#!/usr/bin/env bats
# Tests for scripts/lint-after-edit.sh. Run with: bats tests/
#
# Each test invokes the script with a simulated hook JSON payload on stdin
# and a restricted PATH (stub dir + system dirs for coreutils/jq) so we
# control exactly which tools "exist".

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/lint-after-edit.sh"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$STUBS" "$WORK"
  # Keep real jq/coreutils reachable; stubs dir first so stubs win.
  JQ_DIR=$(dirname "$(command -v jq)")
  BASE_PATH="$STUBS:$JQ_DIR:/usr/bin:/bin"
  # Isolate cache/debug writes from the real home.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
}

payload() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }

run_hook() { # $1=file
  payload "$1" | PATH="$BASE_PATH" bash "$SCRIPT"
}

@test "py file without ruff on PATH -> exit 0, no output" {
  echo "x = 1" > "$WORK/a.py"
  run run_hook "$WORK/a.py"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "py file with failing ruff stub -> exit 2, error on stderr" {
  echo "x = 1" > "$WORK/a.py"
  cat > "$STUBS/ruff" <<'EOF'
#!/bin/sh
echo "a.py:1:1: E999 fake error"
exit 1
EOF
  chmod +x "$STUBS/ruff"
  run run_hook "$WORK/a.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Check failed"* ]]
  [[ "$output" == *"E999 fake error"* ]]
}

@test "py file with passing ruff stub -> exit 0" {
  echo "x = 1" > "$WORK/a.py"
  printf '#!/bin/sh\nexit 0\n' > "$STUBS/ruff"
  chmod +x "$STUBS/ruff"
  run run_hook "$WORK/a.py"
  [ "$status" -eq 0 ]
}

@test "ts file with no tsconfig.json in any parent -> exit 0" {
  echo "const x = 1" > "$BATS_TEST_TMPDIR/b.ts"
  run run_hook "$BATS_TEST_TMPDIR/b.ts"
  [ "$status" -eq 0 ]
}

@test "old tsc rejecting --incremental (TS5023) -> retries without flags" {
  mkdir -p "$WORK/proj"
  echo '{}' > "$WORK/proj/tsconfig.json"
  echo "const x = 1" > "$WORK/proj/c.ts"
  # Fails with TS5023 when given --incremental, passes on the plain retry.
  cat > "$STUBS/tsc" <<'EOF'
#!/bin/sh
case "$*" in
  *--incremental*) echo "error TS5023: Unknown compiler option"; exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUBS/tsc"
  run run_hook "$WORK/proj/c.ts"
  [ "$status" -eq 0 ]
}

@test "tsc failing with real type error -> exit 2" {
  mkdir -p "$WORK/proj2"
  echo '{}' > "$WORK/proj2/tsconfig.json"
  echo "const x = 1" > "$WORK/proj2/d.ts"
  cat > "$STUBS/tsc" <<'EOF'
#!/bin/sh
echo "d.ts(1,1): error TS2322: fake type error"
exit 1
EOF
  chmod +x "$STUBS/tsc"
  run run_hook "$WORK/proj2/d.ts"
  [ "$status" -eq 2 ]
  [[ "$output" == *"TS2322"* ]]
}

@test "jq missing from PATH -> exit 0 with warning on stderr" {
  # PATH with only a bash symlink: jq is guaranteed absent, and the script
  # reaches its jq check using shell builtins alone.
  NOJQ="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$NOJQ"
  ln -sf "$(command -v bash)" "$NOJQ/bash"
  run bash -c "printf '{}' | PATH='$NOJQ' bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"jq not installed"* ]]
}

@test "payload without file_path -> exit 0" {
  run bash -c "printf '{\"tool_input\":{}}' | PATH='$BASE_PATH' bash '$SCRIPT'"
  [ "$status" -eq 0 ]
}

@test "uncovered extension (.md) -> exit 0" {
  echo "# hi" > "$WORK/e.md"
  printf '#!/bin/sh\nexit 1\n' > "$STUBS/ruff"   # would fail if wrongly invoked
  chmod +x "$STUBS/ruff"
  run run_hook "$WORK/e.md"
  [ "$status" -eq 0 ]
}

@test "FAST_CLAUDE_DEBUG=1 writes debug log" {
  echo "x = 1" > "$WORK/a.py"
  payload "$WORK/a.py" | PATH="$BASE_PATH" FAST_CLAUDE_DEBUG=1 bash "$SCRIPT"
  [ -f "$HOME/.claude/cache/fast-claude-debug.log" ]
  grep -q "file: $WORK/a.py" "$HOME/.claude/cache/fast-claude-debug.log"
}
