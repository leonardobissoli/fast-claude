# fast-claude

A [Claude Code](https://claude.com/claude-code) skill that makes Claude Code **fast without losing quality**.

Born from a real optimization session: audit where the latency actually comes from, fix it with measured results, and — just as important — document the "speedups" that look tempting but silently destroy quality or security (they're in the skill's *Common mistakes* table).

## What it covers

1. **Measure first** — `/context`, version, timed turns. No cargo-cult tuning.
2. **Per-edit hooks** — incremental typecheck with build state outside the repo. Measured: **4.25s → 1.38s per edit** (grows with repo size). Ready-to-use hook in [`scripts/lint-after-edit.sh`](scripts/lint-after-edit.sh).
3. **Per-session context** — trim MCP servers per project, audit plugin injections, relocate single-project skills.
4. **Permission waits** — the largest perceived latency. Safe read-only allowlist patterns; never broad wildcards.
5. **Models and effort** — where a cheaper model is free speed and where it silently degrades your results.
6. **Session hygiene** — `/clear`, `--continue`, `/compact`, and when each helps or hurts.

## Install

Personal (all projects):

```bash
git clone https://github.com/leonardobissoli/fast-claude ~/.claude/skills/fast-claude
```

Per project:

```bash
git clone https://github.com/leonardobissoli/fast-claude .claude/skills/fast-claude
```

Then just tell Claude Code "Claude Code feels slow" — the skill triggers on that. Or read [SKILL.md](SKILL.md) yourself; it's short.

## Safety notes

The skill is opinionated about what **not** to do:

- No broad allowlist wildcards (`ssh:*`, `git:*`, `curl:*`) — with auto-accept modes these become unattended production access and exfiltration vectors.
- No global cheap-model override for subagents — research quality degrades silently.
- No cutting skill descriptions to save tokens — skills stop triggering.

## License

MIT — see [LICENSE](LICENSE).
