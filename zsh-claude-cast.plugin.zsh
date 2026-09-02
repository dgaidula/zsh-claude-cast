# zsh-claude-cast — launchers projected from a role -> model|effort casting table.
#
# Works via oh-my-zsh, plain `source`, zinit, and antidote. See README.md for
# install instructions and CLAUDE.md for the internals. Dependency-free zsh —
# no external commands are required to generate or run the launchers.

typeset -g CLAUDE_CAST_VERSION="0.1.0"

# ---------------------------------------------------------------------------
# Config knobs (set these — or CLAUDE_CAST[role]=… entries — BEFORE sourcing
# this file to override the defaults; see README.md "Overriding").
# ---------------------------------------------------------------------------

: ${CLAUDE_CAST_PREFIX:=cl}
: ${CLAUDE_CAST_FORCE:=0}

if ! (( ${+CLAUDE_CAST_HEADLESS_FLAGS} )); then
  typeset -ga CLAUDE_CAST_HEADLESS_FLAGS
  CLAUDE_CAST_HEADLESS_FLAGS=(-p --output-format json --setting-sources "")
fi

if ! (( ${+CLAUDE_CAST} )); then
  typeset -gA CLAUDE_CAST
fi

# Internal bookkeeping — not part of the public API.
typeset -gA _CLAUDE_CAST_GENERATED       # launcher name -> 1 (ours to redefine/remove)
typeset -gA _CLAUDE_CAST_LAUNCHER_CMD    # launcher name -> display command line
typeset -ga _CLAUDE_CAST_SKIPPED         # scratch: names skipped on the last generation pass
typeset -g _CLAUDE_CAST_COMPLETION_DONE=0

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

# Prints the shipped default table as tab-separated "role\tspec" lines.
_claude_cast_default_table() {
  cat <<'EOF'
driver	claude-fable-5-1[1m]|high
build	claude-fable-5-1[1m]|medium
chore	claude-fable-5-1[1m]|low
verify	claude-fable-5-1[1m]|xhigh
orchestrate	claude-opus-4-8[1m]|high
review	claude-opus-5|medium
sonnet	claude-sonnet-5[1m]|high
EOF
}

