# zsh-claude-cast — maintainer notes

Agent-facing notes for future Claude sessions working on this repo. The
README is for users; this file is for whoever next touches
`zsh-claude-cast.plugin.zsh`.

## What this is

A zsh plugin that projects a `CLAUDE_CAST` associative array (role ->
`model|effort|extra flags`) into real shell functions (`cl<role>`,
`clp<role>` headless, plus fixed `cl`/`clr`). No hand-maintained aliases, no
`settings.json` writes — the table is the source of truth, the launchers are
its compiled form. See README.md for the full user-facing pitch.

## Architecture in one pass

Everything lives in `zsh-claude-cast.plugin.zsh`, no dependencies:

1. Config knobs (`CLAUDE_CAST_PREFIX`, `CLAUDE_CAST_FORCE`,
   `CLAUDE_CAST_PRESET`, `CLAUDE_CAST_HEADLESS_FLAGS`) get defaults via
   `: ${var:=default}` (or the array-existence check for
   `CLAUDE_CAST_HEADLESS_FLAGS`, since `: ${arr:=}` doesn’t work on zsh
   arrays). `CLAUDE_CAST_PRESET` (default `max20`) is resolved to
   `_CLAUDE_CAST_ACTIVE_PRESET` right after — an unrecognized value falls
   back to `max20` with a stderr note — since `_claude_cast_default_table`
   (see below) reads that resolved global, not the raw env var.
2. `CLAUDE_CAST` is declared with `typeset -gA` only if not already declared
   — this is what lets a caller pre-populate rows before sourcing and have
   them win over the shipped defaults.
3. `CLAUDE_CAST_FILE` (if set and readable) is sourced before anything else
   touches the table, so it behaves exactly like inline pre-source overrides.
4. `_claude_cast_merge_defaults` fills in any role not already present —
   never clobbers a key that exists.
5. `_claude_cast_generate_all` iterates `CLAUDE_CAST`, defines `cl<role>` +
   `clp<role>` per row via `_claude_cast_define_launcher`, then the two fixed
   helpers via `_claude_cast_generate_fixed`.
6. `_claude_cast_try_completion` wires `compdef _claude <name>` for every
   generated name, if `_claude`/`compdef` exist yet — called once at load and
   again lazily on the first `claude-cast` call, since load order relative to
   `compinit` isn’t guaranteed.

## The three zsh gotchas that will bite you here

1. **Assigning `ARR[key]=value` on an undeclared array is a hard error in
   zsh** (`assignment to invalid subscript range`), not an auto-vivify like
   bash. This is why `CLAUDE_CAST` must be `typeset -gA`‘d — by the plugin if
   the caller didn’t, by the caller first if they want their override to
   win. Don’t “simplify” the declare-guard away; a user’s inline
   `CLAUDE_CAST[build]=...` before `source` needs `typeset -gA CLAUDE_CAST`
   to have already run, in THEIR script, before that line.

2. **`"${(k)assoc}"` (or `(ok)`, `(kv)`, etc.) inside double quotes collapses
   to ONE word without the `@` flag.** `local -a roles=("${(ok)CLAUDE_CAST}")`
   silently produces a one-element array holding all the keys space-joined,
   not an array of keys — this was a real bug caught by the `export`/`lint`
   tests during the initial build (fixed by using `(@ok)` everywhere an
   assoc’s keys/values are captured into an array). Always use the `@` flag
   (`(@k)`, `(@kv)`, `(@ok)`, …) when expanding an array/assoc parameter
   inside double quotes into another array.

3. **Re-running `local name` (no `=value`) on a name already local in the
   same function activation PRINTS it**, like a miniature `typeset -p` —
   it doesn’t just no-op. Bit `claude-cast presets` during the 0.2.0 build:
   its `for preset in max20 max5 pro; do local role spec w1=4 …; done` loop
   printed `role=''` / `spec=''` on the 2nd and 3rd passes, because `local`
   ran a second time on names the first pass had already declared local.
   Fix: declare a loop’s locals ONCE before the loop, reset them by plain
   assignment (`w1=4`, `rows=()`) inside it — never call `local` on the same
   name twice within one function activation.

## Plan presets

Three tables, one function each — `_claude_cast_default_table_max20`,
`_claude_cast_default_table_max5`, `_claude_cast_default_table_pro` —
dispatched by `_claude_cast_default_table()` on `_CLAUDE_CAST_ACTIVE_PRESET`.
`_claude_cast_merge_defaults` now also records, in
`_CLAUDE_CAST_OVERRIDDEN_ROLES`, any role that was already present in
`CLAUDE_CAST` when it ran (i.e. a user/`CLAUDE_CAST_FILE` row shadowing a
preset row) — that’s what `claude-cast list`’s header line reports. This is
load-time-only: a later `claude-cast set` doesn’t retroactively add to that
array. `pro` deliberately has no `review` row (Opus 5 isn’t assumed on Pro);
don’t “fix” that by adding one.

