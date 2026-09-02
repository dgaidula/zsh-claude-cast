# zsh-claude-cast

Zsh launchers generated from a casting table — one line per role, mapping it
to a full Claude Code model ID and effort level — instead of a pile of
hand-maintained shell aliases that drift out of sync with what you actually
meant.

## The problem

Claude Code's `/model` picker is convenient for one session and dangerous as
a habit: pick a model interactively and the CLI tells you plainly what just
happened —

> Your pick becomes the default for new sessions.

That's `settings.json` drift. Every `/model` swap you make to try something
for one task quietly becomes the default for the *next* one, on every
project, until you notice and swap it back. `claude --model` and `--effort`
at launch avoid that — they're session-only — but now the model+effort pair
you actually want per task (a cheap model for chores, a strong one for
verification, a specific pairing for orchestration) lives nowhere except your
memory and whatever alias you hacked together six months ago and forgot to
update after the last model release.

## The casting-table idea

Instead of aliases like `alias cco='claude --model whatever-you-typed-in-2025'`,
define **roles** — `driver`, `build`, `chore`, `verify`, `orchestrate`,
`review` — each mapped to a `model|effort|extra-flags` triple in one zsh
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
[Why full model IDs](#why-full-model-ids):

| role | model | effort |
|---|---|---|
| `driver` | `claude-fable-5-1[1m]` | `high` |
| `build` | `claude-fable-5-1[1m]` | `medium` |
| `chore` | `claude-fable-5-1[1m]` | `low` |
| `verify` | `claude-fable-5-1[1m]` | `xhigh` |
| `orchestrate` | `claude-opus-4-8[1m]` | `high` |
| `review` | `claude-opus-5` | `medium` |
| `sonnet` | `claude-sonnet-5[1m]` | `high` |

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
assign a subscript — the plugin declares it for you if you don't, but only
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

## Launcher list

For every role in `CLAUDE_CAST`, with prefix `CLAUDE_CAST_PREFIX` (default
`cl`):

| launcher | headless variant | runs |
|---|---|---|
| `cl<role>` | `clp<role>` | `command claude --model <model> --effort <effort> <extra> "$@"` |

Passthrough args work normally: `clbuild --continue`, `clbuild -p "fix the thing"`.

Plus two fixed helpers, not tied to any role:

| launcher | runs |
|---|---|
| `cl` | `command claude "$@"` — bare, whatever `settings.json` says, deliberately not cast |
| `clr` | `command claude --continue "$@"` |

With the default table and prefix, that's `cldriver`, `clbuild`, `clchore`,
`clverify`, `clorchestrate`, `clreview`, `clsonnet` (plus their `clp*`
headless twins), `cl`, and `clr`.

**Collision safety.** If a name the plugin would generate already resolves
to a command, alias, function, or builtin — from your own `.zshrc`, another
plugin, or a prior `zsh-claude-cast` load — it's skipped, and the plugin
prints one summary line at load naming everything it skipped. Set
`CLAUDE_CAST_FORCE=1` before sourcing to override and take the name anyway.

## `claude-cast` subcommands

```
claude-cast              # list (default)
claude-cast list
claude-cast which <launcher-or-role>
claude-cast set <role> <model> <effort> [flags...]
claude-cast unset <role>
claude-cast export
claude-cast lint
claude-cast reload
claude-cast help
claude-cast version
```

- **`list`** — aligned table: role, launcher, model, effort, extra flags.
- **`which <launcher-or-role>`** — prints the exact command line a launcher
  runs, e.g. `claude-cast which build` or `claude-cast which clbuild` both
  print `command claude --model claude-fable-5-1[1m] --effort medium`.
- **`set` / `unset`** — see [Overriding](#overriding).
- **`export`** — the table as JSON on stdout, sorted by role, for scripting
  or inspection (`claude-cast export | jq .`).
- **`lint`** — warns on: a bare alias model name (`fable`, `opus`, `sonnet`,
  `haiku`, `best`, `default` — see [Why full model
  IDs](#why-full-model-ids)); any Haiku-model row that sets an effort (the
  `--effort` flag errors on Haiku); an effort value outside
  `low`/`medium`/`high`/`xhigh`/`max`. Exits 1 if it found anything to warn
  about, 0 otherwise — wire it into a dotfiles CI check if you want your
  casting table linted on every commit.
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

It's a zsh array, not a string — that's what lets it carry the empty
`--setting-sources ""` argument cleanly instead of fighting shell quoting to
smuggle an empty string through a scalar variable.

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
for people who'd rather keep the casting table out of `.zshrc` entirely
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
(from Claude Code's own completions, or another plugin), every generated
launcher gets `compdef _claude <launcher>` wired up automatically — flags
like `--model`/`--effort`/`-p` complete on `clbuild` exactly as they would on
bare `claude`. The plugin doesn't assume load order: it tries once at
source time and again on your first `claude-cast` call, so it works whether
`zsh-claude-cast` loads before or after `compinit` and `_claude`.

## Pairing with a completion plugin

`zsh-claude-cast` only generates launchers — it deliberately doesn't ship its
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
model column actually says what ran. Full IDs pin that; aliases don't.

## Development

```sh
zsh test/run.zsh
```

Dependency-free — the suite puts a stub `claude` script first on `PATH`
(prints its argv, one token per line) and drives the plugin against it in
hermetic `zsh -f` subprocesses. The one exception: `export`'s JSON output is
validated with `node -e`, since parsing JSON correctly is not something to
hand-roll in shell.

## License

MIT © Danniel T. Gaidula
