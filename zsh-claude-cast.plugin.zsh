# zsh-claude-cast — launchers projected from a role -> model|effort casting table.
#
# Works via oh-my-zsh, plain `source`, zinit, and antidote. See README.md for
# install instructions and CLAUDE.md for the internals. Dependency-free zsh —
# no external commands are required to generate or run the launchers.

typeset -g CLAUDE_CAST_VERSION="0.3.0"

# ---------------------------------------------------------------------------
# Config knobs (set these — or CLAUDE_CAST[role]=… entries — BEFORE sourcing
# this file to override the defaults; see README.md "Overriding").
# ---------------------------------------------------------------------------

: ${CLAUDE_CAST_PREFIX:=cl}
: ${CLAUDE_CAST_FORCE:=0}
: ${CLAUDE_CAST_PRESET:=max20}

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

# Internal bookkeeping — not part of the public API.
typeset -gA _CLAUDE_CAST_GENERATED       # launcher name -> 1 (ours to redefine/remove)
typeset -gA _CLAUDE_CAST_LAUNCHER_CMD    # launcher name -> display command line
typeset -ga _CLAUDE_CAST_SKIPPED         # scratch: names skipped on the last generation pass
typeset -ga _CLAUDE_CAST_OVERRIDDEN_ROLES # roles the table overrode from the active preset
typeset -g _CLAUDE_CAST_COMPLETION_DONE=0

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

# The shipped preset tables, one function each, as tab-separated
# "role\tspec" lines. Keep in sync with README.md "Plan presets" and
# CLAUDE.md. Empty effort field (e.g. "claude-haiku-4-5|") means: pass no
# --effort flag at all — required for Haiku, which errors on --effort.

# casting:begin (generated from claude-ops casting.json @ 4b7a516 2026-09-02 — do not edit by hand)
# Claude Max 20x — today's default table.
_claude_cast_default_table_max20() {
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

# Claude Max 5x — Fable rationed, Opus fronts driver/orchestrate.
_claude_cast_default_table_max5() {
  cat <<'EOF'
driver	claude-opus-4-8[1m]|high
build	claude-sonnet-5[1m]|high
chore	claude-haiku-4-5|
verify	claude-fable-5-1[1m]|high
orchestrate	claude-opus-4-8[1m]|high
review	claude-opus-5|medium
sonnet	claude-sonnet-5[1m]|high
EOF
}

# Claude Pro — Sonnet-led, no Opus 5 assumed (no review row).
_claude_cast_default_table_pro() {
  cat <<'EOF'
driver	claude-sonnet-5[1m]|high
build	claude-sonnet-5[1m]|medium
chore	claude-haiku-4-5|
verify	claude-opus-4-8[1m]|high
orchestrate	claude-opus-4-8[1m]|high
sonnet	claude-sonnet-5[1m]|high
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

  local -a fixed=(command claude --model "$model")
  [[ -n "$effort" ]] && fixed+=(--effort "$effort")
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
  local role n=${#roles} i=0 comma
  print -r -- "{"
  printf '  "preset": "%s",\n' "$(_claude_cast_json_escape "$_CLAUDE_CAST_ACTIVE_PRESET")"
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
  export                        Print the casting table as JSON (stable key order)
  presets                       Print all three shipped preset tables
  lint                          Warn on alias model names, Haiku+effort, unknown efforts
  reload                        Regenerate launchers after editing CLAUDE_CAST directly
  help                          Show this message
  version                       Print the plugin version

Active preset: ${_CLAUDE_CAST_ACTIVE_PRESET} (CLAUDE_CAST_PRESET, set before sourcing).
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
    presets) _claude_cast_cmd_presets ;;
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
