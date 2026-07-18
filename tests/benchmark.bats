#!/usr/bin/env bats
# Tests for scripts/benchmark.sh. Run with: bats tests/

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/benchmark.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  export FAST_CLAUDE_BENCH_DIR="$BATS_TEST_TMPDIR/bench"
  export FAST_CLAUDE_DEBUG_LOG="$BATS_TEST_TMPDIR/debug.log"
  mkdir -p "$HOME" "$FAST_CLAUDE_BENCH_DIR"
}

write_debug_log() { # mixed old (s) and new (ms) formats, one failure
  cat > "$FAST_CLAUDE_DEBUG_LOG" <<'EOF'
2026-07-18T10:00:00 file: /p/a.ts
2026-07-18T10:00:01 done: status=0 elapsed=2s
2026-07-18T10:00:05 file: /p/b.ts
2026-07-18T10:00:06 done: status=0 elapsed=1000ms
2026-07-18T10:00:10 file: /p/c.ts
2026-07-18T10:00:14 done: status=2 elapsed=4000ms
2026-07-18T10:00:20 file: /p/d.ts
2026-07-18T10:00:23 done: status=0 elapsed=3000ms
EOF
}

write_transcript() { # 2 turns; turn 1 has a 20s human wait before its tool_result
  cat > "$BATS_TEST_TMPDIR/transcript.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-07-18T10:00:00.000Z","message":{"content":"first prompt"}}
{"type":"assistant","timestamp":"2026-07-18T10:00:05.000Z","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":40000,"cache_creation_input_tokens":900},"content":[{"type":"tool_use"}]}}
{"type":"user","timestamp":"2026-07-18T10:00:25.000Z","message":{"content":[{"type":"tool_result"}]}}
{"type":"assistant","timestamp":"2026-07-18T10:00:30.000Z","message":{"usage":{"input_tokens":200,"cache_read_input_tokens":41000,"cache_creation_input_tokens":0},"content":[{"type":"text"}]}}
{"type":"user","timestamp":"2026-07-18T10:01:00.000Z","message":{"content":"second prompt"}}
{"type":"assistant","timestamp":"2026-07-18T10:01:10.000Z","message":{"usage":{"input_tokens":300,"cache_read_input_tokens":42000,"cache_creation_input_tokens":0},"content":[{"type":"text"}]}}
EOF
}

@test "snapshot: hook stats from mixed s/ms debug log" {
  write_debug_log
  run bash "$SCRIPT" snapshot t1
  [ "$status" -eq 0 ]
  json="$FAST_CLAUDE_BENCH_DIR/t1.json"
  [ -f "$json" ]
  [ "$(jq .hook.edits "$json")" = "4" ]
  [ "$(jq .hook.avg_ms "$json")" = "2500" ]      # (2000+1000+4000+3000)/4
  [ "$(jq .hook.p50_ms "$json")" = "3000" ]      # sorted [1000,2000,3000,4000] idx 2
  [ "$(jq .hook.p95_ms "$json")" = "4000" ]
  [ "$(jq .hook.fail_rate "$json")" = "0.25" ]   # 1 of 4
}

@test "snapshot: session stats from transcript fixture" {
  write_transcript
  run bash "$SCRIPT" snapshot t2 --transcript "$BATS_TEST_TMPDIR/transcript.jsonl"
  [ "$status" -eq 0 ]
  json="$FAST_CLAUDE_BENCH_DIR/t2.json"
  [ "$(jq .session.startup_tokens "$json")" = "41000" ]  # 100+40000+900
  [ "$(jq .session.turns "$json")" = "2" ]
  [ "$(jq .session.turn_p50_s "$json")" = "30" ]         # turns 30s,10s -> sorted [10,30], idx floor(2*0.5)=1
  [ "$(jq .session.waits "$json")" = "1" ]               # 20s gap > 10s threshold
  [ "$(jq .session.wait_total_s "$json")" = "20" ]
}

@test "snapshot: no log and no transcript -> exit 0, null fields, warnings" {
  run bash "$SCRIPT" snapshot t3 --transcript /nonexistent.jsonl
  [ "$status" -eq 0 ]
  [[ "$output" == *"no hook timings"* ]]
  [[ "$output" == *"no transcript"* ]]
  json="$FAST_CLAUDE_BENCH_DIR/t3.json"
  [ "$(jq .hook.p50_ms "$json")" = "null" ]
  [ "$(jq .session.startup_tokens "$json")" = "null" ]
}

@test "compare: deltas between two known snapshots" {
  write_debug_log
  bash "$SCRIPT" snapshot before >/dev/null
  jq '.name = "after" | .hook.p50_ms = 1500 | .hook.avg_ms = 1250' \
    "$FAST_CLAUDE_BENCH_DIR/before.json" > "$FAST_CLAUDE_BENCH_DIR/after.json"
  run bash "$SCRIPT" compare
  [ "$status" -eq 0 ]
  [[ "$output" == *"-50%"* ]]   # p50 3000 -> 1500
  [[ "$output" == *"1250ms"* ]]
}

@test "compare: missing snapshot -> exit 1 with message" {
  run bash "$SCRIPT" compare nope1 nope2
  [ "$status" -eq 1 ]
  [[ "$output" == *"snapshot not found"* ]]
}

@test "report: HTML from 3 snapshots with values and names embedded" {
  write_debug_log
  bash "$SCRIPT" snapshot s1 >/dev/null
  jq '.name = "s2" | .hook.p50_ms = 2000' "$FAST_CLAUDE_BENCH_DIR/s1.json" > "$FAST_CLAUDE_BENCH_DIR/s2.json"
  jq '.name = "s3" | .hook.p50_ms = 1000' "$FAST_CLAUDE_BENCH_DIR/s1.json" > "$FAST_CLAUDE_BENCH_DIR/s3.json"
  out="$BATS_TEST_TMPDIR/dash.html"
  run bash "$SCRIPT" report -o "$out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 snapshots"* ]]
  [ -f "$out" ]
  grep -q '"s1"' "$out"
  grep -q '"s3"' "$out"
  grep -Eq '"p50_ms": ?1000' "$out"
  grep -q 'const DATA' "$out"
  grep -q 'const GENERATED' "$out"
  grep -q 'METRICS.md' "$out"
}

@test "report: no snapshots -> exit 1 with message" {
  run bash "$SCRIPT" report -o "$BATS_TEST_TMPDIR/x.html"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no snapshots"* ]]
}

@test "jq missing from PATH -> exit 0 with warning" {
  NOJQ="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$NOJQ"
  ln -sf "$(command -v bash)" "$NOJQ/bash"
  run bash -c "PATH='$NOJQ' bash '$SCRIPT' snapshot x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"jq not installed"* ]]
}

@test "no arguments -> usage, exit 1" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"snapshot"* ]]
}
