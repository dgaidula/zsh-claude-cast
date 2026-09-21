# zsh-claude-cast

Zsh launchers generated from a casting table — one line per role, mapping it
to a full Claude Code model ID and effort level — instead of a pile of
hand-maintained shell aliases that drift out of sync with what you actually
meant.

## The problem

Claude Code’s `/model` picker is convenient for one session and dangerous as
a habit: pick a model interactively and the CLI tells you plainly what just
happened —

> Your pick becomes the default for new sessions.

That’s `settings.json` drift. Every `/model` swap you make to try something
for one task quietly becomes the default for the *next* one, on every
project, until you notice and swap it back. `claude --model` and `--effort`
at launch avoid that — they’re session-only — but now the model+effort pair
you actually want per task (a cheap model for chores, a strong one for
verification, a specific pairing for orchestration) lives nowhere except your
memory and whatever alias you hacked together six months ago and forgot to
update after the last model release.

## The casting-table idea

Instead of aliases like `alias cco='claude --model whatever-you-typed-in-2025'`,
define **roles** — `driver`, `fable`, `build`, `fix`, `chore`, `verify`,
`taste`, `orchestrate`, `review` — each mapped to a `model|effort|extra-flags` triple in one zsh
associative array, `CLAUDE_CAST`. The plugin *projects* that table into real
shell functions at load time: `clbuild`, `clverify`, and so on. Change the
table, `claude-cast reload`, and every launcher it produced is regenerated —
no hand-editing scattered `alias` lines, no `settings.json` writes, no
picker-induced drift. The table is the source of truth; the launchers are
just its compiled form.

## Install

Pick whichever matches your setup — all four load the same file.

**oh-my-zsh** — clone (or symlink) into your custom plugins directory and add
it to `plugins=(...)` in `.zshrc`:

```sh
git clone https://github.com/dgaidula/zsh-claude-cast \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-claude-cast
```

```sh
plugins=(... zsh-claude-cast)
```

**Plain `source`** — no framework required:

```sh
source /path/to/zsh-claude-cast/zsh-claude-cast.plugin.zsh
```

**zinit:**

```sh
zinit light dgaidula/zsh-claude-cast
```

**antidote:**

```sh
antidote bundle dgaidula/zsh-claude-cast
```

## The default table

