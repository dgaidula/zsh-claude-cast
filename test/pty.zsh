#!/usr/bin/env zsh
# Interactive launch-guard tests for zsh-claude-cast, run under a real
# pseudo-terminal.
#
# Run with: zsh test/pty.zsh   (also invoked as the last section of run.zsh,
# which folds this file's PASS/FAIL tally into its own totals.)
#
# The generated launchers gate on `_claude_cast_launch_guard` before
# `command claude`. When an agent definition disagrees with the casting table
# and CLAUDE_CAST_LAUNCH_CHECK=ask, the guard prompts `launch anyway? [y/N]`
# ONLY when stdin AND stderr are both terminals; otherwise it refuses (exit 3).
# run.zsh drives the plugin over pipes, so that interactive branch — the one a
# human actually hits at the keyboard — has no coverage there. These cases
# exercise it for real: each launcher runs inside a pty (zsh's own zsh/zpty
# module, so no `script`/`expect` and nothing to install on the Ubuntu CI
# runner), the prompt is waited for before any input is sent, and every wait is
# bounded by a timeout so a hang fails the case instead of hanging CI.
#
# Each case is hermetic: a temp HOME, a temp CLAUDE_CAST_AGENTS_DIR holding a
# deliberately mismatched builder.md, and a stub `claude` first on PATH that
# APPENDS its argv to a file — so "launched" vs "never launched" is a file
# check, never output parsing. The stub exits with STUB_RC (7 here), so an
# assertion can prove the launcher returns the stub's own exit status.
#
# Dependency-free: zsh builtins and modules only (zpty, datetime, zselect).

SCRIPT_DIR="${0:A:h}"
REPO_DIR="${SCRIPT_DIR:h}"
PLUGIN="${REPO_DIR}/zsh-claude-cast.plugin.zsh"

typeset -i PASS=0 FAIL=0
typeset -a FAILURES=()

ok()  { (( PASS++ )); print -- "  ok - $1"; }
bad() {
  (( FAIL++ )); FAILURES+=("$1")
  print -u2 -- "  NOT OK - $1"
  print -u2 -- "    expected: ${2}"
  print -u2 -- "    got:      ${3}"
}
assert_eq()           { [[ "$3" == "$2"   ]] && ok "$1" || bad "$1" "$2" "$3"; }
assert_contains()     { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "*${2}*" "$3"; }
assert_not_contains() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "NOT *${2}*" "$3"; }

summary() {
  print --
  print -- "----------------------------------------"
  print -- "PASS: ${PASS}  FAIL: ${FAIL}"
  if (( FAIL > 0 )); then
    print -- "Failed:"
    local f; for f in "${FAILURES[@]}"; do print -- "  - $f"; done
    exit 1
  fi
  print -- "All pty tests passed."
  exit 0
}

# zsh/zpty is the whole point; if it can't load, say so loudly and count zero —
# never a silent pass.
if ! zmodload zsh/zpty 2>/dev/null; then
  print -- "SKIP: zsh/zpty unavailable — interactive guard branch NOT tested"
  summary
fi
zmodload zsh/datetime
if zmodload zsh/zselect 2>/dev/null; then
  _pty_nap() { zselect -t 2 2>/dev/null; }   # ~20ms poll between reads
else
  _pty_nap() { command sleep 0.02 2>/dev/null; }
fi

PTY_TIMEOUT=8   # seconds; the ceiling on every wait, so a hang fails a case

# Writes a builder.md whose model/effort either match the max20 `build` row
# (claude-opus-5-5 / xhigh) or deliberately disagree with it.
_pty_write_builder() {
  local dir=$1 kind=$2 model effort
  if [[ $kind == mismatch ]]; then model=claude-sonnet-5; effort=low
  else                              model=claude-opus-5-5;  effort=xhigh; fi
  {
    print -- '---'; print -- 'name: builder'; print -- 'description: fixture'
    print -- "model: $model"; print -- "effort: $effort"
    print -- '---'; print -- 'body'
  } > "$dir/builder.md"
}

# Silent stub claude: append argv to $STUB_REC/argv, exit $STUB_RC. Silent so
# a "no extra output" assertion means the guard printed nothing.
_pty_write_stub() {
  cat > "$1/claude" <<'STUB'
#!/usr/bin/env zsh
R="${STUB_REC:?}"
{ print -r -- "argc=$#"; for a in "$@"; do print -r -- "arg=[$a]"; done } >> "$R/argv"
exit ${STUB_RC:-0}
STUB
  chmod +x "$1/claude"
}

