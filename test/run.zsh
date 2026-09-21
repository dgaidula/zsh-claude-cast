#!/usr/bin/env zsh
# Dependency-free test suite for zsh-claude-cast.
#
# Run with: zsh test/run.zsh
#
# Each assertion runs the plugin in a fresh, hermetic zsh subprocess (-f, no
# rc files) with a stub `claude` script placed first on PATH. The stub prints
# its argv one-per-line, wrapped as ">arg<" so an empty argument (e.g. the
# default headless `--setting-sources ""`) still shows up as a real line
# instead of vanishing under command-substitution trailing-newline stripping.
#
# Only `node -e` (to validate the `export` subcommand's JSON) reaches outside
# zsh — everything else is dependency-free.

SCRIPT_DIR="${0:A:h}"
REPO_DIR="${SCRIPT_DIR:h}"
PLUGIN="${REPO_DIR}/zsh-claude-cast.plugin.zsh"

STUB_DIR="$(mktemp -d)"
# An empty agent-definition dir, so the launch-time agent check (added 0.5.0)
# finds every mapped agent "missing" — never a mismatch — and stays silent by
# default. Without this, run_zsh would read the real ~/.claude/agents on the
# host and a launcher's guard could fire mid-test. Tests that exercise the
# check set CLAUDE_CAST_AGENTS_DIR themselves inside the snippet.
AGENTS_EMPTY_DIR="$(mktemp -d)"
# A minimal bin holding only the externals the plugin needs at load/doctor time
# and NO chezmoi, so the "chezmoi not on PATH — skipped" assertions hold on any
# host (F11 — an AlmaLinux box has /usr/bin/chezmoi, which PATH=/usr/bin:/bin
# would fail to hide). Symlinked, not copied, so it tracks the host's binaries.
NOCZ_BIN="$(mktemp -d)"
for _c in cat sleep git; do
  _src="$(command -v $_c)" && ln -s "$_src" "$NOCZ_BIN/$_c"
done
trap 'rm -rf "$STUB_DIR" "$AGENTS_EMPTY_DIR" "$NOCZ_BIN"' EXIT

cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env zsh
for a in "$@"; do
  printf '>%s<\n' "$a"
done
STUB
chmod +x "$STUB_DIR/claude"

typeset -i PASS=0 FAIL=0
typeset -a FAILURES=()

ok() {
  (( PASS++ ))
  print -- "  ok - $1"
}

bad() {
  (( FAIL++ ))
  FAILURES+=("$1")
  print -u2 -- "  NOT OK - $1"
  print -u2 -- "    expected: ${2}"
  print -u2 -- "    got:      ${3}"
}

# Runs a zsh snippet in a fresh, hermetic subprocess with the stub claude on
# PATH. Prints stdout+stderr merged, preserves the snippet's own exit code.
run_zsh() {
  PATH="$STUB_DIR:$PATH" CLAUDE_CAST_AGENTS_DIR="$AGENTS_EMPTY_DIR" zsh -f -c "$1" 2>&1
}

assert_eq() {
  local label=$1 expected=$2 got=$3
  if [[ "$got" == "$expected" ]]; then
    ok "$label"
  else
    bad "$label" "$expected" "$got"
  fi
}

assert_contains() {
  local label=$1 needle=$2 haystack=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    bad "$label" "*${needle}*" "$haystack"
  fi
}

assert_not_contains() {
  local label=$1 needle=$2 haystack=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    ok "$label"
  else
    bad "$label" "(not) *${needle}*" "$haystack"
  fi
}

print -- "zsh-claude-cast test suite"
print -- "plugin: ${PLUGIN}"
print --

