---
name: fast-claude
description: Use when Claude Code feels slow — slow session startup, long pauses after file edits, frequent permission prompts, sluggish long sessions, or bloated context from MCP servers, plugins, and skills.
---

# Fast Claude

## Overview

Claude Code latency comes from four places: **per-edit hooks** (blocking checks after every Edit/Write), **fixed per-session context** (MCP tools, plugin injections, and skill listings reprocessed every session), **human permission waits** (the largest *perceived* latency), and **long sessions** (every turn reprocesses the whole transcript).

Core principle: **measure first, change one thing at a time, and never trade security or quality for speed.** Every fix below keeps the checks that block bad code — it only moves them off the hot path.

## Quick reference

| Symptom | Source | Fix |
|---|---|---|
| Long pause after every file edit | Hook running a full-project check | Step 2 |
| Slow startup / first token | MCP servers, plugin injections, skill sprawl | Step 3 |
| Always waiting on permission prompts | Literal one-shot allowlist rules | Step 4 |
| Turns slow down as the session grows | Context accumulation | Step 6 |

## Step 1: Measure

- `claude update`, note `claude --version`.
- `/context` in a fresh session: record system-prompt, MCP-tool, and skill token counts. If MCP tools show as deferred, trimming them gains little — measure before cutting.
- Time one turn that edits a file in your biggest repo.

Re-measure after every change. A fix that doesn't move a number isn't a fix.

## Step 2: Fix per-edit hooks (biggest per-action win)

If a PostToolUse hook runs `tsc --noEmit` (or any full-project check) on every edit, make it incremental and keep build state **outside the repo** so it never dirties `git status`.

Use [scripts/lint-after-edit.sh](scripts/lint-after-edit.sh): per-file `ruff` for Python, incremental `tsc` with `--tsBuildInfoFile` under `~/.claude/cache/` for TypeScript, automatic fallback for old tsc versions. Measured: 4.25s → 1.38s per edit; the gap grows with repo size.

To see what the hook is doing (file detected, tsconfig found, commands, timings), run with `FAST_CLAUDE_DEBUG=1` — it appends to `~/.claude/cache/fast-claude-debug.log`.

Anti-patterns:

- **Don't swap tsc for eslint** — eslint does not typecheck; you silently lose the guardrail.
- **Don't make a Stop hook the only check** — Stop doesn't fire on interrupts, and a pre-existing type error the agent can't fix creates a re-invocation loop.

## Step 3: Trim per-session context

- Disable unused MCP servers **per project** (`/mcp` → toggle). Never disconnect account-level connectors you still use on other surfaces (web, mobile, other projects).
- Audit plugins that inject text every session or spawn a process every prompt; `claude plugin disable <name>` the ones you don't use. Trial for a week; re-enable if quality drops.
- Move skills used by a single project into that project's `.claude/skills/`.
- **Never shorten engineered skill descriptions** to save tokens — the description is the only trigger signal; cutting it makes skills stop firing or cross-trigger with each other.

## Step 4: Cut permission waits safely

Each permission prompt costs seconds to minutes of human wait. In `settings.json`:

- Delete dead literal rules that will never match again.
- Add **read-only** patterns only: `Bash(git status:*)`, `Bash(git diff:*)`, `Bash(git log:*)`, `Bash(ls:*)`.
- For remote hosts, allowlist a wrapper script that runs only fixed read-only commands (status, logs) — not `ssh:*`.
- **Never allowlist broad wildcards** (`Bash(ssh:*)`, `Bash(git:*)`, `Bash(curl:*)`). Combined with auto-accept modes, they execute mutating commands on production, `git remote add` + push (code exfiltration), or curl POSTs with no human checkpoint. If a prompt injection or model error fires one, there is no undo.

### Complete example: `~/.claude/settings.json`

Steps 2 and 4 combined in one working config (replace `/Users/you` with your home path — hooks need absolute paths):

```json
{
  "permissions": {
    "allow": [
      "Bash(git status:*)",
      "Bash(git diff:*)",
      "Bash(git log:*)",
      "Bash(ls:*)"
    ]
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/.claude/hooks/lint-after-edit.sh",
            "timeout": 120,
            "statusMessage": "Lint/typecheck edited file..."
          }
        ]
      }
    ]
  }
}
```

MCP servers are not disabled here — that's per project via `/mcp` → toggle (Step 3), so account-level connectors keep working everywhere else.

## Step 5: Models and effort

- Keep the main model at full strength — speed must not cost reasoning quality.
- **Don't set a cheap model globally for all subagents** — research and planning subagents degrade silently and feed wrong premises back to you. Override per mechanical task only.
- If a long-context tier (e.g. 1M) is your permanent default, make it per-session opt-in instead.
- Set reasoning effort at session start only — changing it mid-session invalidates the prompt cache.

## Step 6: Session hygiene (biggest single win)

- `/clear` when switching tasks — a fresh session is almost always faster than turn 35 of an old one.
- `claude --continue` to resume within the prompt-cache TTL.
- `/compact` only at natural breaks between tasks, never mid-task.
- `/context` regularly to audit what fills the window.

## Common mistakes

| Excuse | Reality |
|---|---|
| "eslint is faster than tsc" | It doesn't typecheck. You lose the guardrail, not the wait. |
| "Move checks to a Stop hook" | Doesn't fire on interrupt; pre-existing errors loop forever. |
| "Cheap model for all subagents" | Research subagents fail silently; wrong premises reach you unnoticed. |
| "The user told me to allowlist ssh:*" | Auto-accept + wildcard = unattended root on production. Propose a read-only wrapper instead. |
| "Shorter skill descriptions save tokens" | ~1k tokens saved, skills stop triggering. Worst trade on this list. |

## Real-world impact

Applied to a real setup: per-edit hook 4.25s → 1.38s; ~70% of fixed per-session context overhead removed; permission waits eliminated for read-only operations — with zero reduction in typecheck coverage, model strength, or command safety.