# Runs one launcher under a pty via a throwaway `zsh -f` driver, optionally
# answering the prompt, and reports back through globals:
#   PTY_RAN (yes|no)  PTY_RC (e.g. RC=7, or empty if the child never wrote it)
#   PTY_PROMPTED (yes|no)  PTY_BUF (everything the pty emitted)  PTY_ERR (the
#   captured-stderr file's contents, for the redirected-stderr case)
#
# Args: MODE(ask|warn) MATCH(match|mismatch) REDIR(direct|redir) ANSWER
# ANSWER ∈ y|Y|yes|n|enter|x|eof|none  (none = expect no prompt, send nothing).
pty_case() {
  local mode=$1 match=$2 redir=$3 answer=$4
  local SB; SB="$(mktemp -d)"
  mkdir -p "$SB/home" "$SB/agents" "$SB/bin" "$SB/rec"
  _pty_write_builder "$SB/agents" "$match"
  _pty_write_stub "$SB/bin"

  local redir_frag=""
  [[ $redir == redir ]] && redir_frag=" 2>\"$SB/err\""
  print -r -- "source \"$PLUGIN\"; clbuild 'arg one'${redir_frag}; print -r -- \"RC=\$?\" > \"$SB/rc\"" > "$SB/driver.zsh"

  export HOME="$SB/home" PATH="$SB/bin:/usr/bin:/bin"
  export STUB_REC="$SB/rec" STUB_RC=7
  export CLAUDE_CAST_AGENTS_DIR="$SB/agents" CLAUDE_CAST_LAUNCH_CHECK=$mode

  PTY_BUF="" PTY_RAN=no PTY_RC="" PTY_PROMPTED=no PTY_ERR=""
  local chunk deadline
  zpty -b _cc "zsh -f $SB/driver.zsh"

  if [[ $answer != none ]]; then
    # Wait for the prompt text before sending anything (pattern is the sync;
    # the nap only avoids a busy-spin), bounded by PTY_TIMEOUT.
    deadline=$(( EPOCHREALTIME + PTY_TIMEOUT ))
    while true; do
      while zpty -r -t _cc chunk 2>/dev/null; do PTY_BUF+="$chunk"; done
      [[ "$PTY_BUF" == *"launch anyway?"* ]] && break
      zpty -t _cc 2>/dev/null || break               # child exited before prompting
      (( EPOCHREALTIME > deadline )) && break          # timed out -> fail downstream
      _pty_nap
    done
    if [[ "$PTY_BUF" == *"launch anyway?"* ]]; then
      case $answer in
        y)     zpty -w _cc "y" ;;
        Y)     zpty -w _cc "Y" ;;
        yes)   zpty -w _cc "yes" ;;
        n)     zpty -w _cc "n" ;;
        x)     zpty -w _cc "x" ;;
        enter) zpty -w -n _cc $'\n' ;;      # bare Enter = empty line
        eof)   zpty -w -n _cc $'\004' ;;    # Ctrl-D at the prompt
      esac
    fi
  fi

  # Wait for the child to exit, bounded; then final-drain and reap.
  deadline=$(( EPOCHREALTIME + PTY_TIMEOUT ))
  while zpty -t _cc 2>/dev/null; do
    while zpty -r -t _cc chunk 2>/dev/null; do PTY_BUF+="$chunk"; done
    (( EPOCHREALTIME > deadline )) && break
    _pty_nap
  done
  while zpty -r _cc chunk 2>/dev/null; do PTY_BUF+="$chunk"; done
  zpty -d _cc 2>/dev/null

  [[ "$PTY_BUF" == *"launch anyway?"* ]] && PTY_PROMPTED=yes
  [[ -f "$SB/rec/argv" ]] && PTY_RAN=yes
  [[ -f "$SB/rc" ]] && PTY_RC="$(<"$SB/rc")"
  [[ -f "$SB/err" ]] && PTY_ERR="$(<"$SB/err")"
  rm -rf "$SB"
}

# The Ctrl-C case is about an *interactive* shell surviving SIGINT at the
# prompt (returning to its prompt, not dying), so it runs the guard inside a
# real interactive `zsh -f -i` under the pty rather than a script.
pty_ctrlc_case() {
  local SB; SB="$(mktemp -d)"
  mkdir -p "$SB/home" "$SB/agents" "$SB/bin" "$SB/rec"
  _pty_write_builder "$SB/agents" mismatch
  _pty_write_stub "$SB/bin"

  export HOME="$SB/home" PATH="$SB/bin:/usr/bin:/bin"
  export STUB_REC="$SB/rec" STUB_RC=7
  export CLAUDE_CAST_AGENTS_DIR="$SB/agents" CLAUDE_CAST_LAUNCH_CHECK=ask
  export PS1="RDY%% " PROMPT="RDY%% "

  PTY_BUF="" PTY_RAN=no PTY_SURVIVED=no
  local chunk deadline
  zpty -b _cc "zsh -f -i"

  _pty_expect() {   # wait until PTY_BUF contains $1, bounded; 0 hit / 1 timeout / 2 exited
    local pat=$1 dl=$(( EPOCHREALTIME + PTY_TIMEOUT ))
    while true; do
      while zpty -r -t _cc chunk 2>/dev/null; do PTY_BUF+="$chunk"; done
      [[ "$PTY_BUF" == *$pat* ]] && return 0
      zpty -t _cc 2>/dev/null || { while zpty -r _cc chunk 2>/dev/null; do PTY_BUF+="$chunk"; done; [[ "$PTY_BUF" == *$pat* ]] && return 0; return 2; }
      (( EPOCHREALTIME > dl )) && return 1
      _pty_nap
    done
  }

  zpty -w _cc "source \"$PLUGIN\""
  _pty_expect "RDY"
  PTY_BUF=""
  zpty -w _cc "clbuild 'arg one'"
  _pty_expect "launch anyway?"
  zpty -w -n _cc $'\003'                       # Ctrl-C at the prompt
  # If the shell survived, this next command runs and its marker appears.
  zpty -w _cc "print CC-SURVIVED-marker"
  _pty_expect "CC-SURVIVED-marker" && PTY_SURVIVED=yes
  [[ -f "$SB/rec/argv" ]] && PTY_RAN=yes
  zpty -w _cc "exit" 2>/dev/null
  zpty -d _cc 2>/dev/null
  unfunction _pty_expect
  rm -rf "$SB"
}

