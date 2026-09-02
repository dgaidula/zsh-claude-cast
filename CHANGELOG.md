# Changelog

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
  "unknown effort" and still warns only when a Haiku row carries a
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
