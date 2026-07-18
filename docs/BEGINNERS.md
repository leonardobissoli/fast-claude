# Beginner's Guide — fast-claude

*Documentation for people who are **not developers**. No jargon, step by step, from zero.*

---

## What is this?

**Claude Code** is Anthropic's coding assistant that runs on your computer. Over time it can get **slow**: it takes long to answer, stalls after editing a file, keeps asking for permission.

**fast-claude** is an "optimization kit" that fixes this. It does two things:

1. **Teaches Claude to optimize itself** — it's a *skill* (a manual Claude itself reads). You just say *"Claude Code feels slow"* and it applies the right fixes.
2. **Proves it worked, with numbers** — it ships with a measuring tool (`benchmark.sh`) that compares before and after in a visual dashboard.

> **Analogy:** it's like taking your car to a shop that first measures everything (fuel use, response time), then makes ONE adjustment at a time, and measures again to prove each adjustment paid off. No "replace everything and hope".

---

## Why does Claude Code get slow?

Four causes, each with its own cure:

| Cause | What happens | Analogy |
|---|---|---|
| **1. A check after every edit** | Each time a file is edited, a "reviewer" (hook) checks the ENTIRE project instead of just the file that changed | Re-reading the whole book to proofread one paragraph |
| **2. Baggage at session start** | Connected tools (MCP, plugins, skills) you never use get loaded every single time | Leaving home with 5 suitcases to walk to the bakery |
| **3. Permission prompts** | Claude stops and waits for YOU to click "approve" on harmless commands, like listing files | Requiring written authorization to open a drawer |
| **4. Long sessions** | Every answer reprocesses the whole conversation; huge conversation = slow answer | Retelling the entire story before every new sentence |

fast-claude tackles all four — **without sacrificing quality or safety** (that's the project's rule number one).

---

## Step by step: installing

**What you need:** a Mac or Linux machine with Claude Code already installed, plus the program `jq` (a data reader the kit uses).

**1.** Open the Terminal (on Mac: `Cmd + Space`, type "Terminal", Enter).

**2.** Install `jq` (harmless to repeat if you already have it):

```bash
brew install jq
```

**3.** Download fast-claude into Claude's skills folder:

```bash
git clone https://github.com/leonardobissoli/fast-claude ~/.claude/skills/fast-claude
```

**4.** Done. Open Claude Code and say:

> *"Claude Code feels slow"*

The skill triggers on its own and Claude walks you through the fixes, one at a time.

---

## Step by step: measuring (the before and after)

"Feeling" faster is worthless — the kit measures for real. The flow has 4 steps:

**1. Turn on the stopwatch.** In the Terminal:

```bash
echo 'export FAST_CLAUDE_DEBUG=1' >> ~/.zshrc
```

Close and reopen the Terminal. From then on, every file check gets logged with its duration (in a log file you never have to look at).

**2. Use Claude Code normally for a day.** Then take a "photo" of the current state:

```bash
~/.claude/skills/fast-claude/scripts/benchmark.sh snapshot baseline
```

`baseline` = your starting point. The photo records: how long each file check took, how much "baggage" a session carries, how long you spent waiting on permission prompts, how long each answer takes.

**3. Apply ONE optimization** (Claude does this for you when you tell it it's slow). Use it for another day and take another photo, named after the change:

```bash
~/.claude/skills/fast-claude/scripts/benchmark.sh snapshot incremental-hook
```

**4. Compare:**

```bash
~/.claude/skills/fast-claude/scripts/benchmark.sh compare baseline incremental-hook
```

That prints a table in the Terminal with before, after, and the % difference. Or generate the visual dashboard:

```bash
~/.claude/skills/fast-claude/scripts/benchmark.sh report
```

This creates a file called `benchmark-dashboard.html` — double-click it and it opens in your browser.

> **No patience to wait a day?** `benchmark.sh hook path/to/file.ts` measures the file check right now, including the "before" and "after" variants.

---

## How to read the dashboard

![sample dashboard](sample-benchmark.jpg)

- **Each row is a "photo"** (snapshot) you took, oldest to newest. In the sample: `01-baseline` (before anything) → `02-incremental-hook` → `03-mcp-trim` → `04-allowlist` (one photo after each optimization).
- **Shorter bar = faster = better.** Always. Light bar = the past; dark bar = your current state.
- **The green ▼ badge** shows how much things improved from start to now (e.g. ▼ -68% = dropped 68%). A red ▲ = it got worse (great for catching a change that backfired).
- **The 4 cards at the top** are the summary: file-check time, session-start baggage, permission-wait time, time per answer.
- **The little trend line** shows WHERE the drop happened — if it fell right after the `03-mcp-trim` photo, that change is the one that paid off.
- The dashboard itself has a **"How to read this dashboard"** section at the top with this same summary.
- Want each metric explained in depth? See the [metric reference](METRICS.md).

Reading the sample above: the file check dropped from 4.2s to 1.4s at optimization `02`, session baggage dropped 35% at `03`, and permission waiting plummeted 87% at `04`. Every change proved its worth.

---

## Is this safe?

Yes — and the project is stubborn about it. What it **refuses** to do in the name of speed:

- **It never turns code checks off** — it only makes them smarter (check only what changed).
- **It never green-lights dangerous commands** — it only auto-approves *read-only* commands (show status, list files). Nothing that modifies or deletes.
- **It never swaps in a dumber model** — speed must not cost reasoning quality.

---

## Common problems

| Symptom | Fix |
|---|---|
| "Not sure it installed" | In Claude Code, type: *"do you know the fast-claude skill?"* |
| `benchmark.sh` command not found | Use the full path: `~/.claude/skills/fast-claude/scripts/benchmark.sh` |
| `jq not installed` | Run `brew install jq` |
| Snapshot says "no hook timings" | The stopwatch wasn't on — redo step 1 of measuring and use Claude for a while |
| Dashboard opens blank | Regenerate with `benchmark.sh report` — it needs at least 1 saved snapshot |

---

## Quick glossary

| Term | Human translation |
|---|---|
| **Skill** | A manual Claude reads to learn a new task |
| **Hook** | An automatic check that runs after every file edit |
| **MCP** | Connectors that give Claude superpowers (Gmail, Notion…) — each loaded one weighs the session down |
| **Token** | A "word-piece" the model processes; more tokens = slower and more expensive |
| **Context** | Everything Claude holds in memory during the conversation |
| **Allowlist** | A list of pre-approved commands that skip the permission prompt |
| **Snapshot** | A photo of the measurements at one moment, to compare later |
| **p50 / p95** | "Half the time it was faster than this" / "almost always (95%) it was faster than this" |
| **Baseline** | The starting point — the measurement before any change |

---

*Technical questions? The [README](../README.md) and [SKILL.md](../SKILL.md) have the full developer version.*