print -- "# interactive launch-guard (pty) — CLAUDE_CAST_LAUNCH_CHECK=ask"

# --- y / Y / yes at the prompt -> launches, and the launcher returns the
#     stub's own exit status (STUB_RC=7, a value the guard itself never emits).
pty_case ask mismatch direct y
assert_eq "ask: 'y' at the prompt is preceded by the prompt" "yes" "$PTY_PROMPTED"
assert_eq "ask: 'y' launches claude"                          "yes" "$PTY_RAN"
assert_eq "ask: 'y' returns the stub's exit status (7)"       "RC=7" "$PTY_RC"

pty_case ask mismatch direct Y
assert_eq "ask: 'Y' launches claude"                    "yes" "$PTY_RAN"
assert_eq "ask: 'Y' returns the stub's exit status (7)" "RC=7" "$PTY_RC"

pty_case ask mismatch direct yes
assert_eq "ask: 'yes' launches claude"                    "yes" "$PTY_RAN"
assert_eq "ask: 'yes' returns the stub's exit status (7)" "RC=7" "$PTY_RC"

# --- n / empty line / x -> returns 1, never launches.
pty_case ask mismatch direct n
assert_eq "ask: 'n' never launches" "no"   "$PTY_RAN"
assert_eq "ask: 'n' returns 1"      "RC=1" "$PTY_RC"

pty_case ask mismatch direct enter
assert_eq "ask: a bare Enter (empty line) never launches" "no"   "$PTY_RAN"
assert_eq "ask: a bare Enter returns 1"                   "RC=1" "$PTY_RC"

pty_case ask mismatch direct x
assert_eq "ask: an unrelated key ('x') never launches" "no"   "$PTY_RAN"
assert_eq "ask: an unrelated key returns 1"            "RC=1" "$PTY_RC"

# --- EOF (Ctrl-D) at the prompt -> never launches (read fails, reply empty).
pty_case ask mismatch direct eof
assert_eq "ask: EOF (Ctrl-D) at the prompt was reached" "yes"  "$PTY_PROMPTED"
assert_eq "ask: EOF (Ctrl-D) at the prompt never launches" "no"   "$PTY_RAN"
assert_eq "ask: EOF (Ctrl-D) at the prompt returns 1"      "RC=1" "$PTY_RC"

# --- Ctrl-C at the prompt -> never launches AND the interactive shell survives.
pty_ctrlc_case
assert_eq "ask: Ctrl-C at the prompt never launches"          "no"  "$PTY_RAN"
assert_eq "ask: Ctrl-C leaves the calling shell alive (runs the next command)" "yes" "$PTY_SURVIVED"

# --- stdin a terminal but stderr redirected to a file -> refuses with 3,
#     without ever printing the prompt (the [-t 0 && -t 2] gate).
pty_case ask mismatch redir none
assert_eq       "ask: stderr-not-a-tty refuses with 3"                 "RC=3" "$PTY_RC"
assert_eq       "ask: stderr-not-a-tty never launches"                 "no"   "$PTY_RAN"
assert_not_contains "ask: stderr-not-a-tty never prints the prompt"    "launch anyway?" "$PTY_BUF"
assert_contains "ask: stderr-not-a-tty still explains the refusal"     "refusing to launch" "$PTY_ERR"

# --- no mismatch under a pty -> no prompt, launches, no extra output at all.
pty_case ask match direct none
assert_eq "ask: an in-sync agent under a tty never prompts"  "no"   "$PTY_PROMPTED"
assert_eq "ask: an in-sync agent under a tty launches"       "yes"  "$PTY_RAN"
assert_eq "ask: an in-sync agent under a tty emits nothing"  ""     "$PTY_BUF"

# --- warn mode under a pty -> warns and launches, but never prompts.
pty_case warn mismatch direct none
assert_contains     "warn: prints the drift warning under a tty" "agent definition drift" "$PTY_BUF"
assert_eq           "warn: launches despite the drift"           "yes" "$PTY_RAN"
assert_not_contains "warn: never prompts (warn is not ask)"      "launch anyway?" "$PTY_BUF"

summary
