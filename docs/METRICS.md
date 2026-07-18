# Metric reference — fast-claude benchmark

In-depth explanation of every metric in the benchmark dashboard. For the visual guide, see [BEGINNERS.md](BEGINNERS.md); for the workflow, see the [README](../README.md).

---

## Percentiles in 30 seconds

**p50** (median): the typical case. Half of all measurements were faster than this, half were slower. When someone says "a normal edit takes 1.4s", they mean the p50.

**p90 / p95**: the slow tail. 90% (or 95%) of measurements were faster than this. These tell you how bad the worst cases get.

**Why not just use the average?** One 60-second outlier drags the average up dramatically but barely moves the p50. Averages hide bad days; percentiles show them.

Example: if your edits take `[1s, 1s, 1s, 1s, 60s]`, the average is 12.8s (misleading — most edits are 1s), but the p50 is 1s (honest) and the p95 is 60s (tells you something rare but terrible is happening).

---

## Hook p50

### What it is

The typical delay the automatic file check adds after each edit. When Claude edits a file, a hook runs a linter or typechecker before declaring the edit done. This metric is the median of those check durations.

### Worked example

In the sample dashboard, Hook p50 dropped from **4250ms** (baseline) to **1370ms** (after making the hook incremental). That's a 68% reduction — each edit went from ~4.3 seconds of waiting to ~1.4 seconds.

### Where the number comes from

The debug log at `~/.claude/cache/fast-claude-debug.log`, written by `lint-after-edit.sh` when `FAST_CLAUDE_DEBUG=1` is set. Each line matching `done: status=N elapsed=Xms` contributes one data point. The benchmark script parses these, sorts them, and picks the middle value.

### What to expect

The incremental-tsc win grows with repo size. Tiny repos may show little gain because a full `tsc --noEmit` is already fast. Large monorepos can see 5–10x improvements. The first edit after a cache wipe is always a full check; the speedup shows from the second edit on.

---

## Hook p95

### What it is

The worst-case delay of the file check — 95% of edits were faster than this. It captures the slow tail that the p50 hides.

### Worked example

In the sample dashboard, Hook p95 dropped from **6100ms** to **2000ms**. Even the slowest edits now finish in ~2 seconds instead of ~6.

### Where the number comes from

Same debug log as Hook p50. The script sorts all elapsed times and picks the value at index `floor(length * 0.95)`.

### What to expect

The p95 is sensitive to cold starts, large files, or moments when the incremental cache is stale. If p95 is much higher than p50, investigate whether certain files or directories trigger full rebuilds.

---

## Hook fail rate

### What it is

How often the file check found a real problem and blocked the edit — the share of `status=2` lines in the debug log. A fail means the linter or typechecker caught an error.

### Worked example

In the sample dashboard, fail rate went from **4.3%** to **3.6%**. Roughly 1 in 23 edits had an error before; now 1 in 28 does. The rate stayed stable, which is healthy.

### Where the number comes from

The debug log. The script counts lines with `status=2` (check failed) and divides by total `done:` lines.

### What to expect

This is **not** a number to drive to zero. A stable fail rate means checks are running and catching real errors. A sudden drop to near-zero may mean checks stopped running entirely (misconfigured hook, missing tool, wrong file extension). If fail rate spikes, it may mean a new linter rule or a TypeScript upgrade surfaced latent issues — investigate, don't suppress.

---

## Startup context

### What it is

How much baggage (tokens) every session carries before you type anything — MCP servers, plugins, skills, system prompt, and any injected documentation. Lower means more room for your actual work.

### Worked example

In the sample dashboard, startup context dropped from **48.2k tokens** to **31.5k tokens** after disabling unused MCP servers and plugins (SKILL.md Step 3). That's ~16.7k tokens freed — roughly 35% less overhead per session.

### Where the number comes from

The newest Claude Code session transcript for the current project (`~/.claude/projects/<project-slug>/*.jsonl`). The script reads the first assistant reply's `usage` object and sums `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.

### What to expect

Trimming MCP servers you don't use is the biggest win. Plugins that inject text every session also add up. Skills are lightweight by comparison — don't remove skill descriptions to save tokens (they stop triggering, which is worse than the token cost).

---

## Human wait total

### What it is

Total time Claude sat idle waiting for you to approve permission prompts. Each "Claude wants to run `npm test`. Allow?" is a wait.

### Worked example

In the sample dashboard, human wait total dropped from **312 seconds** to **41 seconds** after allowlisting read-only commands (SKILL.md Step 4). That's 87% less time spent clicking "Allow".

### Where the number comes from

The session transcript. The script finds gaps longer than 10 seconds between an assistant tool call and the next user message containing a `tool_result`. Those gaps are summed.

### What to expect

Most waits come from permission prompts. The read-only allowlist (`Bash(git status:*)`, `Bash(ls:*)`, etc.) eliminates the harmless ones. Dangerous commands (`ssh`, `curl POST`, `git push`) should still prompt — that's the safety tradeoff.

---

## Human waits

### What it is

How many times Claude had to stop and wait for your approval. The count of those same >10-second gaps.

### Worked example

In the sample dashboard, human waits dropped from **9** to **2**. Seven permission prompts eliminated by the allowlist.

### Where the number comes from

Same transcript parsing as Human wait total, but counting gaps instead of summing them.

### What to expect

Drops sharply after allowlisting read-only commands. The remaining 2 waits are likely legitimate — a destructive command, a network call, or a moment where you stepped away.

---

## Turn p50

### What it is

Typical wall-clock time from your message to Claude's finished answer. Includes tool runs, file edits, and text generation — the full interaction.

### Worked example

In the sample dashboard, Turn p50 dropped from **22 seconds** to **14 seconds**. A typical exchange got 8 seconds faster.

### Where the number comes from

The session transcript. For each user message (excluding tool results and meta messages), the script finds the last assistant message before the next user message and computes the elapsed time. The p50 is the median of those durations.

### What to expect

Turn latency improves as a side effect of the other optimizations: faster hooks mean faster edits, less context means faster reasoning, fewer permission waits mean less idle time. It's also affected by session hygiene (SKILL.md Step 6) — long sessions slow down as the transcript grows.

---

## Turn p90

### What it is

Slow-turn time — 90% of answers arrived faster than this. Captures the interactions that involve many files, tests, or complex reasoning.

### Worked example

In the sample dashboard, Turn p90 dropped from **61 seconds** to **38 seconds**. Even the slowest turns are now under 40 seconds.

### Where the number comes from

Same transcript parsing as Turn p50, but the 90th percentile instead of the median.

### What to expect

A high p90 can be a genuinely big task (refactoring 20 files, running a full test suite, installing dependencies), not slowness. Compare the trend across snapshots, not the absolute number. If p90 spikes after a change, investigate whether that change broke incremental caching or added per-turn overhead.

---

See the [README](../README.md) for the workflow and [BEGINNERS.md](BEGINNERS.md) for the non-developer guide.
