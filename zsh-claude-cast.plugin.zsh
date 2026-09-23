# zsh-claude-cast — launchers projected from a role -> model|effort casting table.
#
# Works via oh-my-zsh, plain `source`, zinit, and antidote. See README.md for
# install instructions and CLAUDE.md for the internals. The generated
# launchers shell out to nothing but `claude`; the plugin itself uses a few
# external commands — `cat` for the shipped preset/agent heredocs and, in
# `claude-cast doctor`, `git`/`ps`/`sleep` for the bounded chezmoi-lag fetch.

typeset -g CLAUDE_CAST_VERSION="0.6.0"

# ---------------------------------------------------------------------------
# Config knobs (set these — or CLAUDE_CAST[role]=… entries — BEFORE sourcing
# this file to override the defaults; see README.md "Overriding").
# ---------------------------------------------------------------------------

: ${CLAUDE_CAST_PREFIX:=cl}
: ${CLAUDE_CAST_FORCE:=0}
: ${CLAUDE_CAST_PRESET:=max20}
: ${CLAUDE_CAST_AGENTS_DIR:=$HOME/.claude/agents}
# Launch-time agent-definition check: warn (default) | ask | off — see the
# agent check below and README.md "Agent definitions and the launch check".
: ${CLAUDE_CAST_LAUNCH_CHECK:=warn}

# Resolves CLAUDE_CAST_PRESET to one of the shipped preset tables (max20,
# max5, pro), falling back to max20 — with a stderr note — on anything else.
typeset -g _CLAUDE_CAST_ACTIVE_PRESET
case "$CLAUDE_CAST_PRESET" in
  max20|max5|pro)
    _CLAUDE_CAST_ACTIVE_PRESET="$CLAUDE_CAST_PRESET"
    ;;
  *)
    print -u2 -- "zsh-claude-cast: unknown preset '$CLAUDE_CAST_PRESET' — falling back to max20"
    _CLAUDE_CAST_ACTIVE_PRESET=max20
    ;;
esac

if ! (( ${+CLAUDE_CAST_HEADLESS_FLAGS} )); then
  typeset -ga CLAUDE_CAST_HEADLESS_FLAGS
  CLAUDE_CAST_HEADLESS_FLAGS=(-p --output-format json --setting-sources "")
fi

if ! (( ${+CLAUDE_CAST} )); then
  typeset -gA CLAUDE_CAST
fi

# Agent-definition -> role map, same override mechanism as CLAUDE_CAST: a value
# set before sourcing wins; anything unset is filled from the shipped default
# (_claude_cast_default_agents, generated from casting.json) at load time. A
# map the user set before sourcing but left empty disables the agent check
# entirely (see _claude_cast_merge_agent_defaults); a plain array or scalar is
# re-typeset to an association so the subscript fills below can't abort load.
typeset -g _CLAUDE_CAST_AGENTS_USER_SET=0
if (( ${+CLAUDE_CAST_AGENTS} )); then
  _CLAUDE_CAST_AGENTS_USER_SET=1
  if [[ "${(t)CLAUDE_CAST_AGENTS}" != association* ]]; then
    unset CLAUDE_CAST_AGENTS
    typeset -gA CLAUDE_CAST_AGENTS
  fi
else
  typeset -gA CLAUDE_CAST_AGENTS
fi

# Internal bookkeeping — not part of the public API.
typeset -gA _CLAUDE_CAST_GENERATED       # launcher name -> 1 (ours to redefine/remove)
typeset -gA _CLAUDE_CAST_LAUNCHER_CMD    # launcher name -> display command line
typeset -ga _CLAUDE_CAST_SKIPPED         # scratch: names skipped on the last generation pass
typeset -ga _CLAUDE_CAST_OVERRIDDEN_ROLES # roles the table overrode from the active preset
typeset -g _CLAUDE_CAST_COMPLETION_DONE=0
# Pre-declared so `setopt warn_create_global` stays quiet when a launcher's
# guard (or `doctor`) first populates them from inside a function.
typeset -g __cc_fm_value                  # scratch: last frontmatter field read
typeset -gi _CLAUDE_CAST_AGENT_FILES_SEEN # scratch: mapped agent files that exist
typeset -ga _CLAUDE_CAST_AGENT_RESULTS    # scratch: per-agent check records
typeset -gA _CLAUDE_CAST_AGENTS_FROM_DEFAULT # agent -> 1 when filled from the shipped default map (not user-set)

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

# The shipped preset tables, one function each, as tab-separated
# "role\tspec" lines. Keep in sync with README.md "Plan presets" and
# CLAUDE.md. Empty effort field (e.g. "claude-haiku-4-5|") means: pass no
# --effort flag at all — required for Haiku, which errors on --effort.

# casting:begin (generated from claude-ops casting.json @ 7d3bd05 2026-09-23 — do not edit by hand)
# Claude Max 20x — today's default table.
_claude_cast_default_table_max20() {
  cat <<'EOF'
driver	claude-opus-5-5[1m]|high
fable	claude-opus-5-5[1m]|high|--append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md
build	claude-opus-5-5[1m]|xhigh
fix	claude-opus-5-5[1m]|high
gate	claude-opus-5-5[1m]|xhigh
chore	claude-sonnet-5[1m]|low
fanout	claude-haiku-4-5|
verify	claude-fable-5-1[1m]|xhigh
taste	claude-opus-5-5[1m]|high
orchestrate	claude-opus-5-5[1m]|high|--append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md
review	claude-opus-5-5[1m]|medium
sonnet	claude-sonnet-5[1m]|high
EOF
}