Shipped as-is, in `CLAUDE_CAST`, with full model IDs only — see
[Why full model IDs](#why-full-model-ids). This is the `max20` preset — see
[Plan presets](#plan-presets) for the other two:

<!-- casting:begin -->
| role | model | effort | extra |
|---|---|---|---|
| `driver` | `claude-opus-4-8[1m]` | `high` | — |
| `fable` | `claude-opus-4-8[1m]` | `high` | `--append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md` |
| `build` | `claude-opus-4-8[1m]` | `xhigh` | — |
| `fix` | `claude-opus-4-8[1m]` | `high` | — |
| `chore` | `claude-sonnet-5[1m]` | `low` | — |
| `verify` | `claude-fable-5-1[1m]` | `xhigh` | — |
| `taste` | `claude-fable-5-1[1m]` | `high` | — |
| `orchestrate` | `claude-opus-4-8[1m]` | `high` | `--append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md` |
| `review` | `claude-opus-5` | `medium` | — |
| `sonnet` | `claude-sonnet-5[1m]` | `high` | — |

| role | max20 | max5 | pro |
|---|---|---|---|
| `driver` | `claude-opus-4-8[1m]` `high` | `claude-opus-4-8[1m]` `high` | `claude-sonnet-5[1m]` `high` |
| `fable` | `claude-opus-4-8[1m]` `high` `+ --append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md` | `claude-opus-4-8[1m]` `high` `+ --append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md` | `claude-opus-4-8[1m]` `high` `+ --append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md` |
| `build` | `claude-opus-4-8[1m]` `xhigh` | `claude-sonnet-5[1m]` `high` | `claude-sonnet-5[1m]` `medium` |
| `fix` | `claude-opus-4-8[1m]` `high` | `claude-opus-4-8[1m]` `high` | `claude-opus-4-8[1m]` `high` |
| `chore` | `claude-sonnet-5[1m]` `low` | `claude-haiku-4-5` | `claude-haiku-4-5` |
| `verify` | `claude-fable-5-1[1m]` `xhigh` | `claude-fable-5-1[1m]` `high` | `claude-opus-4-8[1m]` `high` |
| `taste` | `claude-fable-5-1[1m]` `high` | `claude-fable-5-1[1m]` `high` | `claude-opus-4-8[1m]` `high` |
| `orchestrate` | `claude-opus-4-8[1m]` `high` `+ --append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md` | `claude-opus-4-8[1m]` `high` `+ --append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md` | `claude-opus-4-8[1m]` `high` `+ --append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md` |
| `review` | `claude-opus-5` `medium` | `claude-opus-5` `medium` | — |
| `sonnet` | `claude-sonnet-5[1m]` `high` | `claude-sonnet-5[1m]` `high` | `claude-sonnet-5[1m]` `high` |

Generated from the author’s scorecard casting source, commit `174d594`, as of `2026-09-21`.
<!-- casting:end -->

**This default is a snapshot, not a source of truth.** It reflects the
author’s own casting decisions as of **2026-09-03** — a private model
scorecard kept current from a frozen test battery and logged real-use
observations. Yours override it row by row in `.zshrc` (see
[Overriding](#overriding)); the table is an opinion to start from, not a
recommendation to keep.

### How the defaults are generated

The tables between the `<!-- casting:begin -->` / `<!-- casting:end -->`
markers above aren’t hand-copied from the scorecard — they’re *generated*
from it. `claude-ops/casting.json` (the author’s private scorecard repo) is
the one machine-readable casting source; `claude-ops/routines/project-casting.mjs
--write` renders it into this README, into the matching markers in
`zsh-claude-cast.plugin.zsh` itself, and into the author’s global Claude
Code instructions, stamping each block with the source commit and date.
`--check` re-renders every block in memory and fails if any of them
disagrees with `casting.json` — it runs in the author’s release routine
before a version is tagged, so a hand-edited table inside the markers (or a
scorecard change nobody projected) can’t ship unnoticed. Projections all the
way down.

## Plan presets

The table above assumes a Claude Max 20x plan. Not everyone is on that
plan, so `zsh-claude-cast` ships two more, selected by `CLAUDE_CAST_PRESET`
(set before sourcing, default `max20`):

- **`max20`** — Claude Max 20x. The table above: Opus 4.8 carries `driver`
  and `build` (Fable draws from a 50% weekly bucket on this plan, not
  unlimited quota), and Fable 5.1 is reserved for `verify` and `taste` —
  the two roles the maintainer’s battery found no Opus-plus-skill crossover
  for. `fable` and `orchestrate` get Fable-mode rigor a different way: Opus
  4.8 with the fable-mode skill appended (see [Why `fable` and
  `orchestrate` run Opus, not
  Fable](#why-fable-and-orchestrate-run-opus-not-fable)).
- **`max5`** — Claude Max 5x. Same shape as `max20`, one tier down on
  `chore`: it drops to `claude-haiku-4-5` (no effort) instead of a cheap
  Sonnet pass.
- **`pro`** — Claude Pro. Sonnet-led throughout (`driver` and `build` run
  `claude-sonnet-5[1m]`), `verify`/`taste`/`orchestrate` fall back to Opus
  instead of Fable, and there’s no `review` row at all — Opus 5 isn’t
  assumed to be worth spending on Pro.

```sh
CLAUDE_CAST_PRESET=max5
source /path/to/zsh-claude-cast.plugin.zsh
```

An unknown value falls back to `max20`, with a note on stderr.

These three tables are **opinions**, not a spec — a rough plan-ceiling
matrix of what the maintainer casts on each plan (how much of a model a
plan’s quota can actually absorb before it stops being worth reaching for).
Yours may differ. A row you set before sourcing (or via `CLAUDE_CAST_FILE`)
still overrides the matching preset row exactly as described in
[Overriding](#overriding) — the preset only fills in what you didn’t set.
Run `claude-cast presets` to print all three tables at once, and
`claude-cast list` to see the active preset and anything you overrode from
it, e.g. `preset: pro (overridden: chore)`.

## Why `fable` and `orchestrate` run Opus, not Fable

The shipped `fable` and `orchestrate` rows don’t run the Fable model at
all — they run `claude-opus-4-8[1m]` with a third `|`-separated field, an
`extra` flags string: `--append-system-prompt-file
~/.claude/skills/fable-mode/SKILL.md`. That’s the maintainer’s own
Fable-mode skill, appended at launch to give Opus 4.8 Fable’s planning and
verification habits without spending the Fable weekly bucket on roles the
2026-09-01/02 battery found no measurable difference on. `verify` and
`taste` don’t get this treatment — those are the two roles where the
battery found Fable 5.1 still wins outright, so they run the real model.

`extra` is free text, split on shell-word boundaries at launch — point it
at your own system-prompt file (or any other flags), or blank it to run a
plain row with no third field:

```sh
CLAUDE_CAST[fable]='claude-opus-4-8[1m]|high|--append-system-prompt-file ~/my-skill/SKILL.md'
CLAUDE_CAST[orchestrate]='claude-opus-4-8[1m]|high'   # no extra field: bare Opus
```

A leading `~` in any extra-flag word expands to `$HOME` at launch time.
The row itself is a plain string (a heredoc line, or a value you typed into
`CLAUDE_CAST[...]`), so `~` doesn’t expand on its own the way it would if
you’d typed the path directly on a command line — the plugin expands it for
you when the launcher actually runs. `claude-cast which` prints the
already-expanded form, so what you see is what runs.

## Overriding

Two ways in, both merge into the defaults rather than replacing the whole
table — a row you set wins over the shipped default for that role, every
other default role is untouched.

**Before sourcing**, declare the array and set the rows you care about:

```sh
typeset -gA CLAUDE_CAST
CLAUDE_CAST[build]='claude-opus-4-8[1m]|high'
source /path/to/zsh-claude-cast.plugin.zsh
```

(zsh requires the array to be declared with `typeset -gA` before you can
assign a subscript — the plugin declares it for you if you don’t, but only
*before* it sees your overrides, so declare-then-assign has to happen first
in your `.zshrc`.)

**At runtime**, once the plugin is loaded:

```sh
claude-cast set build claude-opus-4-8[1m] high
claude-cast unset chore
```

Both regenerate the affected launchers immediately — no `reload` needed
after `set`/`unset` specifically (they call it for you); `reload` is for
after you edit `CLAUDE_CAST[...]` directly.

`<effort>` can be `-` (or `""`) for a role that shouldn’t get an `--effort`
flag at all — Haiku errors on `--effort`, so its row needs one of those, e.g.
`claude-cast set chore claude-haiku-4-5 -`. The same holds for a row set
directly in `CLAUDE_CAST[...]`: `'claude-haiku-4-5|'` (empty effort field)
or `'claude-haiku-4-5||--some-flag'` (empty effort, with extra flags) both
mean no `--effort` flag.

## Launcher list

For every role in `CLAUDE_CAST`, with prefix `CLAUDE_CAST_PREFIX` (default
`cl`):

| launcher | headless variant | runs |
|---|---|---|
| `cl<role>` | `clp<role>` | `command claude --model <model> --effort <effort> <extra> "$@"` |

Passthrough args work normally: `clbuild --continue`, `clbuild -p "fix the thing"`.
A role with an empty effort field drops `--effort <effort>` from that line
entirely — see [empty-effort semantics](#overriding).

Plus two fixed helpers, not tied to any role:

| launcher | runs |
|---|---|
| `cl` | `command claude "$@"` — bare, whatever `settings.json` says, deliberately not cast |
| `clr` | `command claude --continue "$@"` |

With the default table and prefix, that’s `cldriver`, `clfable`, `clbuild`,
`clfix`, `clchore`, `clverify`, `cltaste`, `clorchestrate`, `clreview`,
`clsonnet` (plus their `clp*` headless twins), `cl`, and `clr`.

**Collision safety.** If a name the plugin would generate already resolves
to a command, alias, function, or builtin — from your own `.zshrc`, another
plugin, or a prior `zsh-claude-cast` load — it’s skipped, and the plugin
prints one summary line at load naming everything it skipped. Set
`CLAUDE_CAST_FORCE=1` before sourcing to override and take the name anyway.

## `claude-cast` subcommands

```
claude-cast              # list (default)
claude-cast list
claude-cast which <launcher-or-role>
claude-cast set <role> <model> <effort|-> [flags...]
claude-cast unset <role>
claude-cast argv <role>
claude-cast export
claude-cast presets
claude-cast lint
claude-cast doctor [--fetch] [--brief]
claude-cast reload
claude-cast help
claude-cast version
```

- **`list`** — a header line naming the active preset and any roles you
  overrode from it (see [Plan presets](#plan-presets)), then an aligned
  table: role, launcher, model, effort, extra flags.
- **`which <launcher-or-role>`** — prints the exact command line a launcher
  runs, e.g. `claude-cast which build` or `claude-cast which clbuild` both
  print `command claude --model claude-opus-4-8[1m] --effort xhigh`; a role
  with an `extra` field (e.g. `claude-cast which fable`) shows it appended,
  with any leading `~` already expanded to `$HOME`.
- **`set` / `unset`** — see [Overriding](#overriding).
- **`argv <role>`** — prints the launch arguments a role resolves to, one
  token per line, with no `claude` word: `--model <id>`, then `--effort
  <level>` when the effort is non-empty, then each `extra` token with any
  leading `~` expanded to `$HOME` — exactly what the launcher runs. Meant for
  a script that wants to build its own `claude` invocation from the table
  (`args=(); while IFS= read -r a; do args+=("$a"); done < <(claude-cast argv build); command claude "${args[@]}"`).
  An unknown role prints a message on stderr and returns 1.
- **`export`** — the table as JSON on stdout, sorted by role, with a
  top-level `"preset"` field and a top-level `"agents"` map
  (agent-definition name → role, `{}` when empty), for scripting or
  inspection (`claude-cast export | jq .`).
- **`presets`** — prints all three shipped preset tables (`max20`, `max5`,
  `pro`), one after another, regardless of which one is currently active.
- **`lint`** — warns on: a bare alias model name (`fable`, `opus`, `sonnet`,
  `haiku`, `best`, `default` — see [Why full model
  IDs](#why-full-model-ids)); any Haiku-model row that sets a *non-empty*
  effort (the `--effort` flag errors on Haiku — an empty effort field is
  exactly how a Haiku row avoids the warning, see
  [Overriding](#overriding)); an effort value outside
  `low`/`medium`/`high`/`xhigh`/`max` (an empty effort is exempt from this
  one too). Exits 1 if it found anything to warn about, 0 otherwise — wire
  it into a dotfiles CI check if you want your casting table linted on
  every commit.
- **`doctor [--fetch] [--brief]`** — a one-shot health check of this
  machine: runs `lint`, checks each mapped agent definition against the
  table (see [Agent definitions and the launch
  check](#agent-definitions-and-the-launch-check)), and, if `chezmoi` is on
  `PATH`, reports how many commits its source is behind upstream (using the
  refs already fetched — `--fetch` refreshes them first, bounded so a dead
  network can’t hang it). Exit 0 when clean, 1 on drift; a condition it can’t
  evaluate — a lag it can’t measure because there’s no upstream tracking
  branch, an agent file it can’t read — is a `WARN` that still exits 0.
  `--brief` collapses it to a single line, e.g.
  `claude-cast doctor: OK agents=4 chezmoi=behind:0`.
- **`reload`** — regenerates launchers from the current `CLAUDE_CAST`
  contents; use after editing the array directly (`set`/`unset` already call
  this for you).

## Headless variants

`clp<role>` runs the same cast plus a fixed set of headless flags, default
`-p --output-format json --setting-sources ""` (scriptable, no interactive
picker, no project/user settings layered in). Override the whole set before
sourcing:

```sh
CLAUDE_CAST_HEADLESS_FLAGS=(-p --output-format json)
source /path/to/zsh-claude-cast.plugin.zsh
```

It’s a zsh array, not a string — that’s what lets it carry the empty
`--setting-sources ""` argument cleanly instead of fighting shell quoting to
smuggle an empty string through a scalar variable.

## Agent definitions and the launch check

A launcher is one way to cast a model; an agent framework that reads
per-agent definition files (a `model:`/`effort:` frontmatter per agent) is
another. If you use both, the two can drift: the launcher table says one
thing, a hand-edited agent file on this machine says another, and the wrong
model runs. **A casting table is only as good as the agent definitions on
the machine that actually launches** — so the plugin can check them, locally,
at zero token cost.

`CLAUDE_CAST_AGENTS` is an associative array mapping an agent-definition name
to a role, filled at load from a shipped default (generated from the same
casting source as the tables) and overridable exactly like `CLAUDE_CAST` — a
value you set before sourcing wins, the rest come from the default:

```sh
typeset -gA CLAUDE_CAST_AGENTS
CLAUDE_CAST_AGENTS[builder]='build'   # your agent file builder.md should match the `build` row
source /path/to/zsh-claude-cast.plugin.zsh
```

`CLAUDE_CAST_AGENTS_DIR` (default `$HOME/.claude/agents`) is where those
`<agent>.md` files live. For each mapped agent, the check compares its
frontmatter `model:`/`effort:` against the role’s table entry (the model with
any trailing `[...]` suffix stripped, since frontmatter doesn’t take it) and
reports `ok`, `mismatch` (which field, have vs want), `missing` (no file),
`unreadable` (exists but can’t be read), or `unknown-role` (mapped to a role
not in the table). The parser is forgiving of real YAML — CRLF line endings, a
leading UTF-8 BOM, trailing whitespace on a fence, quoted values, and a
trailing `# comment` are all tolerated — so only a genuinely different value
trips it. It’s pure zsh file reads — no subprocess — so it’s cheap enough to
run at launch. Run it on demand with
[`claude-cast doctor`](#claude-cast-subcommands).

**The launch check.** Every generated launcher runs that check — existing
files only, mismatch only — right before `command claude`, governed by
`CLAUDE_CAST_LAUNCH_CHECK` (matched case-insensitively; an unrecognised value
prints a one-line notice and behaves as `warn`):

- **`warn`** (default) — print the mismatch and a hint to stderr, then launch
  anyway. The default is deliberately non-blocking: an upgrade can’t stop you
  from launching Claude.
- **`ask`** — on a mismatch, print it and a hint to stderr, then prompt
  `launch anyway? [y/N]` if stdin and stderr are both TTYs (default No). If
  there’s no TTY to confirm (a script, a headless `clp<role>`), it refuses
  without prompting and returns 3, so a drifted definition can’t silently
  launch the wrong model in automation. Recommended when your agent files are
  generated from the same casting table (so any mismatch is real drift worth
  stopping for).
- **`off`** — skip the check entirely.

With no mismatch there’s zero output and no behaviour change.

**If you already keep agent files that intentionally differ.** Upgrading with
a `builder.md` / `fixer.md` / `chore.md` / `verifier.md` that names other
models means the default `warn` prints one drift line per launch (it still
launches). Three ways to quiet it:

- **Disable the whole check** — set an empty map before sourcing:
  `typeset -gA CLAUDE_CAST_AGENTS; CLAUDE_CAST_AGENTS=()` (then `source …`).
  `claude-cast doctor` reports `agents=0`, skipped.
- **Opt one agent out** — map it to the empty string:
  `CLAUDE_CAST_AGENTS[builder]=''` before sourcing. That agent is skipped
  silently by both the launch check and `doctor`; the rest still come from the
  defaults and are still checked.
- **Turn the launch check off** — `export CLAUDE_CAST_LAUNCH_CHECK=off`
  (leaves `claude-cast doctor` available for an on-demand check).

## Per-machine casting

Two ways to vary the table by host, both documented rather than baked in,
since the right one depends on how much you want in `.zshrc` versus a
separate file.

**A `case` on hostname**, directly in `.zshrc` before sourcing the plugin:

```sh
typeset -gA CLAUDE_CAST
case "$(hostname -s)" in
  mbp)      CLAUDE_CAST[driver]='claude-fable-5-1[1m]|high' ;;
  m4-mini)  CLAUDE_CAST[driver]='claude-opus-4-8[1m]|high'  ;;
esac
source /path/to/zsh-claude-cast.plugin.zsh
```

**`CLAUDE_CAST_FILE`** — a zsh file sourced before the table is generated,
for people who’d rather keep the casting table out of `.zshrc` entirely
(dotfiles-managed, per-machine, whatever):

```sh
export CLAUDE_CAST_FILE=~/.config/zsh/claude-cast-table.zsh
source /path/to/zsh-claude-cast.plugin.zsh
```

`CLAUDE_CAST_FILE` is sourced first, so it can declare `CLAUDE_CAST` and set
rows exactly like the inline `case` above; both approaches merge the same
way described in [Overriding](#overriding).

## Completion

If a `_claude` completion function is defined by the time compinit has run
(from Claude Code’s own completions, or another plugin), every generated
launcher gets `compdef _claude <launcher>` wired up automatically — flags
like `--model`/`--effort`/`-p` complete on `clbuild` exactly as they would on
bare `claude`. The plugin doesn’t assume load order: it tries once at
source time and again on your first `claude-cast` call, so it works whether
`zsh-claude-cast` loads before or after `compinit` and `_claude`.

## Pairing with a completion plugin

`zsh-claude-cast` only generates launchers — it deliberately doesn’t ship its
own `claude` completion. Load a completion plugin alongside it (e.g.
[itsdevcoffee/claude-code-zsh](https://github.com/itsdevcoffee/claude-code-zsh)
or [wbingli/zsh-claudecode-completion](https://github.com/wbingli/zsh-claudecode-completion))
and the [Completion](#completion) wiring above picks up its `_claude`
function for free on every `cl*` launcher.

## Why full model IDs

`claude-cast lint` warns on bare alias names (`fable`, `opus`, `sonnet`,
`haiku`, `best`, `default`) rather than full model IDs
(`claude-fable-5-1[1m]`, `claude-opus-4-8[1m]`, …) on purpose: aliases
re-resolve to whatever Anthropic currently maps them to, silently, across
releases. A casting table is supposed to be a deliberate, inspectable record
of what you decided to run for a given role — `claude-cast export`,
`claude-cast which`, and `git blame` on your dotfiles are only useful if the
model column actually says what ran. Full IDs pin that; aliases don’t.

## Development

```sh
zsh test/run.zsh
```

Dependency-free — the suite puts a stub `claude` script first on `PATH`
(prints its argv, one token per line) and drives the plugin against it in
hermetic `zsh -f` subprocesses. The one exception: `export`‘s JSON output is
validated with `node -e`, since parsing JSON correctly is not something to
hand-roll in shell.

## License

MIT © Danniel T. Gaidula
