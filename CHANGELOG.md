# Changelog

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
  call so load order relative to `compinit` doesn't matter.
- Four install paths documented: oh-my-zsh, plain `source`, zinit, antidote.
- `test/run.zsh`: dependency-free black-box suite (stub `claude` on `PATH`,
  hermetic `zsh -f` subprocesses per assertion); `export`'s JSON validated
  with `node -e`. CI on ubuntu-latest and macos-latest via GitHub Actions.
