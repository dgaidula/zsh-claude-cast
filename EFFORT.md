# EFFORT.md — zsh-claude-cast

One row per work-pass. Agent metrics (duration/tokens/tool-calls) are exact when taken from
completion records; anything marked *(see orchestrator row)* means this agent's own duration/token
counts are not visible to it — the orchestrator session holds those. Git author is the machine
identity, not who did the work.

| date | agent/model | role | scope | duration | tokens | tool-calls | outcome |
|---|---|---|---|---|---|---|---|
| 2026-09-02 | Sonnet 5 [high] (builder subagent) | builder | Built zsh-claude-cast 0.1.0 from scratch: plugin (`CLAUDE_CAST` table, launcher generation, collision handling, `claude-cast` subcommands, lazy completion), README/CLAUDE.md/CHANGELOG per svg-knockout house shape, dependency-free `test/run.zsh` (stub `claude` on PATH, hermetic subprocesses), GitHub Actions CI. Two zsh bugs found and fixed during testing: unquoted `CLAUDE_CAST[key]=` on an undeclared array errors (needs `typeset -gA` first), and `"${(ok)assoc}"` without the `@` flag collapses to one word inside double quotes (hit `export`/`lint` tests, fixed to `(@ok)`) | 605s (exact, completion record) | 158,471 (exact) | 34 (exact) | success |
| 2026-09-02 | Claude Fable 5.1 (`claude-fable-5-1`, 1M ctx) [high] | orchestrator | Surveyed existing zsh Claude plugins (none casting-driven), designed the casting-table shape and launcher family, wrote the builder spec, verified the build (tests green in a fresh zsh, `list`/`which`/`lint` exercised), fixed README/CHANGELOG/CLAUDE.md prose to typographic punctuation, installed via chezmoi drop-in, added the repo to the private inventory. Wall-clock is an estimate | ~20 min (estimate) | not measured | ~12 | success |
