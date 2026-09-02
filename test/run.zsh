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
trap 'rm -rf "$STUB_DIR"' EXIT

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
  PATH="$STUB_DIR:$PATH" zsh -f -c "$1" 2>&1
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
  for r in driver build chore verify orchestrate review sonnet; do
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
# 2. clbuild foo --bar -> exactly --model <model> --effort medium foo --bar
# ---------------------------------------------------------------------------
out=$(run_zsh "source '${PLUGIN}'; clbuild foo --bar")
expected=$'>--model<\n>claude-fable-5-1[1m]<\n>--effort<\n>medium<\n>foo<\n>--bar<'
assert_eq "clbuild foo --bar produces exactly --model <model> --effort medium foo --bar" "$expected" "$out"

# ---------------------------------------------------------------------------
# 3. clpbuild adds the headless flags
# ---------------------------------------------------------------------------
out=$(run_zsh "source '${PLUGIN}'; clpbuild")
expected=$'>--model<\n>claude-fable-5-1[1m]<\n>--effort<\n>medium<\n>-p<\n>--output-format<\n>json<\n>--setting-sources<\n><'
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
expected="command claude --model claude-fable-5-1[1m] --effort medium"
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
    const roles = ["driver","build","chore","verify","orchestrate","review","sonnet"];
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
expected=$'>--model<\n>claude-fable-5-1[1m]<\n>--effort<\n>medium<'
assert_eq "CLAUDE_CAST_FORCE=1 overrides a pre-existing clbuild function" "$expected" "$out"

# ---------------------------------------------------------------------------
# 10. `cl` passes through untouched
# ---------------------------------------------------------------------------
out=$(run_zsh "source '${PLUGIN}'; cl --version")
expected=$'>--version<'
assert_eq "cl passes arguments straight through to claude, uncast" "$expected" "$out"

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
