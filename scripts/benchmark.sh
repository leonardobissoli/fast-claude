#!/usr/bin/env bash
# fast-claude benchmark: measure whether the skill actually made Claude Code faster.
#
#   benchmark.sh snapshot <name> [--transcript <file.jsonl>]
#       Collect current metrics into ~/.claude/cache/fast-claude-bench/<name>.json
#       - hook latency avg/p50/p95, edit count, fail rate  (from the debug log;
#         enable with FAST_CLAUDE_DEBUG=1 so lint-after-edit.sh logs timings)
#       - startup context tokens, per-turn latency p50/p90, human waits
#         (from the newest Claude Code transcript for the current project)
#   benchmark.sh compare [<before> <after>]
#       Text table with deltas between two snapshots (default: before/after).
#   benchmark.sh report [-o <out.html>]
#       Self-contained HTML dashboard over ALL saved snapshots
#       (default: ./benchmark-dashboard.html).
#   benchmark.sh hook <file>
#       Synthetic hook bench: 1 cold + 3 warm runs; for .ts/.tsx also times the
#       non-incremental "before" variant for an instant comparison.
#
# Requires jq. Overridables: FAST_CLAUDE_BENCH_DIR, FAST_CLAUDE_DEBUG_LOG.

BENCHDIR="${FAST_CLAUDE_BENCH_DIR:-$HOME/.claude/cache/fast-claude-bench}"
DEBUGLOG="${FAST_CLAUDE_DEBUG_LOG:-$HOME/.claude/cache/fast-claude-debug.log}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if ! command -v jq >/dev/null 2>&1; then
  echo "benchmark.sh: jq not installed; cannot compute metrics. Install jq first." >&2
  exit 0
fi

# Millisecond clock: EPOCHREALTIME on bash >= 5, else jq's float clock
# (macOS ships bash 3.2 and BSD date has no %N).
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    printf '%s\n' "$EPOCHREALTIME" | awk -F. '{ printf "%d", $1 * 1000 + substr($2 "000", 1, 3) }'
  else
    jq -n 'now * 1000 | floor'
  fi
}

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# ---------- metric collection ----------

hook_stats_json() { # from the debug log; {} fields null/0 when no data
  if [ ! -f "$DEBUGLOG" ]; then
    echo '{"avg_ms":null,"p50_ms":null,"p95_ms":null,"edits":0,"fail_rate":null}'
    return
  fi
  jq -R -s '
    [ split("\n")[] | capture("done: status=(?<st>[0-9]+) elapsed=(?<v>[0-9]+)(?<u>ms|s)")? ]
    | map({st: (.st|tonumber), ms: (if .u=="s" then (.v|tonumber)*1000 else (.v|tonumber) end)})
    | if length == 0
      then {avg_ms:null, p50_ms:null, p95_ms:null, edits:0, fail_rate:null}
      else ([.[].ms] | sort) as $s
      | { avg_ms: (([.[].ms] | add) / length | round),
          p50_ms: $s[(length * 0.5 | floor)],
          p95_ms: $s[([ (length * 0.95 | floor), length - 1 ] | min)],
          edits: length,
          fail_rate: (([.[] | select(.st != 0)] | length) / length * 1000 | round / 1000) }
      end' "$DEBUGLOG"
}