# Claude Max 5x — Fable rationed, Opus fronts driver/orchestrate.
_claude_cast_default_table_max5() {
  cat <<'EOF'
driver	claude-opus-5-5[1m]|high
fable	claude-opus-5-5[1m]|high|--append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md
build	claude-opus-5-5[1m]|high
fix	claude-opus-5-5[1m]|high
gate	claude-opus-5-5[1m]|xhigh
chore	claude-haiku-4-5|
fanout	claude-haiku-4-5|
verify	claude-fable-5-1[1m]|high
taste	claude-opus-5-5[1m]|high
orchestrate	claude-opus-5-5[1m]|high|--append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md
review	claude-opus-5-5[1m]|medium
sonnet	claude-sonnet-5[1m]|high
EOF
}

# Claude Pro — Sonnet-led, no Opus 5 assumed (no review row).
_claude_cast_default_table_pro() {
  cat <<'EOF'
driver	claude-sonnet-5[1m]|high
fable	claude-opus-5-5[1m]|high|--append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md
build	claude-sonnet-5[1m]|medium
fix	claude-opus-5-5[1m]|high
gate	claude-opus-5-5[1m]|high
chore	claude-haiku-4-5|
fanout	claude-haiku-4-5|
verify	claude-opus-5-5[1m]|high
taste	claude-opus-5-5[1m]|high
orchestrate	claude-opus-5-5[1m]|high|--append-system-prompt-file ~/.claude/skills/fable-mode/SKILL.md
sonnet	claude-sonnet-5[1m]|high
EOF
}

# The default agent-definition -> role map (agents key in casting.json).
_claude_cast_default_agents() {
  cat <<'EOF'
builder	build
fixer	fix
gate	gate
chore	chore
fanout	fanout
verifier	verify
analyst	review
EOF
}
# casting:end

# Prints the active preset's table (see _CLAUDE_CAST_ACTIVE_PRESET).
_claude_cast_default_table() {
  case "$_CLAUDE_CAST_ACTIVE_PRESET" in
    max5) _claude_cast_default_table_max5 ;;
    pro) _claude_cast_default_table_pro ;;
    *) _claude_cast_default_table_max20 ;;
  esac
}

# Fills in any default role not already present in CLAUDE_CAST. A row a user
# set before sourcing (or via CLAUDE_CAST_FILE) always wins, and is recorded
# in _CLAUDE_CAST_OVERRIDDEN_ROLES for `claude-cast list`'s header line.
_claude_cast_merge_defaults() {
  local role spec
  _CLAUDE_CAST_OVERRIDDEN_ROLES=()
  while IFS=$'\t' read -r role spec; do
    [[ -z "$role" ]] && continue
    if [[ -z "${CLAUDE_CAST[$role]+x}" ]]; then
      CLAUDE_CAST[$role]="$spec"
    else
      _CLAUDE_CAST_OVERRIDDEN_ROLES+=("$role")
    fi
  done < <(_claude_cast_default_table)
}

