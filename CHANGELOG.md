# Changelog

## Unreleased

## 0.5.0 - 2026-09-21

- **New `fix` role.** A well-scoped fix pass over already-verified findings
  (agent `fixer`), added to all three shipped presets right after `build`;
  generates `clfix`/`clpfix` like any other role.
- **`claude-cast argv <role>`.** Prints a role’s resolved launch arguments,
  one token per line, with no `claude` word — `--model <id>`, then `--effort
  <level>` when non-empty, then each `extra` token with a leading `~`
  expanded. Shares the launchers’ own resolution path, so the two can’t
  disagree. Unknown role → stderr message, return 1.
- **Agent-definition awareness.** A new `CLAUDE_CAST_AGENTS` associative
  array (agent-definition name → role, default filled from the shipped map,
  overridable like `CLAUDE_CAST`) and `CLAUDE_CAST_AGENTS_DIR` (default
  `$HOME/.claude/agents`). The plugin can check each agent file’s
  `model:`/`effort:` frontmatter against its role’s table entry — pure zsh
  file reads, no subprocess. `claude-cast export` now carries a top-level
  `"agents"` map.
- **`claude-cast doctor [--fetch] [--brief]`.** Runs `lint`, the
  agent-definition check, and (when `chezmoi` is on `PATH`) a source-behind
  count; exit 0 clean, 1 on drift. `--brief` is one line.
- **Launch-time agent check.** Every launcher runs the agent check (existing
  files only, mismatch only) before `command claude`, governed by
  `CLAUDE_CAST_LAUNCH_CHECK`: `ask` (default — prompt on a TTY, refuse with
  code 3 when there’s no TTY to confirm), `warn` (print, continue), or `off`.
  No mismatch means zero output and no behaviour change.

## 0.4.0 - 2026-09-03

- **`extra` flags are now a first-class part of the casting source.** A
  `casting.json` row can carry an `extra` field (a flags string); the
  generator renders it as the third `|`-separated field of a row (e.g.
  `claude-opus-4-8[1m]|high|--append-system-prompt-file
  ~/.claude/skills/fable-mode/SKILL.md`), in a fourth README column, and
  appended to the CLAUDE.md casting list. A leading `~` in any extra-flag
  word now expands to `$HOME` at launch time, in
  `_claude_cast_define_launcher` — the row string is data, so `~` doesn’t
  expand on its own; `claude-cast which` prints the expanded form.
- **Two new roles: `fable` and `taste`.** `fable` — Fable-mode rigor on a
  non-Fable model, via the fable-mode skill appended at launch. `taste` —
  design, writing, and aesthetic direction, the one role the 2026-09-01/02
  battery found no Opus-plus-skill crossover for.
- **`max20` rebalanced.** `driver` and `build` now run Opus 4.8 (Fable
  draws from a 50% weekly bucket on Max 20x, not unlimited quota); `fable`
  and `orchestrate` run Opus 4.8 with the fable-mode skill appended rather
  than the Fable model itself; `verify` and `taste` still run Fable 5.1,
  where the battery found it wins outright. `max5` and `pro` keep their
  prior shape, plus the two new rows.
- Role order in the generated tables (and this repo’s docs) is now
  `driver`, `fable`, `build`, `chore`, `verify`, `taste`, `orchestrate`,
  `review`, `sonnet` — `claude-cast list`/`export` still sort roles
  alphabetically (unchanged; not worth the added complexity of tracking a
  fixed order alongside arbitrary user-added roles).

## 0.3.0 - 2026-09-02

- **Defaults are now generated from the author’s casting source, not hand-copied.** The `max20`/`max5`/`pro` tables in this file’s plugin source and in the README now live between `casting:begin`/`casting:end` markers, rendered from `claude-ops/casting.json` by `claude-ops/routines/project-casting.mjs --write` and stamped with the source commit and date; `--check` re-renders every block and fails on drift, and runs in the author’s release routine before a version is tagged. Behaviour unchanged — same three tables, same launchers.

## 0.2.0 - 2026-09-02

- **Plan presets.** `CLAUDE_CAST_PRESET` (set before sourcing, default
  `max20`) picks one of three shipped default tables: `max20` (today’s
  table, Claude Max 20x), `max5` (Claude Max 5x — Fable rationed, Opus
  fronts `driver`/`orchestrate`), `pro` (Claude Pro — Sonnet-led, no `review`
  row). A user row set before sourcing (or via `CLAUDE_CAST_FILE`) still
  overrides a matching preset row, same merge rule as before. An unknown
  preset falls back to `max20` with a stderr message.
- `claude-cast list` now opens with a header line naming the active preset
  and any roles the table overrode from it, e.g.
  `preset: pro (overridden: chore)`.
- New `claude-cast presets` subcommand: prints all three shipped preset
  tables, one after another.
- `claude-cast export`’s JSON now carries a top-level `"preset"` field.
- **Empty-effort semantics.** A spec with an empty effort field
  (`model|` or `model||extra`) now means: pass no `--effort` flag at all —
  required for Haiku, which errors on `--effort`. `claude-cast which` and
  `list` reflect this; `lint` no longer misflags an empty effort as
  “unknown effort” and still warns only when a Haiku row carries a
  non-empty one. `claude-cast set <role> <model> <effort> [flags...]` now
  accepts `-` (or `""`) for `<effort>` to mean empty.

## 0.1.0 - 2026-09-02

Initial release.

- `CLAUDE_CAST` associative array (role -> `model|effort|extra flags`),
  merged against a shipped default table (`driver`, `build`, `chore`,
  `verify`, `orchestrate`, `review`, `sonnet`) — a row set before sourcing,
  or via `CLAUDE_CAST_FILE`, always wins over the matching default.
- Generated launchers per role: `cl<role>` and a headless `clp<role>`
  (adds `-p --output-format json --setting-sources ""`, overridable via the
  `CLAUDE_CAST_HEADLESS_FLAGS` array), plus fixed `cl` (bare `claude`) and
  `clr` (`claude --continue`). Configurable prefix via `CLAUDE_CAST_PREFIX`.
- Collision-safe generation: skips any name already resolving to a command,
  alias, function, or builtin, with one summary line at load; override with
  `CLAUDE_CAST_FORCE=1`.
- `claude-cast` command: `list` (default), `which`, `set`, `unset`,
  `export` (JSON, stable key order), `lint` (alias-model / Haiku+effort /
  unknown-effort warnings, exit 1 on any), `reload`, `help`, `version`.
- Lazy `compdef _claude <launcher>` wiring, retried on first `claude-cast`
  call so load order relative to `compinit` doesn’t matter.
- Four install paths documented: oh-my-zsh, plain `source`, zinit, antidote.
- `test/run.zsh`: dependency-free black-box suite (stub `claude` on `PATH`,
  hermetic `zsh -f` subprocesses per assertion); `export`‘s JSON validated
  with `node -e`. CI on ubuntu-latest and macos-latest via GitHub Actions.