find_transcript() { # newest transcript for the cwd project
  slug=$(pwd | sed 's/[^a-zA-Z0-9]/-/g')
  ls -t "$HOME/.claude/projects/$slug"/*.jsonl 2>/dev/null | head -1
}

session_stats_json() { # $1 = transcript path; nulls when unreadable
  if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo '{"startup_tokens":null,"turn_p50_s":null,"turn_p90_s":null,"turns":0,"waits":0,"wait_total_s":0}'
    return
  fi
  jq -s '
    def ts: .timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def is_prompt: .type == "user" and .isMeta != true and
      ((.message.content | type) == "string" or
       ((.message.content | type) == "array" and
        ([.message.content[].type] | index("tool_result") | not)));
    def is_toolresult: .type == "user" and
      ((.message.content | type) == "array" and
       ([.message.content[].type] | index("tool_result")));
    def pct($a; $p):
      if ($a | length) == 0 then null
      else ($a | sort)[([ (($a | length) * $p | floor), ($a | length) - 1 ] | min)]
      end;

    [ .[] | select(.timestamp != null and (.type == "user" or .type == "assistant")) ] as $m
    | ([ $m[] | select(.type == "assistant" and .message.usage != null) ][0].message.usage) as $u
    | (if $u then (($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0)
                   + ($u.cache_creation_input_tokens // 0)) else null end) as $startup
    | [ range(0; $m | length) | select($m[.] | is_prompt) ] as $starts
    | [ range(0; $starts | length) | . as $i
        | (if $i + 1 < ($starts | length) then $starts[$i + 1] - 1 else ($m | length) - 1 end) as $e
        | (($m[$e] | ts) - ($m[$starts[$i]] | ts))
        | select(. >= 0) ] as $turns
    | [ range(1; $m | length)
        | select(($m[. - 1].type == "assistant") and ($m[.] | is_toolresult))
        | (($m[.] | ts) - ($m[. - 1] | ts))
        | select(. > 10) ] as $waits
    | { startup_tokens: $startup,
        turn_p50_s: pct($turns; 0.5),
        turn_p90_s: pct($turns; 0.9),
        turns: ($turns | length),
        waits: ($waits | length),
        wait_total_s: ($waits | add // 0 | round) }' "$1"
}

# ---------- subcommands ----------

cmd_snapshot() {
  name="$1"; shift
  [ -z "$name" ] && usage
  transcript=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --transcript) transcript="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
  done
  [ -z "$transcript" ] && transcript=$(find_transcript)

  hook=$(hook_stats_json)
  session=$(session_stats_json "$transcript")
  [ "$(echo "$hook" | jq .edits)" = "0" ] && \
    echo "warning: no hook timings in $DEBUGLOG (enable FAST_CLAUDE_DEBUG=1 and use Claude Code first)" >&2
  [ "$(echo "$session" | jq .turns)" = "0" ] && \
    echo "warning: no transcript found/parsed for this project (session metrics are null)" >&2

  mkdir -p "$BENCHDIR"
  jq -n --arg name "$name" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg transcript "${transcript:-}" \
        --argjson hook "$hook" --argjson session "$session" \
    '{name: $name, timestamp: $ts, transcript: $transcript, hook: $hook, session: $session}' \
    > "$BENCHDIR/$name.json"
  echo "saved: $BENCHDIR/$name.json"
  jq . "$BENCHDIR/$name.json"
}

snap_rows() { # $1=before.json $2=after.json -> TSV: label, before, after, delta
  jq -r -s '
    def fmt($v; $u):
      if $v == null then "-"
      elif $u == "ms" then "\($v)ms"
      elif $u == "s"  then "\($v)s"
      elif $u == "tok" then (if $v >= 1000 then "\($v / 100 | round / 10)k tok" else "\($v) tok" end)
      elif $u == "%"  then "\($v * 1000 | round / 10)%"
      else "\($v)" end;
    def delta($b; $a; $u):
      if $b == null or $a == null then "-"
      elif $u == "%" then "\(($a - $b) * 1000 | round / 10)pp"
      elif $b == 0 then (if $a == 0 then "0%" else "-" end)
      else "\(( ($a - $b) / $b * 100 ) | round)%" end;
    .[0] as $b | .[1] as $a
    | [ ["Hook avg",        $b.hook.avg_ms,           $a.hook.avg_ms,           "ms"],
        ["Hook p50",        $b.hook.p50_ms,           $a.hook.p50_ms,           "ms"],
        ["Hook p95",        $b.hook.p95_ms,           $a.hook.p95_ms,           "ms"],
        ["Edits measured",  $b.hook.edits,            $a.hook.edits,            ""],
        ["Fail rate",       $b.hook.fail_rate,        $a.hook.fail_rate,        "%"],
        ["Startup context", $b.session.startup_tokens, $a.session.startup_tokens, "tok"],
        ["Turn p50",        $b.session.turn_p50_s,    $a.session.turn_p50_s,    "s"],
        ["Turn p90",        $b.session.turn_p90_s,    $a.session.turn_p90_s,    "s"],
        ["Human waits",     $b.session.waits,         $a.session.waits,         ""],
        ["Wait total",      $b.session.wait_total_s,  $a.session.wait_total_s,  "s"] ][]
    | [ .[0], fmt(.[1]; .[3]), fmt(.[2]; .[3]), delta(.[1]; .[2]; .[3]) ] | @tsv
  ' "$1" "$2"
}

cmd_compare() {
  b="${1:-before}"; a="${2:-after}"
  bf="$BENCHDIR/$b.json"; af="$BENCHDIR/$a.json"
  for f in "$bf" "$af"; do
    [ -f "$f" ] || { echo "snapshot not found: $f (run: benchmark.sh snapshot <name>)" >&2; exit 1; }
  done
  echo "=== fast-claude benchmark: $b vs $a ==="
  printf '%-18s %-12s %-12s %s\n' "" "$b" "$a" "delta"
  snap_rows "$bf" "$af" | while IFS=$'\t' read -r label bv av dv; do
    printf '%-18s %-12s %-12s %s\n' "$label:" "$bv" "$av" "$dv"
  done
}

cmd_report() {
  out="./benchmark-dashboard.html"
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) out="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
  done
  set -- "$BENCHDIR"/*.json
  [ -f "$1" ] || { echo "no snapshots in $BENCHDIR (run: benchmark.sh snapshot <name>)" >&2; exit 1; }
  data=$(jq -s 'sort_by(.timestamp)' "$@")
  { render_report_head; printf 'const DATA = %s;\n' "$data"; render_report_tail; } > "$out"
  echo "wrote: $out ($(printf '%s' "$data" | jq 'length') snapshots)"
}

cmd_hook() {
  f="$1"
  [ -f "$f" ] || { echo "file not found: $f" >&2; exit 1; }
  hookscript="$SCRIPT_DIR/lint-after-edit.sh"
  [ -f "$hookscript" ] || { echo "hook script not found: $hookscript" >&2; exit 1; }
  payload=$(jq -n --arg f "$f" '{tool_input: {file_path: $f}}')

  run_once() { # prints elapsed ms; hook exit status ignored (we measure, not gate)
    s=$(now_ms)
    printf '%s' "$payload" | bash "$hookscript" >/dev/null 2>&1
    echo "$(( $(now_ms) - s ))"
  }

  case "$f" in
    *.ts|*.tsx)
      # Clear this project's incremental state so run 1 is a true cold start.
      dir=$(dirname "$f"); tsconfig=""
      while [ "$dir" != "/" ] && [ -n "$dir" ]; do
        if [ -f "$dir/tsconfig.json" ]; then tsconfig="$dir/tsconfig.json"; break; fi
        dir=$(dirname "$dir")
      done
      if [ -n "$tsconfig" ]; then
        pdir=$(dirname "$tsconfig")
        h=$(printf '%s' "$pdir" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || { command -v shasum >/dev/null 2>&1 && shasum || cksum; }; } | cut -d' ' -f1)
        rm -f "$HOME/.claude/cache/tsbuildinfo/$h.tsbuildinfo"
      fi
      ;;
  esac

  echo "=== hook bench: $f ==="
  cold=$(run_once)
  echo "cold:   ${cold}ms"
  w1=$(run_once); w2=$(run_once); w3=$(run_once)
  wmed=$(printf '%s\n%s\n%s\n' "$w1" "$w2" "$w3" | sort -n | sed -n 2p)
  echo "warm:   ${w1}ms ${w2}ms ${w3}ms  (median ${wmed}ms)"

  case "$f" in
    *.ts|*.tsx)
      if [ -n "${tsconfig:-}" ]; then
        pdir=$(dirname "$tsconfig")
        tscbin=""
        if [ -x "$pdir/node_modules/.bin/tsc" ]; then tscbin="./node_modules/.bin/tsc"
        elif command -v tsc >/dev/null 2>&1; then tscbin="tsc"; fi
        if [ -n "$tscbin" ]; then
          s=$(now_ms)
          (cd "$pdir" && "$tscbin" --noEmit >/dev/null 2>&1)
          echo "before (plain tsc --noEmit, non-incremental): $(( $(now_ms) - s ))ms"
        fi
      fi
      ;;
  esac
}

# ---------- HTML dashboard template ----------
# Single hue for bars (snapshots = same measure over time, not categories);
# deltas use status colors + a glyph so meaning never rides on color alone;
# text stays in ink tokens; raw values in a <details> table; light/dark themed.

render_report_head() {
cat <<'HTMLHEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>fast-claude — benchmark dashboard</title>
<style>
  :root {
    color-scheme: light;
    --page: #f9f9f7; --surface: #fcfcfb;
    --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
    --grid: #e1e0d9; --border: rgba(11,11,11,0.10);
    --bar-strong: #2a78d6; --bar-muted: #9ec5f4;
    --good: #006300; --bad: #d03b3b;
    --good-bg: rgba(12,163,12,0.10); --bad-bg: rgba(208,59,59,0.10);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      color-scheme: dark;
      --page: #0d0d0d; --surface: #1a1a19;
      --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
      --grid: #2c2c2a; --border: rgba(255,255,255,0.10);
      --bar-strong: #3987e5; --bar-muted: #184f95;
      --good: #0ca30c; --bad: #e66767;
      --good-bg: rgba(12,163,12,0.16); --bad-bg: rgba(230,103,103,0.16);
    }
  }
  * { box-sizing: border-box; margin: 0; }
  body {
    background: var(--page); color: var(--ink);
    font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
    padding: 32px 20px 60px; max-width: 880px; margin: 0 auto;
  }
  h1 { font-size: 22px; }
  .sub { color: var(--ink-2); margin: 4px 0 28px; font-size: 14px; }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; margin-bottom: 32px; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; }
  .card .k { color: var(--ink-2); font-size: 13px; }
  .card .v { font-size: 26px; font-weight: 650; margin: 2px 0; }
  .card .d { font-size: 13px; }
  .section { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 18px 20px; margin-bottom: 16px; }
  .section h2 { font-size: 15px; display: flex; align-items: baseline; gap: 8px; }
  .section .step { color: var(--muted); font-size: 12px; font-weight: 400; }
  .badge { font-size: 12px; font-weight: 600; padding: 1px 8px; border-radius: 99px; margin-left: auto; }
  .badge.good { color: var(--good); background: var(--good-bg); }
  .badge.bad  { color: var(--bad);  background: var(--bad-bg); }
  .badge.flat { color: var(--ink-2); background: transparent; border: 1px solid var(--border); }
  .rows { margin: 12px 0 4px; display: grid; gap: 7px; }
  .row { display: grid; grid-template-columns: 150px 1fr 90px; gap: 10px; align-items: center; font-size: 13px; }
  .row .name { color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .row .val { color: var(--ink); text-align: right; font-variant-numeric: tabular-nums; }
  .track { display: block; height: 14px; }
  .bar { display: block; height: 14px; border-radius: 0 4px 4px 0; background: var(--bar-muted); min-width: 2px; }
  .row.last .bar { background: var(--bar-strong); }
  .row.last .name { color: var(--ink); font-weight: 600; }
  .spark { margin-top: 10px; color: var(--ink-2); font-size: 12px; display: flex; align-items: center; gap: 10px; }
  .spark svg { display: block; }
  .spark polyline { fill: none; stroke: var(--bar-strong); stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
  details { margin-top: 28px; }
  summary { cursor: pointer; color: var(--ink-2); font-size: 14px; }
  table { border-collapse: collapse; margin-top: 12px; width: 100%; font-size: 13px; }
  th, td { text-align: right; padding: 6px 10px; border-bottom: 1px solid var(--grid); font-variant-numeric: tabular-nums; }
  th:first-child, td:first-child { text-align: left; }
  th { color: var(--ink-2); font-weight: 600; }
  .foot { margin-top: 24px; color: var(--muted); font-size: 12px; }
</style>
</head>
<body>
<h1>fast-claude — benchmark dashboard</h1>
<p class="sub" id="sub"></p>
<div class="cards" id="cards"></div>
<div id="sections"></div>
<details><summary>Raw values (table view)</summary><div id="tablewrap"></div></details>
<p class="foot">All metrics: lower is better. Generated by <code>scripts/benchmark.sh report</code>.</p>
<script>
HTMLHEAD
}

render_report_tail() {
cat <<'HTMLTAIL'
const METRICS = [
  { path: ["hook","p50_ms"],            label: "Hook p50",          unit: "ms",  step: "Step 2 — per-edit hooks" },
  { path: ["hook","p95_ms"],            label: "Hook p95",          unit: "ms",  step: "Step 2 — per-edit hooks" },
  { path: ["hook","fail_rate"],         label: "Hook fail rate",    unit: "%",   step: "Step 2 — per-edit hooks", scale: 100 },
  { path: ["session","startup_tokens"], label: "Startup context",   unit: "tok", step: "Step 3 — per-session context" },
  { path: ["session","wait_total_s"],   label: "Human wait total",  unit: "s",   step: "Step 4 — permission waits" },
  { path: ["session","waits"],          label: "Human waits",       unit: "",    step: "Step 4 — permission waits" },
  { path: ["session","turn_p50_s"],     label: "Turn p50",          unit: "s",   step: "Step 6 — session hygiene" },
  { path: ["session","turn_p90_s"],     label: "Turn p90",          unit: "s",   step: "Step 6 — session hygiene" },
];
const CARDS = [
  { label: "Hook p50",        path: ["hook","p50_ms"],            unit: "ms" },
  { label: "Startup context", path: ["session","startup_tokens"], unit: "tok" },
  { label: "Wait total",      path: ["session","wait_total_s"],   unit: "s" },
  { label: "Turn p50",        path: ["session","turn_p50_s"],     unit: "s" },
];

const get = (s, p) => p.reduce((o, k) => (o == null ? null : o[k]), s);
const fmt = (v, unit, scale) => {
  if (v == null) return "–";
  if (scale) v = Math.round(v * scale * 10) / 10;
  if (unit === "tok") return v >= 1000 ? (Math.round(v / 100) / 10) + "k tok" : v + " tok";
  return v + (unit ? unit : "");
};
const series = (m) => DATA.map(s => ({ name: s.name, v: get(s, m.path) }));
const firstLast = (vals) => {
  const known = vals.filter(x => x.v != null);
  return known.length >= 2 ? [known[0].v, known[known.length - 1].v] : null;
};
const deltaBadge = (fl) => {
  if (!fl || fl[0] === 0) return '<span class="badge flat">n/a</span>';
  const pct = Math.round((fl[1] - fl[0]) / fl[0] * 100);
  if (pct === 0) return '<span class="badge flat">±0%</span>';
  const good = pct < 0; // every metric here: lower is better
  return `<span class="badge ${good ? "good" : "bad"}">${good ? "▼" : "▲"} ${pct > 0 ? "+" : ""}${pct}%</span>`;
};
const spark = (vals) => {
  const known = vals.map(x => x.v).filter(v => v != null);
  if (known.length < 2) return "";
  const w = 120, h = 26, max = Math.max(...known), min = Math.min(...known);
  const pts = known.map((v, i) => {
    const x = 2 + i * (w - 4) / (known.length - 1);
    const y = max === min ? h / 2 : 3 + (h - 6) * (1 - (v - min) / (max - min));
    return x.toFixed(1) + "," + y.toFixed(1);
  }).join(" ");
  return `<div class="spark"><svg width="${w}" height="${h}" role="img" aria-label="trend"><polyline points="${pts}"/></svg><span>trend across ${known.length} snapshots</span></div>`;
};

document.getElementById("sub").textContent =
  DATA.length + " snapshots: " + DATA.map(s => s.name).join(" → ");

document.getElementById("cards").innerHTML = CARDS.map(c => {
  const vals = series(c), fl = firstLast(vals);
  const last = vals.filter(x => x.v != null).pop();
  return `<div class="card"><div class="k">${c.label}</div>
    <div class="v">${last ? fmt(last.v, c.unit) : "–"}</div>
    <div class="d">${deltaBadge(fl)}</div></div>`;
}).join("");

document.getElementById("sections").innerHTML = METRICS.map(m => {
  const vals = series(m);
  const known = vals.filter(x => x.v != null);
  if (!known.length) return "";
  const max = Math.max(...known.map(x => x.v), 1e-9);
  const lastIdx = vals.map(x => x.v != null).lastIndexOf(true);
  const rows = vals.map((x, i) => x.v == null ? "" :
    `<div class="row${i === lastIdx ? " last" : ""}">
       <span class="name">${x.name}</span>
       <span class="track"><span class="bar" style="width:${Math.max(1.5, x.v / max * 100)}%"></span></span>
       <span class="val">${fmt(x.v, m.unit, m.scale)}</span></div>`).join("");
  return `<div class="section"><h2>${m.label} <span class="step">${m.step}</span>${deltaBadge(firstLast(vals))}</h2>
    <div class="rows">${rows}</div>${spark(vals)}</div>`;
}).join("");

document.getElementById("tablewrap").innerHTML =
  `<table><tr><th>metric</th>${DATA.map(s => `<th>${s.name}</th>`).join("")}</tr>` +
  METRICS.map(m =>
    `<tr><td>${m.label}</td>${series(m).map(x => `<td>${fmt(x.v, m.unit, m.scale)}</td>`).join("")}</tr>`
  ).join("") + "</table>";
</script>
</body>
</html>
HTMLTAIL
}

# ---------- dispatch ----------

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  snapshot) cmd_snapshot "${1:-}" "${@:2}" ;;
  compare)  cmd_compare "$@" ;;
  report)   cmd_report "$@" ;;
  hook)     [ $# -ge 1 ] || usage; cmd_hook "$1" ;;
  *) usage ;;
esac