# Fills in any default agent -> role mapping not already present in
# CLAUDE_CAST_AGENTS. Same rule as _claude_cast_merge_defaults: a mapping the
# user set before sourcing wins; the rest come from _claude_cast_default_agents.
_claude_cast_merge_agent_defaults() {
  # A map the user set before sourcing and left empty is an explicit "disable
  # the agent check" — leave it empty instead of refilling the defaults.
  if (( _CLAUDE_CAST_AGENTS_USER_SET )) && (( ${#CLAUDE_CAST_AGENTS} == 0 )); then
    return 0
  fi
  local agent role
  while IFS=$'\t' read -r agent role; do
    [[ -z "$agent" ]] && continue
    if [[ -z "${CLAUDE_CAST_AGENTS[$agent]+x}" ]]; then
      CLAUDE_CAST_AGENTS[$agent]="$role"
      # Remember this came from the shipped map, not the user: a default whose
      # role is absent from the active preset (e.g. analyst -> review under
      # `pro`) is skipped silently by the check, while a user-set mapping to a
      # nonexistent role stays unknown-role (see _claude_cast_agent_check).
      _CLAUDE_CAST_AGENTS_FROM_DEFAULT[$agent]=1
    fi
  done < <(_claude_cast_default_agents)
}

# Parses "model|effort|extra flags" into globals __cc_model, __cc_effort,
# __cc_extra (array). Deliberately not `local` — callers read the globals
# immediately after calling.
_claude_cast_parse_spec() {
  local spec="$1"
  local -a parts
  parts=("${(@s:|:)spec}")
  __cc_model="${parts[1]:-}"
  __cc_effort="${parts[2]:-}"
  local extra="${parts[3]:-}"
  __cc_extra=(${(z)extra})
}

# Resolves a spec's launch argv into the global array __cc_argv (no `command
# claude` prefix): --model <model>, then --effort <effort> when the effort is
# non-empty, then each extra token with a leading "~" expanded to $HOME. Both
# the launcher bodies and `claude-cast argv` call this, so the two cannot
# disagree. Deliberately not `local` — callers read __cc_argv immediately.
_claude_cast_resolve_argv() {
  local model=$1 effort=$2
  shift 2
  local -a extra=("$@")
  local i
  for (( i = 1; i <= ${#extra}; i++ )); do
    extra[i]="${extra[i]/#\~/$HOME}"
  done
  __cc_argv=(--model "$model")
  [[ -n "$effort" ]] && __cc_argv+=(--effort "$effort")
  (( ${#extra} )) && __cc_argv+=("${extra[@]}")
}

# True if $1 already resolves to a command, alias, function, or builtin.
_claude_cast_name_taken() {
  command -v -- "$1" >/dev/null 2>&1
}

# True if generating $1 should be skipped (already taken by something that
# isn't ours, and CLAUDE_CAST_FORCE isn't set).
_claude_cast_should_skip() {
  local name=$1
  (( ${+_CLAUDE_CAST_GENERATED[$name]} )) && return 1
  [[ "${CLAUDE_CAST_FORCE:-0}" == 1 ]] && return 1
  _claude_cast_name_taken "$name" && return 0
  return 1
}

# Quotes one token for human-readable display (used by `which`/`list`), not
# for eval — real launcher bodies are built separately with proper (q@) quoting.
_claude_cast_quote_display() {
  local tok=$1
  if [[ -z "$tok" ]]; then
    print -r -- "''"
  elif [[ "$tok" == *[[:space:]]* ]]; then
    print -r -- "'$tok'"
  else
    print -r -- "$tok"
  fi
}

_claude_cast_display_cmdline() {
  local out="" tok first=1
  for tok in "$@"; do
    if (( first )); then
      out="$(_claude_cast_quote_display "$tok")"
      first=0
    else
      out+=" $(_claude_cast_quote_display "$tok")"
    fi
  done
  print -r -- "$out"
}

# Defines (or skips) one launcher function.
#   _claude_cast_define_launcher <name> <headless:0|1> <model> <effort> [extra...]
_claude_cast_define_launcher() {
  local name=$1 headless=$2 model=$3 effort=$4
  shift 4

  if _claude_cast_should_skip "$name"; then
    _CLAUDE_CAST_SKIPPED+=("$name")
    return 0
  fi

  # Same resolution path as `claude-cast argv` (--model/--effort/extra, with any
  # leading "~" in an extra flag expanded to $HOME at launch time).
  _claude_cast_resolve_argv "$model" "$effort" "$@"
  local -a fixed=(command claude "${__cc_argv[@]}")
  local -a display=("${fixed[@]}")
  if [[ "$headless" == 1 ]]; then
    fixed+=("${CLAUDE_CAST_HEADLESS_FLAGS[@]}")
    display+=("${CLAUDE_CAST_HEADLESS_FLAGS[@]}")
  fi

  # The launch-time agent check runs before `command claude` (see
  # _claude_cast_launch_guard); on a mismatch it can abort with a non-zero code.
  local body="$(print -r -- ${(q@)fixed})"
  eval "function $name { _claude_cast_launch_guard || return; $body \"\$@\"; }"
  _CLAUDE_CAST_GENERATED[$name]=1
  _CLAUDE_CAST_LAUNCHER_CMD[$name]="$(_claude_cast_display_cmdline "${display[@]}")"

  if (( ${+functions[compdef]} )) && (( ${+functions[_claude]} )); then
    compdef _claude "$name" 2>/dev/null
  fi
}

# The two fixed helpers: bare passthrough and --continue.
_claude_cast_generate_fixed() {
  local plain="${CLAUDE_CAST_PREFIX}"
  local cont="${CLAUDE_CAST_PREFIX}r"

  if _claude_cast_should_skip "$plain"; then
    _CLAUDE_CAST_SKIPPED+=("$plain")
  else
    eval "function $plain { _claude_cast_launch_guard || return; command claude \"\$@\"; }"
    _CLAUDE_CAST_GENERATED[$plain]=1
    _CLAUDE_CAST_LAUNCHER_CMD[$plain]="command claude"
    if (( ${+functions[compdef]} )) && (( ${+functions[_claude]} )); then
      compdef _claude "$plain" 2>/dev/null
    fi
  fi

  if _claude_cast_should_skip "$cont"; then
    _CLAUDE_CAST_SKIPPED+=("$cont")
  else
    eval "function $cont { _claude_cast_launch_guard || return; command claude --continue \"\$@\"; }"
    _CLAUDE_CAST_GENERATED[$cont]=1
    _CLAUDE_CAST_LAUNCHER_CMD[$cont]="command claude --continue"
    if (( ${+functions[compdef]} )) && (( ${+functions[_claude]} )); then
      compdef _claude "$cont" 2>/dev/null
    fi
  fi
}

# (Re)generates every launcher from the current CLAUDE_CAST table.
_claude_cast_generate_all() {
  _CLAUDE_CAST_SKIPPED=()
  local role spec
  for role spec in "${(@kv)CLAUDE_CAST}"; do
    _claude_cast_parse_spec "$spec"
    _claude_cast_define_launcher "${CLAUDE_CAST_PREFIX}${role}" 0 "$__cc_model" "$__cc_effort" "${__cc_extra[@]}"
    _claude_cast_define_launcher "${CLAUDE_CAST_PREFIX}p${role}" 1 "$__cc_model" "$__cc_effort" "${__cc_extra[@]}"
  done
  _claude_cast_generate_fixed

  if (( ${#_CLAUDE_CAST_SKIPPED} )); then
    print -u2 -- "zsh-claude-cast: skipped ${#_CLAUDE_CAST_SKIPPED} launcher(s) already defined elsewhere: ${(j:, :)_CLAUDE_CAST_SKIPPED} (set CLAUDE_CAST_FORCE=1 to override)"
  fi
}

# Regenerates after CLAUDE_CAST was edited directly (or via set/unset):
# drops launchers whose role no longer exists, then regenerates the rest.
_claude_cast_reload() {
  local -a want=()
  local role
  for role in "${(@k)CLAUDE_CAST}"; do
    want+=("${CLAUDE_CAST_PREFIX}${role}" "${CLAUDE_CAST_PREFIX}p${role}")
  done

  local gname fixed_plain="${CLAUDE_CAST_PREFIX}" fixed_cont="${CLAUDE_CAST_PREFIX}r"
  for gname in "${(@k)_CLAUDE_CAST_GENERATED}"; do
    [[ "$gname" == "$fixed_plain" || "$gname" == "$fixed_cont" ]] && continue
    if (( ! ${want[(Ie)$gname]} )); then
      unfunction "$gname" 2>/dev/null
      unset "_CLAUDE_CAST_GENERATED[$gname]"
      unset "_CLAUDE_CAST_LAUNCHER_CMD[$gname]"
    fi
  done

  _claude_cast_generate_all
}

# Wires `compdef _claude <launcher>` for every generated launcher, if the
# `_claude` completion function and `compdef` both exist yet. Safe to call
# before compinit has run — it just no-ops.
_claude_cast_try_completion() {
  (( _CLAUDE_CAST_COMPLETION_DONE )) && return 0
  (( ${+functions[compdef]} )) || return 0
  (( ${+functions[_claude]} )) || return 0
  local name
  for name in "${(k)_CLAUDE_CAST_GENERATED}"; do
    compdef _claude "$name" 2>/dev/null
  done
  _CLAUDE_CAST_COMPLETION_DONE=1
}

_claude_cast_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  print -r -- "$s"
}

# ---------------------------------------------------------------------------
# Agent-definition check (a casting table is only as good as the agent
# definitions on the machine that launches). Pure zsh file reads — no
# subprocess — so it adds negligible launch latency.
# ---------------------------------------------------------------------------

# Reads one frontmatter field ("model"/"effort") from an agent .md file, pure
# zsh. Only scans between the first two "---" fences (tolerating a leading
# UTF-8 BOM, CRLF line endings, and trailing whitespace on a fence). Sets
# __cc_fm_value to the value ("" when the key is absent), with one layer of
# matching surrounding quotes and a trailing " #..." comment stripped.
# model/effort values carry no internal whitespace, so surrounding whitespace
# is stripped too.
_claude_cast_read_frontmatter_field() {
  local file=$1 key=$2
  __cc_fm_value=""
  local raw line v in_fm=0
  # `|| [[ -n "$raw" ]]` so a final line with no trailing newline is still seen.
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%$'\r'}"                 # tolerate CRLF
    line="${line#$'\xef\xbb\xbf'}"      # tolerate a leading UTF-8 BOM
    if [[ "$line" == "---" || "$line" == ---[[:space:]]* ]]; then
      (( in_fm )) && break
      in_fm=1
      continue
    fi
    (( in_fm )) || continue
    if [[ "$line" == "${key}:"* ]]; then
      v="${line#${key}:}"
      v="${v%%[[:space:]]\#*}"          # drop a trailing " #..." comment
      v="${v//[[:space:]]/}"            # model/effort carry no inner whitespace
      if [[ "$v" == '"'*'"' || "$v" == \'*\' ]]; then
        v="${v[2,-2]}"                  # strip one layer of matching quotes
      fi
      __cc_fm_value="$v"
      return 0
    fi
  done < "$file"
  return 0
}

# Checks each (agent, role) in CLAUDE_CAST_AGENTS against its
# $CLAUDE_CAST_AGENTS_DIR/<agent>.md. Populates _CLAUDE_CAST_AGENT_RESULTS with
# one "status<TAB>agent<TAB>detail" record per agent (status: ok | mismatch |
# missing | unknown-role), and _CLAUDE_CAST_AGENT_FILES_SEEN with the number of
# mapped agent files that exist (so a caller can tell "convention not used"
# from real drift). Expected model = the role's table model with a trailing
# [...] suffix stripped; expected effort = the role's effort (empty when the
# key is absent).
_claude_cast_agent_check() {
  _CLAUDE_CAST_AGENT_RESULTS=()
  _CLAUDE_CAST_AGENT_FILES_SEEN=0
  local -a agents=("${(@ok)CLAUDE_CAST_AGENTS}")
  local agent role file want_model want_effort have_model have_effort
  for agent in "${agents[@]}"; do
    role="${CLAUDE_CAST_AGENTS[$agent]}"
    # An agent mapped to the empty string is a per-agent opt-out: skip silently.
    [[ -z "$role" ]] && continue
    if [[ -z "${CLAUDE_CAST[$role]+x}" ]]; then
      # A shipped-default mapping whose role isn't in the active preset (e.g.
      # analyst -> review under `pro`, which has no review row) is skipped
      # silently — it isn't drift. Only a user-set mapping to a nonexistent
      # role is flagged unknown-role.
      (( ${+_CLAUDE_CAST_AGENTS_FROM_DEFAULT[$agent]} )) && continue
      _CLAUDE_CAST_AGENT_RESULTS+=("unknown-role"$'\t'"$agent"$'\t'"mapped role '$role' is not in the casting table")
      continue
    fi
    file="${CLAUDE_CAST_AGENTS_DIR}/${agent}.md"
    if [[ ! -f "$file" ]]; then
      _CLAUDE_CAST_AGENT_RESULTS+=("missing"$'\t'"$agent"$'\t'"$file")
      continue
    fi
    if [[ ! -r "$file" ]]; then
      _CLAUDE_CAST_AGENT_RESULTS+=("unreadable"$'\t'"$agent"$'\t'"$file")
      continue
    fi
    (( _CLAUDE_CAST_AGENT_FILES_SEEN++ ))
    _claude_cast_parse_spec "${CLAUDE_CAST[$role]}"
    want_model="${__cc_model%\[*\]}"
    want_effort="$__cc_effort"
    _claude_cast_read_frontmatter_field "$file" model; have_model="$__cc_fm_value"
    _claude_cast_read_frontmatter_field "$file" effort; have_effort="$__cc_fm_value"
    local -a diffs=()
    [[ "$have_model" != "$want_model" ]] && diffs+=("model have=${have_model:-<none>} want=${want_model}")
    [[ "$have_effort" != "$want_effort" ]] && diffs+=("effort have=${have_effort:-<none>} want=${want_effort:-<none>}")
    if (( ${#diffs} )); then
      _CLAUDE_CAST_AGENT_RESULTS+=("mismatch"$'\t'"$agent"$'\t'"${(j:; :)diffs}")
    else
      _CLAUDE_CAST_AGENT_RESULTS+=("ok"$'\t'"$agent"$'\t')
    fi
  done
}

# Launch-time gate, run by every generated launcher before `command claude`.
# Existing files only, mismatch only. Mode from CLAUDE_CAST_LAUNCH_CHECK
# (case-insensitive; an unknown value warns and behaves as warn):
# off -> skip entirely; warn (default) -> print and continue; ask -> prompt
# when stdin and stderr are both TTYs (default No -> return 1), else refuse
# without prompting (return 3). No mismatch: zero output, return 0.
_claude_cast_launch_guard() {
  # Case-insensitive; an unrecognised value warns (safe: print + continue)
  # rather than silently taking the ask path, and says what's valid.
  local mode="${${CLAUDE_CAST_LAUNCH_CHECK:-warn}:l}"
  case "$mode" in
    off|warn|ask) ;;
    *)
      print -u2 -- "zsh-claude-cast: unknown CLAUDE_CAST_LAUNCH_CHECK '$CLAUDE_CAST_LAUNCH_CHECK' — expected off, warn, or ask; using warn"
      mode=warn
      ;;
  esac
  [[ "$mode" == off ]] && return 0

  _claude_cast_agent_check
  local -a mismatches=()
  local rec rest agent detail
  for rec in "${_CLAUDE_CAST_AGENT_RESULTS[@]}"; do
    [[ "${rec%%$'\t'*}" == mismatch ]] || continue
    rest="${rec#*$'\t'}"
    agent="${rest%%$'\t'*}"
    detail="${rest#*$'\t'}"
    mismatches+=("${agent}.md ${detail}")
  done
  (( ${#mismatches} == 0 )) && return 0

  print -u2 -- "zsh-claude-cast: agent definition drift before launch:"
  local m
  for m in "${mismatches[@]}"; do
    print -u2 -- "  ${m}"
  done
  print -u2 -- "  hint: run \`claude-cast doctor\`, then update your dotfiles (chezmoi) to match the casting table."

  [[ "$mode" == warn ]] && return 0

  # ask
  if [[ -t 0 && -t 2 ]]; then
    print -u2 -n -- "launch anyway? [y/N] "
    local reply
    read -r reply
    [[ "$reply" == [yY]* ]] && return 0
    return 1
  fi
  print -u2 -- "zsh-claude-cast: refusing to launch (agent drift, no TTY to confirm; set CLAUDE_CAST_LAUNCH_CHECK=warn or off to override)"
  return 3
}

# ---------------------------------------------------------------------------
# `claude-cast` subcommands
# ---------------------------------------------------------------------------

_claude_cast_cmd_list() {
  local -a roles=("${(@ok)CLAUDE_CAST}")
  local role launcher w1=4 w2=8 w3=5 w4=6 w5=5
  local -A extras efforts

  local header="preset: ${_CLAUDE_CAST_ACTIVE_PRESET}"
  if (( ${#_CLAUDE_CAST_OVERRIDDEN_ROLES} )); then
    header+=" (overridden: ${(j:, :)_CLAUDE_CAST_OVERRIDDEN_ROLES})"
  fi
  print -r -- "$header"

  for role in "${roles[@]}"; do
    _claude_cast_parse_spec "${CLAUDE_CAST[$role]}"
    launcher="${CLAUDE_CAST_PREFIX}${role}"
    extras[$role]="${(j: :)__cc_extra}"
    local ed="$__cc_effort"
    [[ -z "$ed" ]] && ed="-"
    efforts[$role]="$ed"
    (( ${#role} > w1 )) && w1=${#role}
    (( ${#launcher} > w2 )) && w2=${#launcher}
    (( ${#__cc_model} > w3 )) && w3=${#__cc_model}
    (( ${#ed} > w4 )) && w4=${#ed}
    (( ${#extras[$role]} > w5 )) && w5=${#extras[$role]}
  done

  printf "%-${w1}s  %-${w2}s  %-${w3}s  %-${w4}s  %-${w5}s\n" ROLE LAUNCHER MODEL EFFORT EXTRA
  for role in "${roles[@]}"; do
    _claude_cast_parse_spec "${CLAUDE_CAST[$role]}"
    launcher="${CLAUDE_CAST_PREFIX}${role}"
    local extra_disp="${extras[$role]}"
    [[ -z "$extra_disp" ]] && extra_disp="-"
    printf "%-${w1}s  %-${w2}s  %-${w3}s  %-${w4}s  %-${w5}s\n" \
      "$role" "$launcher" "$__cc_model" "${efforts[$role]}" "$extra_disp"
  done
}

_claude_cast_cmd_which() {
  if (( $# < 1 )); then
    print -u2 -- "usage: claude-cast which <launcher-or-role>"
    return 1
  fi
  local input=$1 name=$1
  if [[ -z "${_CLAUDE_CAST_LAUNCHER_CMD[$name]+x}" && -n "${CLAUDE_CAST[$input]+x}" ]]; then
    name="${CLAUDE_CAST_PREFIX}${input}"
  fi
  if [[ -n "${_CLAUDE_CAST_LAUNCHER_CMD[$name]+x}" ]]; then
    print -r -- "${_CLAUDE_CAST_LAUNCHER_CMD[$name]}"
  else
    print -u2 -- "claude-cast: unknown launcher or role: $input"
    return 1
  fi
}

_claude_cast_cmd_set() {
  if (( $# < 3 )); then
    print -u2 -- "usage: claude-cast set <role> <model> <effort|-> [flags...]"
    return 1
  fi
  local role=$1 model=$2 effort=$3
  shift 3
  [[ "$effort" == "-" ]] && effort=""
  local extra="$*"
  CLAUDE_CAST[$role]="${model}|${effort}|${extra}"
  _claude_cast_reload
}

_claude_cast_cmd_unset() {
  if (( $# < 1 )); then
    print -u2 -- "usage: claude-cast unset <role>"
    return 1
  fi
  local role=$1
  if [[ -z "${CLAUDE_CAST[$role]+x}" ]]; then
    print -u2 -- "claude-cast: unknown role: $role"
    return 1
  fi
  unset "CLAUDE_CAST[$role]"
  _claude_cast_reload
}

_claude_cast_cmd_export() {
  local -a roles=("${(@ok)CLAUDE_CAST}")
  local role
  print -r -- "{"
  printf '  "preset": "%s",\n' "$(_claude_cast_json_escape "$_CLAUDE_CAST_ACTIVE_PRESET")"
  # Every role line carries a trailing comma — "agents" is the final key.
  for role in "${roles[@]}"; do
    _claude_cast_parse_spec "${CLAUDE_CAST[$role]}"
    local extra_str="${(j: :)__cc_extra}"
    printf '  "%s": {"model": "%s", "effort": "%s", "extra": "%s"},\n' \
      "$(_claude_cast_json_escape "$role")" \
      "$(_claude_cast_json_escape "$__cc_model")" \
      "$(_claude_cast_json_escape "$__cc_effort")" \
      "$(_claude_cast_json_escape "$extra_str")"
  done
  local -a agents=("${(@ok)CLAUDE_CAST_AGENTS}")
  local a n=${#agents} i=0 comma
  if (( n == 0 )); then
    print -r -- '  "agents": {}'
  else
    print -r -- '  "agents": {'
    for a in "${agents[@]}"; do
      (( i++ ))
      comma=","
      (( i == n )) && comma=""
      printf '    "%s": "%s"%s\n' \
        "$(_claude_cast_json_escape "$a")" \
        "$(_claude_cast_json_escape "${CLAUDE_CAST_AGENTS[$a]}")" \
        "$comma"
    done
    print -r -- '  }'
  fi
  print -r -- "}"
}

_claude_cast_cmd_argv() {
  if (( $# < 1 )); then
    print -u2 -- "usage: claude-cast argv <role>"
    return 1
  fi
  local role=$1
  if [[ -z "${CLAUDE_CAST[$role]+x}" ]]; then
    print -u2 -- "claude-cast: unknown role: $role"
    return 1
  fi
  _claude_cast_parse_spec "${CLAUDE_CAST[$role]}"
  _claude_cast_resolve_argv "$__cc_model" "$__cc_effort" "${__cc_extra[@]}"
  local tok
  for tok in "${__cc_argv[@]}"; do
    print -r -- "$tok"
  done
}

_claude_cast_cmd_lint() {
  local -a roles=("${(@ok)CLAUDE_CAST}")
  local -a alias_names=(fable opus sonnet haiku best default)
  local -a valid_efforts=(low medium high xhigh max)
  local role warned=0

  for role in "${roles[@]}"; do
    _claude_cast_parse_spec "${CLAUDE_CAST[$role]}"
    if (( ${alias_names[(Ie)$__cc_model]} )); then
      print -- "claude-cast lint: [$role] model '$__cc_model' is a bare alias — use the full model ID (aliases re-resolve across releases)"
      warned=1
    fi
    if [[ "${__cc_model:l}" == *haiku* && -n "$__cc_effort" ]]; then
      print -- "claude-cast lint: [$role] model '$__cc_model' is a Haiku model — the --effort flag errors on Haiku"
      warned=1
    fi
    if [[ -n "$__cc_effort" ]] && (( ! ${valid_efforts[(Ie)$__cc_effort]} )); then
      print -- "claude-cast lint: [$role] unknown effort '$__cc_effort' (expected one of: ${(j:, :)valid_efforts})"
      warned=1
    fi
  done

  if (( warned )); then
    return 1
  fi
  print -- "claude-cast lint: no issues found"
  return 0
}

# Prints all three shipped preset tables, one after another — independent
# of the currently active CLAUDE_CAST table.
_claude_cast_cmd_presets() {
  # Locals declared once, reset by plain assignment each pass — zsh prints
  # an already-local name's value if `local`/`typeset` re-declares it (no
  # `=`) a second time in the same scope, which a `local ...` inside this
  # loop would trigger on the 2nd/3rd preset.
  local preset first=1 role spec ed w1 w2 w3 i
  local -a rows_role rows_model rows_effort
  for preset in max20 max5 pro; do
    (( first )) || print --
    first=0
    print -r -- "== ${preset} =="

    w1=4 w2=5 w3=6
    rows_role=() rows_model=() rows_effort=()
    while IFS=$'\t' read -r role spec; do
      [[ -z "$role" ]] && continue
      _claude_cast_parse_spec "$spec"
      ed="$__cc_effort"
      [[ -z "$ed" ]] && ed="-"
      rows_role+=("$role")
      rows_model+=("$__cc_model")
      rows_effort+=("$ed")
      (( ${#role} > w1 )) && w1=${#role}
      (( ${#__cc_model} > w2 )) && w2=${#__cc_model}
      (( ${#ed} > w3 )) && w3=${#ed}
    done < <(_claude_cast_default_table_${preset})

    printf "%-${w1}s  %-${w2}s  %-${w3}s\n" ROLE MODEL EFFORT
    for (( i = 1; i <= ${#rows_role}; i++ )); do
      printf "%-${w1}s  %-${w2}s  %-${w3}s\n" "${rows_role[$i]}" "${rows_model[$i]}" "${rows_effort[$i]}"
    done
  done
}

# Kills $1 and every descendant (from one `ps` snapshot), TERM then KILL — so a
# bounded git fetch is reaped together with its git-remote-https child instead
# of orphaning it to keep dialling a dead network.
_claude_cast_kill_tree() {
  local root=$1
  local -a targets=("$root")
  local snap p ppid round grew
  snap="$(command ps -axo pid=,ppid= 2>/dev/null)"
  for round in 1 2 3 4; do
    grew=0
    while IFS=' ' read -r p ppid; do
      [[ -z "$p" ]] && continue
      if (( ${targets[(Ie)$ppid]} )) && (( ! ${targets[(Ie)$p]} )); then
        targets+=("$p")
        grew=1
      fi
    done <<< "$snap"
    (( grew )) || break
  done
  kill "${targets[@]}" 2>/dev/null
  sleep 0.2
  kill -9 "${targets[@]}" 2>/dev/null
}

# Runs `git fetch --quiet` in $1 with a ~10s ceiling, portable (no GNU
# `timeout`): background it, poll, then kill the whole process tree if it
# overran a dead network. local_options no_monitor/no_notify keep the
# background job's control chatter out of doctor's output; the git env/config
# bounds credential-prompt, SSH-handshake, and stalled-transfer hangs so the
# kill path is a last resort rather than the norm.
_claude_cast_bounded_git_fetch() {
  setopt local_options no_monitor no_notify
  local dir=$1
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o ConnectTimeout=8 -o BatchMode=yes' \
    command git -C "$dir" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=8 \
    fetch --quiet 2>/dev/null &
  local pid=$! i=0
  while (( i < 100 )) && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    (( i++ ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    _claude_cast_kill_tree "$pid"
  fi
  wait "$pid" 2>/dev/null
}

# `claude-cast doctor [--fetch] [--brief]`: runs the lint, the agent-definition
# check, and a chezmoi-lag check; exit 0 clean, 1 on any drift. --brief prints
# exactly one line. --fetch refreshes chezmoi's remote refs (bounded) first.
_claude_cast_cmd_doctor() {
  local fetch=0 brief=0 arg
  for arg in "$@"; do
    case "$arg" in
      --fetch) fetch=1 ;;
      --brief) brief=1 ;;
      *) print -u2 -- "usage: claude-cast doctor [--fetch] [--brief]"; return 1 ;;
    esac
  done

  local drift=0 warn=0
  local -a lines=() brief_drift=()

  # 1. lint (existing).
  local lint_out lint_rc
  lint_out="$(_claude_cast_cmd_lint)"
  lint_rc=$?
  if (( lint_rc != 0 )); then
    drift=1
    brief_drift+=("lint")
    lines+=("lint: issues found")
    lines+=("${(f)lint_out}")
  else
    lines+=("lint: ok")
  fi

  # 2. agent definitions.
  _claude_cast_agent_check
  local -a mapped=("${(@ok)CLAUDE_CAST_AGENTS}")
  local agents_brief
  if (( ${#mapped} == 0 )); then
    agents_brief="agents=0"
    lines+=("agents: no agent map configured — skipped")
  elif (( _CLAUDE_CAST_AGENT_FILES_SEEN == 0 )); then
    agents_brief="agents=skipped"
    lines+=("agents: no mapped agent definitions found — skipped (${CLAUDE_CAST_AGENTS_DIR})")
  else
    agents_brief="agents=${_CLAUDE_CAST_AGENT_FILES_SEEN}"
  fi
  local rec rest st agent detail
  for rec in "${_CLAUDE_CAST_AGENT_RESULTS[@]}"; do
    st="${rec%%$'\t'*}"
    rest="${rec#*$'\t'}"
    agent="${rest%%$'\t'*}"
    detail="${rest#*$'\t'}"
    case "$st" in
      ok) lines+=("agents: ${agent}.md ok") ;;
      mismatch)
        drift=1
        brief_drift+=("${agent}.md ${detail}")
        lines+=("agents: ${agent}.md MISMATCH — ${detail}")
        ;;
      missing)
        # Drift only when the convention is actually in use (some file exists).
        if (( _CLAUDE_CAST_AGENT_FILES_SEEN > 0 )); then
          drift=1
          brief_drift+=("${agent}.md missing")
          lines+=("agents: ${agent}.md MISSING — ${detail}")
        fi
        ;;
      unreadable)
        # Exists but can't be read — a warning (can't confirm drift), not drift.
        warn=1
        lines+=("agents: ${agent}.md UNREADABLE — ${detail}")
        ;;
      unknown-role)
        drift=1
        brief_drift+=("${agent}.md unknown-role")
        lines+=("agents: ${agent}.md UNKNOWN-ROLE — ${detail}")
        ;;
    esac
  done

  # 3. chezmoi lag.
  local chezmoi_brief="skipped"
  if (( ${+commands[chezmoi]} )); then
    local src
    src="$(chezmoi source-path 2>/dev/null)"
    if [[ -n "$src" && -d "$src" ]]; then
      (( fetch )) && _claude_cast_bounded_git_fetch "$src"
      local upstream behind
      upstream="$(command git -C "$src" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"
      if [[ -n "$upstream" ]]; then
        behind="$(command git -C "$src" rev-list --count "HEAD..${upstream}" 2>/dev/null)"
        [[ -z "$behind" ]] && behind=0
        chezmoi_brief="behind:${behind}"
        lines+=("chezmoi: source ${src} is ${behind} commit(s) behind ${upstream} (as of last fetch)")
        (( behind > 0 )) && drift=1
      else
        chezmoi_brief="no-upstream"
        warn=1
        lines+=("chezmoi: cannot measure lag (no upstream) — source ${src}")
      fi
    else
      lines+=("chezmoi: source-path unavailable — skipped")
    fi
  else
    lines+=("chezmoi: not on PATH — skipped")
  fi

  if (( brief )); then
    if (( drift )); then
      local -a brief_all=("${brief_drift[@]}" "chezmoi=${chezmoi_brief}")
      print -r -- "claude-cast doctor: DRIFT ${(j:; :)brief_all}"
    elif (( warn )); then
      print -r -- "claude-cast doctor: WARN ${agents_brief} chezmoi=${chezmoi_brief}"
    else
      print -r -- "claude-cast doctor: OK ${agents_brief} chezmoi=${chezmoi_brief}"
    fi
  else
    local l
    for l in "${lines[@]}"; do
      print -r -- "$l"
    done
    local verdict=OK
    (( warn )) && verdict=WARN
    (( drift )) && verdict=DRIFT
    print -r -- "claude-cast doctor: $verdict"
  fi

  (( drift )) && return 1
  return 0
}

_claude_cast_cmd_help() {
  cat <<EOF
zsh-claude-cast ${CLAUDE_CAST_VERSION} — launchers projected from a CLAUDE_CAST casting table

Usage: claude-cast [subcommand] [args...]

Subcommands:
  list                          Show the casting table (default), with the
                                 active preset and any overridden roles
  which <launcher-or-role>      Print the exact command line for a launcher
  set <role> <model> <effort|-> [flags...]
                                 Add or replace a role, then regenerate launchers
                                 ("-" or "" for effort means: no --effort flag)
  unset <role>                  Remove a role and its launchers
  argv <role>                   Print a role's launch args, one token per line
  export                        Print the casting table as JSON (stable key order)
  presets                       Print all three shipped preset tables
  lint                          Warn on alias model names, Haiku+effort, unknown efforts
  doctor [--fetch] [--brief]    Lint + agent-definition check + chezmoi lag; exit 1 on drift
  reload                        Regenerate launchers after editing CLAUDE_CAST directly
  help                          Show this message
  version                       Print the plugin version

Active preset: ${_CLAUDE_CAST_ACTIVE_PRESET} (CLAUDE_CAST_PRESET, set before sourcing).
Generated per role <r>: ${CLAUDE_CAST_PREFIX}<r> and ${CLAUDE_CAST_PREFIX}p<r> (headless).
Fixed helpers: ${CLAUDE_CAST_PREFIX} (bare claude), ${CLAUDE_CAST_PREFIX}r (claude --continue).
Launch-time agent check: CLAUDE_CAST_LAUNCH_CHECK=warn (default) | ask | off.
EOF
}

claude-cast() {
  _claude_cast_try_completion
  local cmd=${1:-list}
  (( $# > 0 )) && shift
  case "$cmd" in
    list) _claude_cast_cmd_list ;;
    which) _claude_cast_cmd_which "$@" ;;
    set) _claude_cast_cmd_set "$@" ;;
    unset) _claude_cast_cmd_unset "$@" ;;
    argv) _claude_cast_cmd_argv "$@" ;;
    export) _claude_cast_cmd_export ;;
    presets) _claude_cast_cmd_presets ;;
    lint) _claude_cast_cmd_lint ;;
    doctor) _claude_cast_cmd_doctor "$@" ;;
    reload) _claude_cast_reload ;;
    help|-h|--help) _claude_cast_cmd_help ;;
    version|-v|--version) print -r -- "$CLAUDE_CAST_VERSION" ;;
    *)
      print -u2 -- "claude-cast: unknown subcommand: $cmd"
      _claude_cast_cmd_help
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------

# Per-machine casting kept out of .zshrc, per README "Per-machine casting".
if [[ -n "$CLAUDE_CAST_FILE" && -r "$CLAUDE_CAST_FILE" ]]; then
  source "$CLAUDE_CAST_FILE"
fi

_claude_cast_merge_defaults
_claude_cast_merge_agent_defaults
_claude_cast_generate_all
_claude_cast_try_completion