**The three function bodies are generated, not hand-maintained.** They live
between `# casting:begin (generated from claude-ops casting.json @ <sha>
<date> — do not edit by hand)` and `# casting:end` in this file (same two
markers, as `<!-- casting:begin -->`/`<!-- casting:end -->`, wrap the
matching tables in README.md). The one machine-readable source is
`casting.json` in the author’s private `claude-ops` repo; `claude-ops/routines/project-casting.mjs --write`
renders it into both files here plus the author’s global Claude Code
instructions, and `--check` fails if any of the three disagrees with
`casting.json`. Don’t hand-edit inside the markers — edit `casting.json` and
re-run `--write` instead; a hand edit here is exactly what `--check` exists
to catch. Everything outside the markers (this file included) is normal
hand-maintained plugin code.

## Launcher generation mechanics

`_claude_cast_define_launcher` builds a **display** array (what a human
reads via `which`/`list`) and a **fixed** array (what actually runs),
identical except the fixed one may append `CLAUDE_CAST_HEADLESS_FLAGS`. The
fixed array is quoted per-element with `${(q@)fixed}` and spliced into an
`eval "function $name { ... \"\$@\"; }"` — this is the one intentional `eval`
in the file, and it’s safe because every token being quoted came from
`CLAUDE_CAST` (a value the user/config controls), not from `"$@"` at call
time, which is appended unexpanded as a literal `"$@"` in the function body.

Collision handling: `_claude_cast_should_skip` checks the plugin’s own
`_CLAUDE_CAST_GENERATED` registry FIRST — a name we generated ourselves is
always safe to redefine (that’s how `reload`/`set`/`unset` work) — and only
then falls back to `command -v` (which in zsh correctly reports functions,
aliases, builtins, *and* external commands — no need to check `$functions`/
`$aliases`/`$builtins` separately, verified during the build).

`_claude_cast_reload` diffs the *desired* launcher-name set (from current
`CLAUDE_CAST` keys) against `_CLAUDE_CAST_GENERATED`, `unfunction`s anything
we generated that’s no longer wanted (skipping the two prefix-only fixed
helpers, which aren’t tied to any role), then calls `_claude_cast_generate_all`.
This is what makes `claude-cast unset <role>` actually remove the launcher
functions, not just the table row.

## Test strategy

`test/run.zsh` is black-box: each assertion runs the plugin in a fresh,
hermetic `zsh -f -c '...'` subprocess (no rc files) with a stub `claude`
script placed first on `PATH` that prints its argv one-per-line, wrapped as
`>arg<` — a bare empty-line encoding would get silently eaten by `$(...)`‘s
trailing-newline stripping when the last argument is the empty string (the
default headless `--setting-sources ""`), which is exactly the case the
`clpbuild` test needs to catch correctly.

Every test is independent — no shared shell state — because collision tests,
override tests, and `CLAUDE_CAST_FORCE` tests all need different starting
conditions that would interfere with each other in one shared session.

Only `export`‘s JSON gets handed to `node -e` for validation; everything else
stays inside zsh, per the project’s dependency-free constraint.

## Things to not regress

- **Default table values are projected, never hand-edited** — the
  `casting:begin … casting:end` blocks are written by the author’s
  `project-casting.mjs` from the scorecard’s `casting.json`. Edit the source
  and re-project; a hand edit inside the markers is overwritten and flagged.
- **Tests derive expected casting values from the shipped tables** (see the
  comment block at the top of `test/run.zsh`). Never hardcode a model ID,
  effort, role list or role count that comes from a shipped row; literals are
  for values a test injects itself. A recast should need zero test edits.
- **`CLAUDE_CAST_HEADLESS_FLAGS` is an array, not a scalar string.** A scalar
  can’t carry `--setting-sources ""` (an empty-string argument) through
  without the exact hairy-quoting problem this whole plugin exists to avoid
  elsewhere. Keep it an array; document overriding it as array-assignment,
  not as a flags string to `eval`.
- Never write to `settings.json` or any file — this plugin is
  session-launcher generation only, full stop. That’s the whole point
  relative to `/model`.
- **An empty effort field means: no `--effort` flag, not `--effort ''`.**
  `_claude_cast_define_launcher` only appends `--effort "$effort"` when
  `$effort` is non-empty — don’t revert to the unconditional form, it
  breaks every Haiku row across all three presets (`--effort` errors on
  Haiku). `lint`’s unknown-effort check is gated the same way: empty is
  exempt, not a violation.

## Publishing

The owner publishes manually — never run `git push`, `git remote add`, or
create GitHub repos from a session. Preflight before any commit: `zsh
test/run.zsh` green.