# ---------------------------------------------------------------------------
# 1. launchers exist for every default role
# ---------------------------------------------------------------------------
out=$(run_zsh "
  source '${PLUGIN}'
  for r in driver fable build chore verify taste orchestrate review sonnet; do
    (( \$+functions[cl\$r] )) || print MISSING:\$r
    (( \$+functions[clp\$r] )) || print MISSING:clp\$r
  done
  print DONE
")
if [[ "$out" == *DONE* ]] && [[ "$out" != *MISSING* ]]; then
  ok "launchers exist for every default role (plain + headless)"
else
  bad "launchers exist for every default role (plain + headless)" "DONE, no MISSING" "$out"
fi

# ---------------------------------------------------------------------------
# 2. clbuild foo --bar -> exactly --model <model> --effort xhigh foo --bar
# ---------------------------------------------------------------------------
out=$(run_zsh "source '${PLUGIN}'; clbuild foo --bar")
expected=$'>--model<\n>claude-opus-4-8[1m]<\n>--effort<\n>xhigh<\n>foo<\n>--bar<'
assert_eq "clbuild foo --bar produces exactly --model <model> --effort xhigh foo --bar" "$expected" "$out"

# ---------------------------------------------------------------------------
# 3. clpbuild adds the headless flags
# ---------------------------------------------------------------------------
out=$(run_zsh "source '${PLUGIN}'; clpbuild")
expected=$'>--model<\n>claude-opus-4-8[1m]<\n>--effort<\n>xhigh<\n>-p<\n>--output-format<\n>json<\n>--setting-sources<\n><'
assert_eq "clpbuild adds the default headless flags" "$expected" "$out"

# ---------------------------------------------------------------------------
# 4. a user row set before load overrides a default
# ---------------------------------------------------------------------------
out=$(run_zsh "
  typeset -gA CLAUDE_CAST
  CLAUDE_CAST[build]='custom-model|low'
  source '${PLUGIN}'
  clbuild
")
expected=$'>--model<\n>custom-model<\n>--effort<\n>low<'
assert_eq "a user row set before load overrides the shipped default" "$expected" "$out"

# ---------------------------------------------------------------------------
# 5. claude-cast set / unset regenerate launchers
# ---------------------------------------------------------------------------
out=$(run_zsh "
  source '${PLUGIN}'
  claude-cast set widget my-model xhigh --foo
  (( \$+functions[clwidget] )) && print HASFUNC
  clwidget bar
  claude-cast unset widget
  (( \$+functions[clwidget] )) || print GONE
")
assert_contains "claude-cast set defines a new launcher" "HASFUNC" "$out"
assert_contains "claude-cast set launcher runs with the given model/effort/flags" $'>--model<\n>my-model<\n>--effort<\n>xhigh<\n>--foo<\n>bar<' "$out"
assert_contains "claude-cast unset removes the launcher" "GONE" "$out"

# ---------------------------------------------------------------------------
# 6. `which` output matches, by launcher name and by bare role name
# ---------------------------------------------------------------------------
out_role=$(run_zsh "source '${PLUGIN}'; claude-cast which build")
out_launcher=$(run_zsh "source '${PLUGIN}'; claude-cast which clbuild")
expected="command claude --model claude-opus-4-8[1m] --effort xhigh"
assert_eq "which build" "$expected" "$out_role"
assert_eq "which clbuild" "$expected" "$out_launcher"

# ---------------------------------------------------------------------------
# 7. `export` parses as JSON with every role
# ---------------------------------------------------------------------------
json_out=$(run_zsh "source '${PLUGIN}'; claude-cast export")
print -r -- "$json_out" > "${STUB_DIR}/export.json"
if command -v node >/dev/null 2>&1; then
  if node -e '
    const fs = require("fs");
    const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const roles = ["driver","fable","build","chore","verify","taste","orchestrate","review","sonnet"];
    for (const r of roles) {
      if (!data[r]) { console.error("missing role " + r); process.exit(1); }
      if (typeof data[r].model !== "string" || !data[r].model) { console.error("bad model for " + r); process.exit(1); }
      if (typeof data[r].effort !== "string" || !data[r].effort) { console.error("bad effort for " + r); process.exit(1); }
    }
    process.exit(0);
  ' "${STUB_DIR}/export.json"; then
    ok "export parses as JSON and carries every default role"
  else
    bad "export parses as JSON and carries every default role" "valid JSON, all roles present" "$json_out"
  fi
else
  print -u2 -- "  SKIP - export JSON validation (node not on PATH)"
fi

# ---------------------------------------------------------------------------
# 8. lint exits 1 on an alias-model row, 0 on the defaults
# ---------------------------------------------------------------------------
run_zsh "
  typeset -gA CLAUDE_CAST
  CLAUDE_CAST[bad]='fable|high'
  source '${PLUGIN}'
  claude-cast lint >/dev/null 2>&1
" >/dev/null
rc=$?
if [[ $rc -eq 1 ]]; then
  ok "lint exits 1 on an alias-model row"
else
  bad "lint exits 1 on an alias-model row" "exit 1" "exit $rc"
fi

run_zsh "
  source '${PLUGIN}'
  claude-cast lint >/dev/null 2>&1
" >/dev/null
rc=$?
if [[ $rc -eq 0 ]]; then
  ok "lint exits 0 on the shipped defaults"
else
  bad "lint exits 0 on the shipped defaults" "exit 0" "exit $rc"
fi

# ---------------------------------------------------------------------------
# 9. name-collision skip works, and CLAUDE_CAST_FORCE overrides it
# ---------------------------------------------------------------------------
out=$(run_zsh "
  function clbuild() { print PREDEFINED; }
  source '${PLUGIN}'
  clbuild
")
assert_contains "a pre-existing clbuild function is left alone by default" "PREDEFINED" "$out"
assert_contains "skipping a collision is reported once at load" "skipped 1 launcher(s)" "$out"

out=$(run_zsh "
  function clbuild() { print PREDEFINED; }
  CLAUDE_CAST_FORCE=1
  source '${PLUGIN}'
  clbuild
")
expected=$'>--model<\n>claude-opus-4-8[1m]<\n>--effort<\n>xhigh<'
assert_eq "CLAUDE_CAST_FORCE=1 overrides a pre-existing clbuild function" "$expected" "$out"

# ---------------------------------------------------------------------------
# 10. `cl` passes through untouched
# ---------------------------------------------------------------------------
out=$(run_zsh "source '${PLUGIN}'; cl --version")
expected=$'>--version<'
assert_eq "cl passes arguments straight through to claude, uncast" "$expected" "$out"

# ---------------------------------------------------------------------------
# 11. preset selection changes the table
# ---------------------------------------------------------------------------
out=$(run_zsh "CLAUDE_CAST_PRESET=pro; source '${PLUGIN}'; cldriver")
expected=$'>--model<\n>claude-sonnet-5[1m]<\n>--effort<\n>high<'
assert_eq "CLAUDE_CAST_PRESET=pro changes cldriver's model/effort from the max20 default" "$expected" "$out"

# ---------------------------------------------------------------------------
# 12. pro has no review launcher
# ---------------------------------------------------------------------------
out=$(run_zsh "
  CLAUDE_CAST_PRESET=pro
  source '${PLUGIN}'
  (( \$+functions[clreview] )) && print HASFUNC || print NOFUNC
")
assert_contains "the pro preset defines no clreview launcher" "NOFUNC" "$out"

# ---------------------------------------------------------------------------
# 13. max5's clchore has no --effort flag (empty-effort semantics)
# ---------------------------------------------------------------------------
out=$(run_zsh "CLAUDE_CAST_PRESET=max5; source '${PLUGIN}'; clchore")
expected=$'>--model<\n>claude-haiku-4-5<'
assert_eq "max5's clchore argv is --model claude-haiku-4-5 with no --effort" "$expected" "$out"

# ---------------------------------------------------------------------------
# 14. an unknown preset falls back to max20, with a stderr message
# ---------------------------------------------------------------------------
out=$(run_zsh "CLAUDE_CAST_PRESET=bogus; source '${PLUGIN}'; clbuild")
assert_contains "an unknown preset prints a fallback stderr message" "unknown preset 'bogus'" "$out"
assert_contains "an unknown preset falls back to the max20 build row" $'>--model<\n>claude-opus-4-8[1m]<\n>--effort<\n>xhigh<' "$out"

# ---------------------------------------------------------------------------
# 15. a user override on top of a preset wins, and is reported in `list`
# ---------------------------------------------------------------------------
out=$(run_zsh "
  typeset -gA CLAUDE_CAST
  CLAUDE_CAST[chore]='custom-model|low'
  CLAUDE_CAST_PRESET=pro
  source '${PLUGIN}'
  clchore
  claude-cast list
")
assert_contains "a user row set before load overrides a preset row too" $'>--model<\n>custom-model<\n>--effort<\n>low<' "$out"
assert_contains "claude-cast list's header names the active preset" "preset: pro" "$out"
assert_contains "claude-cast list's header names the overridden role" "overridden: chore" "$out"

# ---------------------------------------------------------------------------
# 16. export includes a preset field
# ---------------------------------------------------------------------------
out=$(run_zsh "CLAUDE_CAST_PRESET=max5; source '${PLUGIN}'; claude-cast export")
assert_contains "export includes a preset field" '"preset": "max5"' "$out"

# ---------------------------------------------------------------------------
# 17. lint exits 0 on the shipped pro and max5 tables
# ---------------------------------------------------------------------------
run_zsh "CLAUDE_CAST_PRESET=pro; source '${PLUGIN}'; claude-cast lint >/dev/null 2>&1" >/dev/null
rc=$?
if [[ $rc -eq 0 ]]; then
  ok "lint exits 0 on the shipped pro table"
else
  bad "lint exits 0 on the shipped pro table" "exit 0" "exit $rc"
fi

run_zsh "CLAUDE_CAST_PRESET=max5; source '${PLUGIN}'; claude-cast lint >/dev/null 2>&1" >/dev/null
rc=$?
if [[ $rc -eq 0 ]]; then
  ok "lint exits 0 on the shipped max5 table"
else
  bad "lint exits 0 on the shipped max5 table" "exit 0" "exit $rc"
fi

# ---------------------------------------------------------------------------
# 18. casting markers are present and well-formed (marker-integrity)
# ---------------------------------------------------------------------------
plugin_src=$(cat "${PLUGIN}")
if [[ "$plugin_src" == *'# casting:begin (generated from claude-ops casting.json @'*'— do not edit by hand)'* ]]; then
  ok "plugin source carries a casting:begin marker with a provenance stamp"
else
  bad "plugin source carries a casting:begin marker with a provenance stamp" "marker present" "missing"
fi
assert_contains "plugin source carries a casting:end marker" $'# casting:end' "$plugin_src"

# ---------------------------------------------------------------------------
# 19. the plugin still loads and behaves correctly with the generated block in
#     place — a regression check for the casting:begin/end marker refactor,
#     not a hand-simplified stand-in.
# ---------------------------------------------------------------------------
out=$(run_zsh "source '${PLUGIN}'; claude-cast presets")
assert_contains "claude-cast presets still prints the generated max20 table" "== max20 ==" "$out"
assert_contains "claude-cast presets still prints the generated max5 table" "== max5 ==" "$out"
assert_contains "claude-cast presets still prints the generated pro table" "== pro ==" "$out"

# ---------------------------------------------------------------------------
# 20. a row's extra flags land in argv after --model/--effort
# ---------------------------------------------------------------------------
out=$(run_zsh "
  typeset -gA CLAUDE_CAST
  CLAUDE_CAST[widget]='custom-model|high|--foo bar --baz'
  source '${PLUGIN}'
  clwidget
")
expected=$'>--model<\n>custom-model<\n>--effort<\n>high<\n>--foo<\n>bar<\n>--baz<'
assert_eq "a row's extra flags appear in argv after --model/--effort" "$expected" "$out"

# ---------------------------------------------------------------------------
# 21. a leading ~ in an extra-flag word expands to \$HOME at launch time, and
#     `claude-cast which` prints the already-expanded form
# ---------------------------------------------------------------------------
out=$(run_zsh "
  export HOME=/home/tester
  typeset -gA CLAUDE_CAST
  CLAUDE_CAST[widget]='custom-model|high|--append-system-prompt-file ~/skills/foo/SKILL.md'
  source '${PLUGIN}'
  clwidget
  claude-cast which widget
")
assert_contains "a leading ~ in an extra flag word expands to \$HOME in argv" $'>--append-system-prompt-file<\n>/home/tester/skills/foo/SKILL.md<' "$out"
assert_contains "claude-cast which prints the tilde-expanded form" "/home/tester/skills/foo/SKILL.md" "$out"
assert_not_contains "claude-cast which does not print the unexpanded ~" "~/skills/foo/SKILL.md" "$out"

# ---------------------------------------------------------------------------
# 22. the shipped max20 fable/orchestrate rows carry a real extra flag whose
#     ~ expands against the actual $HOME of whoever sources the plugin
# ---------------------------------------------------------------------------
out=$(run_zsh "source '${PLUGIN}'; claude-cast which fable")
assert_contains "the shipped fable row's ~ expands to the real \$HOME" "${HOME}/.claude/skills/fable-mode/SKILL.md" "$out"
assert_not_contains "the shipped fable row's which output carries no literal ~" "~/.claude/skills/fable-mode/SKILL.md" "$out"

# ---------------------------------------------------------------------------
# 23. the fix role generates clfix/clpfix, resolving to Opus 4.8 at high
# ---------------------------------------------------------------------------
out=$(run_zsh "source '${PLUGIN}'; (( \$+functions[clfix] )) && print HASFIX; (( \$+functions[clpfix] )) && print HASPFIX; clfix foo")
assert_contains "clfix launcher exists" "HASFIX" "$out"
assert_contains "clpfix launcher exists" "HASPFIX" "$out"
assert_contains "clfix resolves to the max20 fix row (Opus 4.8, high)" $'>--model<\n>claude-opus-4-8[1m]<\n>--effort<\n>high<\n>foo<' "$out"

# ---------------------------------------------------------------------------
# 24. `claude-cast argv <role>` prints resolved launch args, one token per line
# ---------------------------------------------------------------------------
out=$(run_zsh "source '${PLUGIN}'; claude-cast argv build")
assert_eq "argv build prints --model/--effort tokens, one per line, no 'claude' word" $'--model\nclaude-opus-4-8[1m]\n--effort\nxhigh' "$out"

out=$(run_zsh "source '${PLUGIN}'; claude-cast argv fable")
assert_contains "argv fable expands a leading ~ in the extra flag to \$HOME" $'--append-system-prompt-file\n'"${HOME}/.claude/skills/fable-mode/SKILL.md" "$out"
assert_not_contains "argv fable prints no unexpanded ~" "~/.claude/skills/fable-mode/SKILL.md" "$out"

out=$(run_zsh "CLAUDE_CAST_PRESET=max5; source '${PLUGIN}'; claude-cast argv chore")
assert_eq "argv on an empty-effort role omits --effort" $'--model\nclaude-haiku-4-5' "$out"

out=$(run_zsh "source '${PLUGIN}'; claude-cast argv nope; print rc=\$?")
assert_contains "argv on an unknown role warns on stderr" "unknown role: nope" "$out"
assert_contains "argv on an unknown role returns 1" "rc=1" "$out"

# ---------------------------------------------------------------------------
# 25. `export` carries the agents map (and the fix role) as valid JSON
# ---------------------------------------------------------------------------
json_out=$(run_zsh "source '${PLUGIN}'; claude-cast export")
print -r -- "$json_out" > "${STUB_DIR}/export-agents.json"
if command -v node >/dev/null 2>&1; then
  if node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (typeof d.agents !== "object" || d.agents === null) { console.error("no agents object"); process.exit(1); }
    if (d.agents.builder !== "build") { console.error("agents.builder != build"); process.exit(1); }
    if (d.agents.fixer !== "fix") { console.error("agents.fixer != fix"); process.exit(1); }
    if (!d.fix || d.fix.model !== "claude-opus-4-8[1m]") { console.error("fix role missing/wrong"); process.exit(1); }
    if (typeof d.preset !== "string") { console.error("preset key lost"); process.exit(1); }
    process.exit(0);
  ' "${STUB_DIR}/export-agents.json"; then
    ok "export JSON carries the agents map and the fix role, keeping preset"
  else
    bad "export JSON carries the agents map and the fix role, keeping preset" "valid JSON with agents+fix" "$json_out"
  fi
else
  print -u2 -- "  SKIP - export agents JSON validation (node not on PATH)"
fi

# ---------------------------------------------------------------------------
# 26. `claude-cast doctor`: clean / mismatch / missing / convention-not-used.
#     Run with PATH=$NOCZ_BIN (the minimal chezmoi-free bin built above) so
#     `chezmoi` is not found — chezmoi=skipped, so the result does not depend on
#     the host's dotfiles state — while `cat` (used by the generated
#     default-table heredocs) still resolves. A temp CLAUDE_CAST_AGENTS_DIR
#     carries the agent defs under test.
# ---------------------------------------------------------------------------

# Writes an agent .md with the given frontmatter (effort omitted when empty).
write_agent_md() {
  local dir=$1 name=$2 model=$3 effort=$4
  {
    print -- '---'
    print -- "name: $name"
    print -- 'description: fixture'
    print -- "model: $model"
    [[ -n "$effort" ]] && print -- "effort: $effort"
    print -- '---'
    print -- 'body'
  } > "$dir/$name.md"
}

# A dir whose four default-mapped agent defs match the shipped max20 table.
# Coupled to that table on purpose — this is what "in sync" looks like; if the
# build/fix/chore/verify rows change, update these four.
make_clean_agents_dir() {
  local dir=$1
  write_agent_md "$dir" builder  claude-opus-4-8  xhigh
  write_agent_md "$dir" fixer    claude-opus-4-8  high
  write_agent_md "$dir" chore    claude-sonnet-5  low
  write_agent_md "$dir" verifier claude-fable-5-1 xhigh
}

CLEAN_AGENTS="$(mktemp -d)"; make_clean_agents_dir "$CLEAN_AGENTS"
out=$(run_zsh "PATH=$NOCZ_BIN; export CLAUDE_CAST_AGENTS_DIR='$CLEAN_AGENTS'; source '${PLUGIN}'; claude-cast doctor; print rc=\$?")
assert_contains "doctor reports OK when the agent defs match the table" "claude-cast doctor: OK" "$out"
assert_contains "doctor clean lists an ok agent" "builder.md ok" "$out"
assert_contains "doctor skips chezmoi when it is not on PATH" "chezmoi: not on PATH — skipped" "$out"
assert_contains "doctor clean exits 0" "rc=0" "$out"

brief_out=$(run_zsh "PATH=$NOCZ_BIN; export CLAUDE_CAST_AGENTS_DIR='$CLEAN_AGENTS'; source '${PLUGIN}'; claude-cast doctor --brief")
brief_lines=("${(@f)brief_out}")
assert_eq "doctor --brief prints exactly one line" "1" "${#brief_lines}"
assert_contains "doctor --brief OK line names agents and chezmoi state" "claude-cast doctor: OK agents=4 chezmoi=skipped" "$brief_out"

MISMATCH_AGENTS="$(mktemp -d)"; make_clean_agents_dir "$MISMATCH_AGENTS"
write_agent_md "$MISMATCH_AGENTS" builder claude-sonnet-5 xhigh   # wrong model
out=$(run_zsh "PATH=$NOCZ_BIN; export CLAUDE_CAST_AGENTS_DIR='$MISMATCH_AGENTS'; source '${PLUGIN}'; claude-cast doctor --brief; print rc=\$?")
assert_contains "doctor reports DRIFT on a model mismatch" "DRIFT" "$out"
assert_contains "doctor names the mismatched field, have vs want" "builder.md model have=claude-sonnet-5 want=claude-opus-4-8" "$out"
assert_contains "doctor exits 1 on drift" "rc=1" "$out"

MISSING_AGENTS="$(mktemp -d)"; make_clean_agents_dir "$MISSING_AGENTS"; rm -f "$MISSING_AGENTS/fixer.md"
out=$(run_zsh "PATH=$NOCZ_BIN; export CLAUDE_CAST_AGENTS_DIR='$MISSING_AGENTS'; source '${PLUGIN}'; claude-cast doctor; print rc=\$?")
assert_contains "doctor reports a missing mapped agent as drift when others exist" "fixer.md MISSING" "$out"
assert_contains "doctor exits 1 when a mapped agent file is missing" "rc=1" "$out"

out=$(run_zsh "PATH=$NOCZ_BIN; export CLAUDE_CAST_AGENTS_DIR='$AGENTS_EMPTY_DIR'; source '${PLUGIN}'; claude-cast doctor; print rc=\$?")
assert_contains "doctor prints one skipped line when the agent convention is not used" "no mapped agent definitions found — skipped" "$out"
assert_contains "doctor is clean (exit 0) when the agent convention is not used" "rc=0" "$out"

rm -rf "$CLEAN_AGENTS" "$MISMATCH_AGENTS" "$MISSING_AGENTS"

# ---------------------------------------------------------------------------
# 27. launch-time agent check: ask (non-TTY) refuses with 3 and never runs the
#     stub; warn runs it; off is silent; no-mismatch is silent.
# ---------------------------------------------------------------------------
MISMATCH_LAUNCH="$(mktemp -d)"; write_agent_md "$MISMATCH_LAUNCH" builder claude-sonnet-5 xhigh

# ask must be requested explicitly now that the default is warn (F2c).
out=$(run_zsh "export CLAUDE_CAST_AGENTS_DIR='$MISMATCH_LAUNCH'; CLAUDE_CAST_LAUNCH_CHECK=ask; source '${PLUGIN}'; clbuild foo; print rc=\$?")
assert_contains "launch check (ask, non-TTY) prints the mismatch" "builder.md model have=claude-sonnet-5 want=claude-opus-4-8" "$out"
assert_contains "launch check (ask, non-TTY) refuses without a TTY" "refusing to launch" "$out"
assert_contains "launch check (ask, non-TTY) returns 3" "rc=3" "$out"
assert_not_contains "launch check (ask, non-TTY) never runs claude" ">foo<" "$out"

# F2c: the default (no CLAUDE_CAST_LAUNCH_CHECK set) is now warn — a mismatch
# is printed but the launch proceeds, so an upgrade never blocks a launch.
out=$(run_zsh "export CLAUDE_CAST_AGENTS_DIR='$MISMATCH_LAUNCH'; source '${PLUGIN}'; clbuild foo; print rc=\$?")
assert_contains "launch check default warns on drift" "agent definition drift before launch" "$out"
assert_contains "launch check default still launches (warn, not ask)" ">foo<" "$out"
assert_not_contains "launch check default does not refuse" "refusing to launch" "$out"

out=$(run_zsh "export CLAUDE_CAST_AGENTS_DIR='$MISMATCH_LAUNCH'; CLAUDE_CAST_LAUNCH_CHECK=warn; source '${PLUGIN}'; clbuild foo")
assert_contains "launch check (warn) still warns" "agent definition drift before launch" "$out"
assert_contains "launch check (warn) runs claude anyway" ">foo<" "$out"

out=$(run_zsh "export CLAUDE_CAST_AGENTS_DIR='$MISMATCH_LAUNCH'; CLAUDE_CAST_LAUNCH_CHECK=off; source '${PLUGIN}'; clbuild foo")
assert_not_contains "launch check (off) is silent" "agent definition drift" "$out"
assert_contains "launch check (off) runs claude" ">foo<" "$out"

out=$(run_zsh "source '${PLUGIN}'; clbuild foo")
assert_not_contains "launch check with no mismatch is silent" "agent definition drift" "$out"
assert_contains "launch check with no mismatch runs claude normally" $'>--model<\n>claude-opus-4-8[1m]<\n>--effort<\n>xhigh<\n>foo<' "$out"

# F16a: an unknown CLAUDE_CAST_LAUNCH_CHECK value names the valid ones and
# behaves as warn (never silently takes the ask path / refuses in automation).
out=$(run_zsh "export CLAUDE_CAST_AGENTS_DIR='$MISMATCH_LAUNCH'; CLAUDE_CAST_LAUNCH_CHECK=no; source '${PLUGIN}'; clbuild foo; print rc=\$?")
assert_contains "F16a: an unknown launch-check value names the valid ones" "unknown CLAUDE_CAST_LAUNCH_CHECK 'no'" "$out"
assert_contains "F16a: an unknown value behaves as warn (claude runs)" ">foo<" "$out"
assert_not_contains "F16a: an unknown value never refuses in automation" "refusing to launch" "$out"

# F16a: the value is matched case-insensitively, so OFF disables the check.
out=$(run_zsh "export CLAUDE_CAST_AGENTS_DIR='$MISMATCH_LAUNCH'; CLAUDE_CAST_LAUNCH_CHECK=OFF; source '${PLUGIN}'; clbuild foo")
assert_not_contains "F16a: OFF is matched case-insensitively (silent)" "agent definition drift" "$out"
assert_contains "F16a: OFF still launches" ">foo<" "$out"

# F15: no warn_create_global chatter when the guard first populates its globals
# (they are pre-declared at file scope). Uses a clean dir so the check runs.
F15_AGENTS="$(mktemp -d)"; make_clean_agents_dir "$F15_AGENTS"
out=$(run_zsh "export CLAUDE_CAST_AGENTS_DIR='$F15_AGENTS'; source '${PLUGIN}'; setopt warn_create_global; clbuild foo")
assert_not_contains "F15: no 'created globally' warnings when the guard first runs" "created globally" "$out"
assert_contains "F15: the launcher still runs after the guard's clean check" ">foo<" "$out"
rm -rf "$F15_AGENTS"

rm -rf "$MISMATCH_LAUNCH"

# ---------------------------------------------------------------------------
# 28. CLAUDE_CAST_AGENTS shapes: plain-array load (F1), explicit empty-map
#     disable (F2a), per-agent opt-out (F2b). A drifted builder.md would fire
#     the guard / doctor unless the agent is disabled or opted out.
# ---------------------------------------------------------------------------
DRIFT_AGENTS="$(mktemp -d)"; write_agent_md "$DRIFT_AGENTS" builder claude-sonnet-5 xhigh

# F1: a plain (non-association) empty array set before sourcing must not abort
# the load with "invalid subscript range" — launchers exist, no check runs.
out=$(run_zsh "CLAUDE_CAST_AGENTS=(); export CLAUDE_CAST_AGENTS_DIR='$DRIFT_AGENTS'; source '${PLUGIN}'; (( \$+functions[clbuild] )) && print HASFUNC; clbuild foo; print rc=\$?")
assert_contains "F1: a plain-array CLAUDE_CAST_AGENTS=() still defines launchers" "HASFUNC" "$out"
assert_not_contains "F1: a plain-array empty map does not abort load" "invalid subscript" "$out"
assert_contains "F1: a plain-array empty map runs no agent check (claude runs)" ">foo<" "$out"

# F2a: an explicitly empty association disables the check — guard silent and
# launches; doctor prints the (now reachable) skipped line and exits 0.
out=$(run_zsh "typeset -gA CLAUDE_CAST_AGENTS; CLAUDE_CAST_AGENTS=(); export CLAUDE_CAST_AGENTS_DIR='$DRIFT_AGENTS'; source '${PLUGIN}'; clbuild foo")
assert_not_contains "F2a: an empty map keeps the launch guard silent" "agent definition drift" "$out"
assert_contains "F2a: an empty map lets the launch proceed" ">foo<" "$out"
out=$(run_zsh "typeset -gA CLAUDE_CAST_AGENTS; CLAUDE_CAST_AGENTS=(); PATH=$NOCZ_BIN; export CLAUDE_CAST_AGENTS_DIR='$DRIFT_AGENTS'; source '${PLUGIN}'; claude-cast doctor; print rc=\$?")
assert_contains "F2a: doctor prints the skipped line for an empty map" "no agent map configured — skipped" "$out"
assert_contains "F2a: doctor exits 0 for an empty map" "rc=0" "$out"

# F2b: one agent mapped to '' opts that agent out silently; the rest still come
# from the defaults and are still checked. Clean dir + a drifted builder.md.
OPTOUT_AGENTS="$(mktemp -d)"; make_clean_agents_dir "$OPTOUT_AGENTS"
write_agent_md "$OPTOUT_AGENTS" builder claude-sonnet-5 xhigh   # drift builder.md
out=$(run_zsh "typeset -gA CLAUDE_CAST_AGENTS; CLAUDE_CAST_AGENTS[builder]=''; export CLAUDE_CAST_AGENTS_DIR='$OPTOUT_AGENTS'; source '${PLUGIN}'; clbuild foo")
assert_contains "F2b: an agent mapped to '' is skipped by the guard (claude runs)" ">foo<" "$out"
assert_not_contains "F2b: the guard does not flag the opted-out agent" "builder.md" "$out"
out=$(run_zsh "typeset -gA CLAUDE_CAST_AGENTS; CLAUDE_CAST_AGENTS[builder]=''; PATH=$NOCZ_BIN; export CLAUDE_CAST_AGENTS_DIR='$OPTOUT_AGENTS'; source '${PLUGIN}'; claude-cast doctor; print rc=\$?")
assert_not_contains "F2b: doctor ignores an opted-out agent even when its file drifts" "builder.md" "$out"
assert_contains "F2b: defaults still fill and check the other agents" "fixer.md ok" "$out"
assert_contains "F2b: doctor is clean when only the opted-out agent drifts" "rc=0" "$out"
rm -rf "$DRIFT_AGENTS" "$OPTOUT_AGENTS"

# ---------------------------------------------------------------------------
# 29. Frontmatter parser (F5): tolerate real-world YAML instead of
#     false-mismatching it, while still flagging genuinely different values.
#     Table-driven via doctor over a single mapped agent (builder).
# ---------------------------------------------------------------------------
FM_AGENTS="$(mktemp -d)"; make_clean_agents_dir "$FM_AGENTS"
B="$FM_AGENTS/builder.md"
fm_doctor() { run_zsh "PATH=$NOCZ_BIN; export CLAUDE_CAST_AGENTS_DIR='$FM_AGENTS'; source '${PLUGIN}'; claude-cast doctor"; }

# Valid YAML the parser must ACCEPT (builder.md ok):
printf -- '---\r\nname: builder\r\ndescription: x\r\nmodel: claude-opus-4-8\r\neffort: xhigh\r\n---\r\n' > "$B"
assert_contains "F5: CRLF line endings accepted" "builder.md ok" "$(fm_doctor)"
printf -- '---\nname: builder\nmodel: "claude-opus-4-8"\neffort: "xhigh"\n---\n' > "$B"
assert_contains "F5: double-quoted values accepted" "builder.md ok" "$(fm_doctor)"
printf -- "---\nname: builder\nmodel: 'claude-opus-4-8'\neffort: 'xhigh'\n---\n" > "$B"
assert_contains "F5: single-quoted values accepted" "builder.md ok" "$(fm_doctor)"
printf -- '---\nname: builder\nmodel: claude-opus-4-8 # pinned\neffort: xhigh # why\n---\n' > "$B"
assert_contains "F5: inline # comment stripped from values" "builder.md ok" "$(fm_doctor)"
printf -- '--- \nname: builder\nmodel: claude-opus-4-8\neffort: xhigh\n--- \n' > "$B"
assert_contains "F5: a fence with trailing whitespace accepted" "builder.md ok" "$(fm_doctor)"
printf -- '\xef\xbb\xbf---\nname: builder\nmodel: claude-opus-4-8\neffort: xhigh\n---\n' > "$B"
assert_contains "F5: a leading UTF-8 BOM accepted" "builder.md ok" "$(fm_doctor)"
printf -- '---\nname: builder\nmodel: claude-opus-4-8\neffort: xhigh' > "$B"
assert_contains "F5: a final line with no trailing newline accepted" "builder.md ok" "$(fm_doctor)"
printf -- '---\nname: builder\n# model: claude-sonnet-5\nmodel: claude-opus-4-8\neffort: xhigh\n---\n' > "$B"
assert_contains "F5: a '# model:' comment line is not read as the value" "builder.md ok" "$(fm_doctor)"

# Genuinely different values must STILL mismatch (no over-normalization):
printf -- '---\nname: builder\neffort: xhigh\n---\nmodel: claude-opus-4-8\n' > "$B"
assert_contains "F5: model only in the body is a real mismatch" "builder.md MISMATCH" "$(fm_doctor)"
printf -- '---\nname: builder\nmodel: claude-opus-4-8[1m]\neffort: xhigh\n---\n' > "$B"
assert_contains "F5: a [1m] suffix in the file is a real mismatch" "builder.md MISMATCH" "$(fm_doctor)"

# An unreadable file yields one clean UNREADABLE result, no raw zsh error.
printf -- '---\nname: builder\nmodel: claude-opus-4-8\neffort: xhigh\n---\n' > "$B"; chmod 000 "$B"
if [[ -r "$B" ]]; then
  print -u2 -- "  SKIP - F5 unreadable file (readable despite chmod 000, likely running as root)"
else
  out="$(fm_doctor)"
  assert_contains "F5: an unreadable file yields a clean UNREADABLE result" "builder.md UNREADABLE" "$out"
  assert_not_contains "F5: an unreadable file prints no raw zsh error" "permission denied" "$out"
fi
chmod 644 "$B"
rm -rf "$FM_AGENTS"

# ---------------------------------------------------------------------------
# 30. doctor lag (F13): a chezmoi source with no upstream is a WARN, not OK —
#     reported, but exit 0 (only DRIFT exits 1). Uses a chezmoi stub + a fresh
#     git repo (a branch with no upstream) on a curated PATH.
# ---------------------------------------------------------------------------
CZ_BIN="$(mktemp -d)"
for _c in cat sleep git; do _src="$(command -v $_c)" && ln -s "$_src" "$CZ_BIN/$_c"; done
cat > "$CZ_BIN/chezmoi" <<'CZSTUB'
#!/bin/sh
[ "$1" = source-path ] && { printf '%s\n' "$CZ_SRC"; exit 0; }
exit 1
CZSTUB
chmod +x "$CZ_BIN/chezmoi"
CZ_REPO="$(mktemp -d)"
git -C "$CZ_REPO" init -q >/dev/null 2>&1
git -C "$CZ_REPO" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1
brief=$(run_zsh "PATH=$CZ_BIN; export CZ_SRC='$CZ_REPO' CLAUDE_CAST_AGENTS_DIR='$AGENTS_EMPTY_DIR'; source '${PLUGIN}'; claude-cast doctor --brief; print rc=\$?")
assert_contains "F13: doctor --brief is WARN when lag can't be measured" "claude-cast doctor: WARN" "$brief"
assert_contains "F13: a WARN still exits 0 (only DRIFT exits 1)" "rc=0" "$brief"
human=$(run_zsh "PATH=$CZ_BIN; export CZ_SRC='$CZ_REPO' CLAUDE_CAST_AGENTS_DIR='$AGENTS_EMPTY_DIR'; source '${PLUGIN}'; claude-cast doctor")
assert_contains "F13: doctor names the no-upstream lag warning" "cannot measure lag (no upstream)" "$human"
rm -rf "$CZ_BIN" "$CZ_REPO"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print --
print -- "----------------------------------------"
print -- "PASS: ${PASS}  FAIL: ${FAIL}"
if (( FAIL > 0 )); then
  print -- "Failed:"
  for f in "${FAILURES[@]}"; do
    print -- "  - $f"
  done
  exit 1
fi
print -- "All tests passed."
exit 0