# Fills in any default role not already present in CLAUDE_CAST. A row a user
# set before sourcing (or via CLAUDE_CAST_FILE) always wins.
_claude_cast_merge_defaults() {
  local role spec
  while IFS=$'\t' read -r role spec; do
    [[ -z "$role" ]] && continue
    if [[ -z "${CLAUDE_CAST[$role]+x}" ]]; then
      CLAUDE_CAST[$role]="$spec"
    fi
  done < <(_claude_cast_default_table)
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
  local -a extra=("$@")

  if _claude_cast_should_skip "$name"; then
    _CLAUDE_CAST_SKIPPED+=("$name")
    return 0
  fi

  local -a fixed=(command claude --model "$model" --effort "$effort")
  (( ${#extra} )) && fixed+=("${extra[@]}")
  local -a display=("${fixed[@]}")
  if [[ "$headless" == 1 ]]; then
    fixed+=("${CLAUDE_CAST_HEADLESS_FLAGS[@]}")
    display+=("${CLAUDE_CAST_HEADLESS_FLAGS[@]}")
  fi

  local body="$(print -r -- ${(q@)fixed})"
  eval "function $name { $body \"\$@\"; }"
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
    eval "function $plain { command claude \"\$@\"; }"
    _CLAUDE_CAST_GENERATED[$plain]=1
    _CLAUDE_CAST_LAUNCHER_CMD[$plain]="command claude"
    if (( ${+functions[compdef]} )) && (( ${+functions[_claude]} )); then
      compdef _claude "$plain" 2>/dev/null
    fi
  fi

  if _claude_cast_should_skip "$cont"; then
    _CLAUDE_CAST_SKIPPED+=("$cont")
  else
    eval "function $cont { command claude --continue \"\$@\"; }"
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
# `claude-cast` subcommands
# ---------------------------------------------------------------------------

_claude_cast_cmd_list() {
  local -a roles=("${(@ok)CLAUDE_CAST}")
  local role launcher w1=4 w2=8 w3=5 w4=6 w5=5
  local -A extras

  for role in "${roles[@]}"; do
    _claude_cast_parse_spec "${CLAUDE_CAST[$role]}"
    launcher="${CLAUDE_CAST_PREFIX}${role}"
    extras[$role]="${(j: :)__cc_extra}"
    (( ${#role} > w1 )) && w1=${#role}
    (( ${#launcher} > w2 )) && w2=${#launcher}
    (( ${#__cc_model} > w3 )) && w3=${#__cc_model}
    (( ${#__cc_effort} > w4 )) && w4=${#__cc_effort}
    (( ${#extras[$role]} > w5 )) && w5=${#extras[$role]}
  done

  printf "%-${w1}s  %-${w2}s  %-${w3}s  %-${w4}s  %-${w5}s\n" ROLE LAUNCHER MODEL EFFORT EXTRA
  for role in "${roles[@]}"; do
    _claude_cast_parse_spec "${CLAUDE_CAST[$role]}"
    launcher="${CLAUDE_CAST_PREFIX}${role}"
    local extra_disp="${extras[$role]}"
    [[ -z "$extra_disp" ]] && extra_disp="-"
    printf "%-${w1}s  %-${w2}s  %-${w3}s  %-${w4}s  %-${w5}s\n" \
      "$role" "$launcher" "$__cc_model" "$__cc_effort" "$extra_disp"
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
    print -u2 -- "usage: claude-cast set <role> <model> <effort> [flags...]"
    return 1
  fi
  local role=$1 model=$2 effort=$3
  shift 3
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
  local role n=${#roles} i=0 comma
  print -r -- "{"
  for role in "${roles[@]}"; do
    (( i++ ))
    _claude_cast_parse_spec "${CLAUDE_CAST[$role]}"
    local extra_str="${(j: :)__cc_extra}"
    comma=","
    (( i == n )) && comma=""
    printf '  "%s": {"model": "%s", "effort": "%s", "extra": "%s"}%s\n' \
      "$(_claude_cast_json_escape "$role")" \
      "$(_claude_cast_json_escape "$__cc_model")" \
      "$(_claude_cast_json_escape "$__cc_effort")" \
      "$(_claude_cast_json_escape "$extra_str")" \
      "$comma"
  done
  print -r -- "}"
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
    if (( ! ${valid_efforts[(Ie)$__cc_effort]} )); then
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

_claude_cast_cmd_help() {
  cat <<EOF
zsh-claude-cast ${CLAUDE_CAST_VERSION} — launchers projected from a CLAUDE_CAST casting table

Usage: claude-cast [subcommand] [args...]

Subcommands:
  list                          Show the casting table (default)
  which <launcher-or-role>      Print the exact command line for a launcher
  set <role> <model> <effort> [flags...]
                                 Add or replace a role, then regenerate launchers
  unset <role>                  Remove a role and its launchers
  export                        Print the casting table as JSON (stable key order)
  lint                          Warn on alias model names, Haiku+effort, unknown efforts
  reload                        Regenerate launchers after editing CLAUDE_CAST directly
  help                          Show this message
  version                       Print the plugin version

Generated per role <r>: ${CLAUDE_CAST_PREFIX}<r> and ${CLAUDE_CAST_PREFIX}p<r> (headless).
Fixed helpers: ${CLAUDE_CAST_PREFIX} (bare claude), ${CLAUDE_CAST_PREFIX}r (claude --continue).
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
    export) _claude_cast_cmd_export ;;
    lint) _claude_cast_cmd_lint ;;
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
_claude_cast_generate_all
_claude_cast_try_completion
