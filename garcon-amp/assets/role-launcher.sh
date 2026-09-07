#!/usr/bin/env bash
set -euo pipefail

ROLE=__ROLE__
if [[ -n "${GARCON_AMP_SPECIALIST_DEPTH:-}" ]]; then
  printf '%s: nested Garcon-Amp specialist invocation is disabled\n' "$ROLE" >&2
  exit 2
fi
CHAT_ID=__CHAT_ID__
GARCON_PATH=__GARCON_PATH__
GARCON_CLI_PATH=__GARCON_CLI_PATH__
GARCON_CLI_RUNNER=__GARCON_CLI_RUNNER__
GARCON_CLI_COMMAND=__GARCON_CLI_COMMAND__
GARCON_CLI_ARGV=("$GARCON_CLI_PATH")
if [[ "$GARCON_CLI_RUNNER" == bun ]]; then
  GARCON_CLI_ARGV=(bun "$GARCON_CLI_PATH")
fi
TRANSCRIPT_QUERY_PATH=__TRANSCRIPT_QUERY_PATH__
TRANSCRIPT_XML_PATH=__TRANSCRIPT_XML_PATH__
if [[ "$ROLE" == reporter ]]; then
  export TRANSCRIPT_QUERY_PATH
fi
STATE_PATH=__STATE_PATH__
CONFIG_PATH="$STATE_PATH/garcon-amp.conf"
SANDBOX_PATH=__SANDBOX_PATH__
ROLE_TITLE=__ROLE_TITLE__
ROLE_ACCENT=__ROLE_ACCENT__
ROLE_PROMPT_PATH=__ROLE_PROMPT_PATH__
REVIEW_PROMPT_PATH=__REVIEW_PROMPT_PATH__
OPENCODE_AGENT_NAME=__OPENCODE_AGENT_NAME__
OPENCODE_CONFIG_JSON=__OPENCODE_CONFIG_JSON__
LAUNCHER_PATH="$STATE_PATH/$ROLE"
RUN_FILE="$STATE_PATH/.$ROLE.run.json"
RUN_LOG="$STATE_PATH/.$ROLE.run.log"
RESPONSE_FILE="$STATE_PATH/.$ROLE.last-response"
PROMPT_FILE="$STATE_PATH/.$ROLE.prompt"
STATUS_WAIT_LIMIT_MS=60000
AGENT=''
PROVIDER=''
MODEL=''
EFFORT_OR_VARIANT=''
WORK_PATH=$SANDBOX_PATH
INVOCATION_PATH=''
CONFIGURED_VALUE=''
CONFIGURED_SPEC_LABEL=''
PRIMARY_SPEC=''
TITLE_SPEC_LABEL=''

usage() {
  if [[ "$ROLE" == oracle ]]; then
    printf 'Usage: %s [--review] [--no-defaults] [--spec <spec-or-alias>]... [--] <prompt>\n' "$ROLE" >&2
    printf '       %s [--review] [--no-defaults] [--spec <spec-or-alias>]... --stdin\n' "$ROLE" >&2
    printf '       %s --start [--review] [--no-defaults] [--spec <spec-or-alias>]... [--] <prompt>\n' "$ROLE" >&2
    printf '       %s --start [--review] [--no-defaults] [--spec <spec-or-alias>]... --stdin\n' "$ROLE" >&2
  elif [[ "$ROLE" == reporter ]]; then
    printf 'Usage: %s <goal>\n' "$ROLE" >&2
    printf '       %s --stdin\n' "$ROLE" >&2
    printf '       %s --start <goal>\n' "$ROLE" >&2
    printf '       %s --start --stdin\n' "$ROLE" >&2
  else
    printf 'Usage: %s <prompt>\n' "$ROLE" >&2
    printf '       %s --stdin\n' "$ROLE" >&2
    printf '       %s --start <prompt>\n' "$ROLE" >&2
    printf '       %s --start --stdin\n' "$ROLE" >&2
  fi
  printf '       %s --status [--wait-ms <0-%s>]   (default: wait until the run settles)\n' \
    "$ROLE" "$STATUS_WAIT_LIMIT_MS" >&2
  printf '       %s --kill\n' "$ROLE" >&2
}

mode=blocking
review_mode=0
user_prompt=''
reporter_work_path=''
status_wait_ms=0
status_wait_bounded=0
status_wait_active=0
prompt_escaped=0
prompt_from_stdin=0
no_defaults=0
runtime_specs=()
runtime_spec_labels=()
configured_specs=()
configured_spec_labels=()
reviewer_specs=()
reviewer_spec_labels=()
declare -A spec_aliases=()
reviewer_child_pids=()
reviewer_count=1
reviewer_success_count=1
run_outcome=finished
group_title_detail=''

enable_review() {
  if [[ "$ROLE" != oracle ]]; then
    printf '%s: --review is only supported by oracle\n' "$ROLE" >&2
    exit 2
  fi
  review_mode=1
}

require_oracle_option() {
  local option=$1
  if [[ "$ROLE" != oracle ]]; then
    printf '%s: %s is only supported by oracle\n' "$ROLE" "$option" >&2
    exit 2
  fi
}

read_prompt_stream() {
  user_prompt=''
  if IFS= read -r -d '' user_prompt; then
    printf '%s: prompt must not contain NUL bytes\n' "$ROLE" >&2
    exit 2
  fi
}

require_nonblank_prompt() {
  if [[ -z "${user_prompt//[[:space:]]/}" ]]; then
    printf '%s: prompt must not be empty\n' "$ROLE" >&2
    exit 2
  fi
}

case "${1-}" in
  --help|-h) usage; exit 0 ;;
  --start)
    mode=start
    shift
    ;;
  --status) mode=status; shift ;;
  --kill) mode=kill; shift ;;
  --run-detached)
    mode=detached
    shift
    ;;
esac

if [[ "$mode" == blocking || "$mode" == start || "$mode" == detached ]]; then
  while (( $# )); do
    case "$1" in
      --)
        prompt_escaped=1
        shift
        break
        ;;
      --review)
        enable_review
        shift
        ;;
      --stdin)
        if (( prompt_from_stdin )); then
          usage
          exit 2
        fi
        prompt_from_stdin=1
        shift
        ;;
      --spec)
        require_oracle_option --spec
        if (( $# < 2 )) || [[ "$2" == --* ]]; then
          usage
          exit 2
        fi
        runtime_specs+=("$2")
        shift 2
        ;;
      --run-spec-label)
        if [[ "$mode" != detached ]] || (( $# < 2 )) || [[ "$2" == --* ]]; then
          usage
          exit 2
        fi
        runtime_spec_labels+=("$2")
        shift 2
        ;;
      --no-defaults)
        require_oracle_option --no-defaults
        if (( no_defaults )); then
          usage
          exit 2
        fi
        no_defaults=1
        shift
        ;;
      *) break ;;
    esac
  done
fi

if [[ "$mode" == detached ]]; then
  if (( ${#runtime_spec_labels[@]} != ${#runtime_specs[@]} )); then usage; exit 2; fi
else
  runtime_spec_labels=("${runtime_specs[@]}")
fi

case "$mode" in
  blocking|start)
    if (( prompt_from_stdin )); then
      if (( prompt_escaped || $# != 0 )); then usage; exit 2; fi
      read_prompt_stream
    else
      if (( ! prompt_escaped )); then
        case "${1-}" in
          --*) usage; exit 2 ;;
        esac
      fi
      if (( $# != 1 )); then usage; exit 2; fi
      user_prompt=$1
    fi
    require_nonblank_prompt
    ;;
  detached)
    if (( prompt_from_stdin || $# != 1 )) || [[ ! -f "$1" || -L "$1" ]]; then usage; exit 2; fi
    read_prompt_stream <"$1"
    require_nonblank_prompt
    ;;
  status)
    while (( $# )); do
      case "$1" in
        --wait-ms)
          if (( $# < 2 )); then usage; exit 2; fi
          status_wait_ms=$2
          status_wait_bounded=1
          shift 2
          ;;
        *) usage; exit 2 ;;
      esac
    done
    if (( status_wait_bounded )) \
      && { [[ ! "$status_wait_ms" =~ ^[0-9]+$ ]] || (( status_wait_ms > STATUS_WAIT_LIMIT_MS )); }; then
      printf '%s: --wait-ms must be an integer from 0 to %s\n' "$ROLE" "$STATUS_WAIT_LIMIT_MS" >&2
      exit 2
    fi
    ;;
  kill)
    if (( $# != 0 )); then usage; exit 2; fi
    ;;
esac

ROLE_ACTIVITY_TITLE=$ROLE_TITLE
if (( review_mode )); then
  ROLE_ACTIVITY_TITLE="$ROLE_TITLE review"
fi

require_private_directory() {
  local directory=$1
  if [[ ! -d "$directory" || -L "$directory" || ! -O "$directory" ]]; then
    printf '%s: unsafe or missing private directory: %s\n' "$ROLE" "$directory" >&2
    exit 1
  fi
}

require_private_directory "$STATE_PATH"

trim_config_whitespace() {
  local value=$1
  while [[ "$value" == ' '* || "$value" == $'\t'* ]]; do
    value=${value:1}
  done
  while [[ "$value" == *' ' || "$value" == *$'\t' ]]; do
    value=${value:0:${#value}-1}
  done
  printf '%s' "$value"
}

parse_config_assignment() {
  local line=$1
  [[ "$line" == *=* ]] || return 1
  CONFIG_ASSIGNMENT_NAME=$(trim_config_whitespace "${line%%=*}")
  CONFIG_ASSIGNMENT_VALUE=$(trim_config_whitespace "${line#*=}")
  [[ -n "$CONFIG_ASSIGNMENT_NAME" && -n "$CONFIG_ASSIGNMENT_VALUE" ]]
}

add_active_spec_alias() {
  local alias_name=$1 alias_target=$2
  if [[ ! "$alias_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf '%s: invalid active spec alias name\n' "$ROLE" >&2
    exit 1
  fi
  case "$alias_name" in
    codex|claude|pi|opencode)
      printf '%s: reserved active spec alias name: %s\n' "$ROLE" "$alias_name" >&2
      exit 1
      ;;
  esac
  if [[ -n "${spec_aliases[$alias_name]+present}" ]]; then
    printf '%s: duplicate active spec alias: %s\n' "$ROLE" "$alias_name" >&2
    exit 1
  fi
  if ! parse_spec_alias_target "$alias_target"; then
    printf '%s: invalid active spec alias target: %s\n' "$ROLE" "$alias_name" >&2
    exit 1
  fi
  spec_aliases["$alias_name"]=$alias_target
}

load_role_config() {
  local line trimmed_line spec='' spec_label='' matches=0 label_matches=0
  local alias_name alias_sections=0 in_alias_section=0 legacy_aliases=0
  if [[ ! -f "$CONFIG_PATH" || -L "$CONFIG_PATH" || ! -O "$CONFIG_PATH" || ! -r "$CONFIG_PATH" ]]; then
    printf '%s: unsafe or missing active role config: %s\n' "$ROLE" "$CONFIG_PATH" >&2
    exit 1
  fi
  spec_aliases=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    trimmed_line=$(trim_config_whitespace "$line")
    if [[ "$trimmed_line" == \#* ]]; then
      continue
    fi
    if (( in_alias_section )); then
      if [[ -z "$trimmed_line" ]]; then
        in_alias_section=0
        continue
      fi
      if [[ "$line" != \[* ]]; then
        if ! parse_config_assignment "$line"; then
          printf '%s: invalid active spec alias declaration\n' "$ROLE" >&2
          exit 1
        fi
        add_active_spec_alias "$CONFIG_ASSIGNMENT_NAME" "$CONFIG_ASSIGNMENT_VALUE"
        continue
      fi
      in_alias_section=0
    fi

    if [[ "$line" == '[spec-alias]' ]]; then
      alias_sections=$((alias_sections + 1))
      if (( alias_sections > 1 || legacy_aliases )); then
        printf '%s: active config must contain one spec alias section\n' "$ROLE" >&2
        exit 1
      fi
      in_alias_section=1
      continue
    elif [[ "$line" == '[spec-alias'* ]]; then
      printf '%s: invalid active spec alias declaration\n' "$ROLE" >&2
      exit 1
    fi

    if ! parse_config_assignment "$line"; then
      if [[ "$trimmed_line" == "spec-label:$ROLE"* ]]; then
        printf '%s: invalid active spec label declaration\n' "$ROLE" >&2
        exit 1
      elif [[ "$trimmed_line" == spec-alias* ]]; then
        printf '%s: invalid active spec alias declaration\n' "$ROLE" >&2
        exit 1
      fi
      continue
    fi

    if [[ "$CONFIG_ASSIGNMENT_NAME" == "$ROLE" ]]; then
      matches=$((matches + 1))
      spec=$CONFIG_ASSIGNMENT_VALUE
    elif [[ "$CONFIG_ASSIGNMENT_NAME" == "spec-label:$ROLE" ]]; then
      label_matches=$((label_matches + 1))
      spec_label=$CONFIG_ASSIGNMENT_VALUE
    elif [[ "$CONFIG_ASSIGNMENT_NAME" == "spec-label:$ROLE"* ]]; then
      printf '%s: invalid active spec label declaration\n' "$ROLE" >&2
      exit 1
    elif [[ "$CONFIG_ASSIGNMENT_NAME" == spec-alias:* ]]; then
      if (( alias_sections )); then
        printf '%s: active config must contain one spec alias section\n' "$ROLE" >&2
        exit 1
      fi
      legacy_aliases=1
      alias_name=${CONFIG_ASSIGNMENT_NAME#spec-alias:}
      add_active_spec_alias "$alias_name" "$CONFIG_ASSIGNMENT_VALUE"
    elif [[ "$CONFIG_ASSIGNMENT_NAME" == spec-alias* ]]; then
      printf '%s: invalid active spec alias declaration\n' "$ROLE" >&2
      exit 1
    fi
  done <"$CONFIG_PATH"
  if (( matches != 1 )) || [[ -z "$spec" ]]; then
    printf '%s: active role config must contain exactly one nonempty %s assignment: %s\n' \
      "$ROLE" "$ROLE" "$CONFIG_PATH" >&2
    exit 1
  fi
  if (( label_matches > 1 )) || { (( label_matches == 1 )) && [[ -z "$spec_label" ]]; }; then
    printf '%s: active role config must contain at most one nonempty %s spec label: %s\n' \
      "$ROLE" "$ROLE" "$CONFIG_PATH" >&2
    exit 1
  fi

  CONFIGURED_VALUE=$spec
  CONFIGURED_SPEC_LABEL=${spec_label:-$spec}
}

parse_agent_spec() {
  local spec=$1 first='' second='' third='' extra='' canonical=''
  AGENT=''
  PROVIDER=''
  MODEL=''
  EFFORT_OR_VARIANT=''
  [[ "$spec" != *,* && "$spec" != *$'\r'* ]] || return 1
  IFS=: read -r AGENT first second third extra <<<"$spec"
  case "$AGENT" in
    codex)
      if [[ -z "$first" || -z "$second" || -n "$third" || -n "$extra" ]]; then
        return 1
      fi
      MODEL=$first
      EFFORT_OR_VARIANT=$second
      case "$EFFORT_OR_VARIANT" in default|minimal|low|medium|high|xhigh|max) ;; *)
        return 1 ;;
      esac
      canonical="$AGENT:$MODEL:$EFFORT_OR_VARIANT"
      ;;
    claude)
      if [[ -z "$first" || -z "$second" || -n "$third" || -n "$extra" ]]; then
        return 1
      fi
      MODEL=$first
      EFFORT_OR_VARIANT=$second
      case "$EFFORT_OR_VARIANT" in default|low|medium|high|xhigh|max) ;; *)
        return 1 ;;
      esac
      canonical="$AGENT:$MODEL:$EFFORT_OR_VARIANT"
      ;;
    pi|opencode)
      if [[ -z "$first" || -z "$second" || -z "$third" || -n "$extra" || ! "$first" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 1
      fi
      PROVIDER=$first
      MODEL=$second
      EFFORT_OR_VARIANT=$third
      if [[ "$AGENT" == pi ]]; then
        case "$EFFORT_OR_VARIANT" in default|off|minimal|low|medium|high|xhigh|max) ;; *)
          return 1 ;;
        esac
      fi
      canonical="$AGENT:$PROVIDER:$MODEL:$EFFORT_OR_VARIANT"
      ;;
    *) return 1 ;;
  esac
  [[ "$spec" == "$canonical" ]]
}

parse_spec_alias_target() {
  local target=$1
  [[ "$target" != *,* && "$target" != *$'\r'* ]] || return 1
  if parse_agent_spec "$target"; then
    return 0
  fi
  if [[ "$target" =~ ^(codex|claude):[^,:]+$ ]]; then
    return 0
  fi
  [[ "$target" =~ ^(pi|opencode):[A-Za-z0-9._-]+:[^,:]+$ ]]
}

resolve_agent_spec_alias() {
  local input=$1 name=${1%%:*}
  RESOLVED_SPEC=$input
  RESOLVED_ALIAS_NAME=''
  if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    && [[ -n "${spec_aliases[$name]+present}" ]]; then
    RESOLVED_SPEC="${spec_aliases[$name]}${input:${#name}}"
    RESOLVED_ALIAS_NAME=$name
  fi
}

validate_stored_spec_label() {
  local label=$1 resolved_spec=$2 name level
  if parse_agent_spec "$label"; then
    [[ "$label" == "$resolved_spec" ]]
    return
  fi
  name=${label%%:*}
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then return 1; fi
  case "$name" in codex|claude|pi|opencode) return 1 ;; esac
  if [[ "$label" == *:* ]]; then
    level=${label#*:}
    if [[ -z "$level" || "$level" == *:* || "$level" == *,* || "$level" == *$'\r'* ]]; then
      return 1
    fi
  fi
}

if [[ "$mode" != status && "$mode" != kill ]]; then
  load_role_config
  if [[ "$ROLE" == oracle ]]; then
    if [[ "$CONFIGURED_VALUE" == ,* || "$CONFIGURED_VALUE" == *, || "$CONFIGURED_VALUE" == *,,* ]]; then
      printf '%s: invalid active Oracle reviewer list\n' "$ROLE" >&2
      exit 1
    fi
    IFS=, read -r -a configured_specs <<<"$CONFIGURED_VALUE"
  else
    configured_specs=("$CONFIGURED_VALUE")
  fi
  if [[ "$ROLE" == oracle ]]; then
    if [[ "$CONFIGURED_SPEC_LABEL" == ,* || "$CONFIGURED_SPEC_LABEL" == *, || "$CONFIGURED_SPEC_LABEL" == *,,* ]]; then
      printf '%s: invalid active Oracle spec label list\n' "$ROLE" >&2
      exit 1
    fi
    IFS=, read -r -a configured_spec_labels <<<"$CONFIGURED_SPEC_LABEL"
  else
    configured_spec_labels=("$CONFIGURED_SPEC_LABEL")
  fi
  if (( ${#configured_spec_labels[@]} != ${#configured_specs[@]} )); then
    printf '%s: active spec label count does not match configured reviewers\n' "$ROLE" >&2
    exit 1
  fi

  validated_configured_specs=()
  validated_configured_spec_labels=()
  for index in "${!configured_specs[@]}"; do
    spec=${configured_specs[index]}
    if ! parse_agent_spec "$spec"; then
      if [[ "$ROLE" == oracle ]]; then
        printf '%s: invalid active agent spec for configured reviewer %s\n' \
          "$ROLE" "$((index + 1))" >&2
      else
        printf '%s: invalid active agent spec\n' "$ROLE" >&2
      fi
      exit 1
    fi
    if ! validate_stored_spec_label "${configured_spec_labels[index]}" "$spec"; then
      if [[ "$ROLE" == oracle ]]; then
        printf '%s: invalid active spec label for configured reviewer %s\n' \
          "$ROLE" "$((index + 1))" >&2
      else
        printf '%s: invalid active spec label\n' "$ROLE" >&2
      fi
      exit 1
    fi
    for selected_label in "${validated_configured_spec_labels[@]}"; do
      if [[ "${configured_spec_labels[index]}" == "$selected_label" ]]; then
        printf '%s: duplicate active spec label for configured reviewer %s\n' \
          "$ROLE" "$((index + 1))" >&2
        exit 1
      fi
    done
    for selected_spec in "${validated_configured_specs[@]}"; do
      if [[ "$spec" == "$selected_spec" ]]; then
        printf '%s: duplicate active agent spec for configured reviewer %s\n' \
          "$ROLE" "$((index + 1))" >&2
        exit 1
      fi
    done
    validated_configured_specs+=("$spec")
    validated_configured_spec_labels+=("${configured_spec_labels[index]}")
  done

  if (( no_defaults )); then
    reviewer_specs=()
    reviewer_spec_labels=()
  else
    reviewer_specs=("${configured_specs[@]}")
    reviewer_spec_labels=("${configured_spec_labels[@]}")
  fi

  validated_runtime_specs=()
  for index in "${!runtime_specs[@]}"; do
    raw_spec=${runtime_specs[index]}
    spec_label=${runtime_spec_labels[index]}
    resolve_agent_spec_alias "$raw_spec"
    spec=$RESOLVED_SPEC
    if ! parse_agent_spec "$spec"; then
      if [[ -n "$RESOLVED_ALIAS_NAME" ]]; then
        printf '%s: invalid --spec agent spec "%s"; alias "%s" resolved to "%s"\n' \
          "$ROLE" "$raw_spec" "$RESOLVED_ALIAS_NAME" "$spec" >&2
      else
        printf '%s: invalid --spec agent spec: %s\n' "$ROLE" "$spec" >&2
      fi
      exit 2
    fi
    if [[ "$mode" == detached ]]; then
      resolve_agent_spec_alias "$spec_label"
      if [[ "$RESOLVED_SPEC" != "$spec" ]]; then
        printf '%s: invalid detached spec label for reviewer %s\n' \
          "$ROLE" "$((index + 1))" >&2
        exit 2
      fi
    fi
    for selected_spec in "${validated_runtime_specs[@]}"; do
      if [[ "$spec" == "$selected_spec" ]]; then
        if [[ "$raw_spec" != "$spec" ]]; then
          printf '%s: duplicate reviewer agent spec after alias resolution: %s\n' "$ROLE" "$spec" >&2
        else
          printf '%s: duplicate reviewer agent spec: %s\n' "$ROLE" "$spec" >&2
        fi
        exit 2
      fi
    done
    validated_runtime_specs+=("$spec")
    if (( ! no_defaults )); then
      configured_match=0
      for selected_spec in "${configured_specs[@]}"; do
        if [[ "$spec" == "$selected_spec" ]]; then
          configured_match=1
          break
        fi
      done
      (( configured_match )) && continue
    fi
    reviewer_specs+=("$spec")
    reviewer_spec_labels+=("$spec_label")
  done
  runtime_specs=("${validated_runtime_specs[@]}")

  if (( ${#reviewer_specs[@]} == 0 )); then
    printf '%s: --no-defaults requires at least one --spec\n' "$ROLE" >&2
    exit 2
  fi

  reviewer_count=${#reviewer_specs[@]}
  PRIMARY_SPEC=${reviewer_specs[0]}
  TITLE_SPEC_LABEL=${reviewer_spec_labels[0]}
  if (( reviewer_count > 1 )); then
    group_title_detail="$reviewer_count reviewers"
    for spec_label in "${reviewer_spec_labels[@]:1}"; do
      TITLE_SPEC_LABEL+=", $spec_label"
    done
  fi

  for spec in "${reviewer_specs[@]}"; do
    parse_agent_spec "$spec"
    if ! command -v "$AGENT" >/dev/null 2>&1; then
      printf '%s: required invocation executable is not on PATH: %s\n' "$ROLE" "$AGENT" >&2
      exit 1
    fi
  done
  parse_agent_spec "$PRIMARY_SPEC"
fi
require_private_directory "$SANDBOX_PATH"

temporary_files=()
run_owned=0
killed_by_signal=0
invocation_path=''

create_invocation_path() {
  invocation_path="$(mktemp -d "$STATE_PATH/.garcon-amp-launch.XXXXXX")"
  chmod 700 "$invocation_path"
  INVOCATION_PATH=$invocation_path
}

remove_invocation_path() {
  local candidate=$1 relative
  if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
    return 0
  fi
  relative="${candidate#"$STATE_PATH"/}"
  if [[
    "$candidate" != "$STATE_PATH"/.garcon-amp-launch.*
    || "$relative" == */*
    || ! -d "$candidate"
    || -L "$candidate"
    || ! -O "$candidate"
  ]]; then
    printf '%s: refusing unsafe launch-directory cleanup path: %s\n' "$ROLE" "$candidate" >&2
    return 1
  fi
  rm -rf -- "$candidate"
}

cleanup_invocation_path() {
  [[ -n "$invocation_path" ]] || return 0
  remove_invocation_path "$invocation_path" || return
  invocation_path=''
  INVOCATION_PATH=''
}

create_reporter_work_path() {
  reporter_work_path="$(mktemp -d "$SANDBOX_PATH/.garcon-amp-reporter.XXXXXX")"
  chmod 700 "$reporter_work_path"
  WORK_PATH=$reporter_work_path
}

remove_reporter_work_path() {
  local candidate=$1 relative
  if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
    return 0
  fi
  relative="${candidate#"$SANDBOX_PATH"/}"
  if [[
    "$candidate" != "$SANDBOX_PATH"/.garcon-amp-reporter.*
    || "$relative" == */*
    || ! -d "$candidate"
    || -L "$candidate"
    || ! -O "$candidate"
  ]]; then
    printf '%s: refusing unsafe Reporter cleanup path: %s\n' "$ROLE" "$candidate" >&2
    return 1
  fi
  if ! rm -rf -- "$candidate"; then
    return 1
  fi
}

cleanup_reporter_work_path() {
  [[ -n "$reporter_work_path" ]] || return 0
  remove_reporter_work_path "$reporter_work_path" || return
  reporter_work_path=''
  WORK_PATH=$SANDBOX_PATH
}

remove_temporary_files_from() {
  local start=$1 index file
  for ((index = start; index < ${#temporary_files[@]}; index++)); do
    file=${temporary_files[index]}
    [[ -z "$file" ]] || rm -f -- "$file"
  done
}

cleanup() {
  local status=0
  remove_temporary_files_from 0
  cleanup_invocation_path || status=$?
  cleanup_reporter_work_path || status=$?
  return "$status"
}

on_exit() {
  local status=$?
  cleanup || true
  if (( run_owned )); then
    finalize_run "$status" || true
  fi
}
trap on_exit EXIT

# A terminating signal must produce a deterministic status: without these traps
# Bash can leave $? at 0 in the EXIT trap after the foreground child is killed,
# which would report an interrupted consultation as a successful one.
terminate_reviewer_children() {
  local pid attempt alive
  for pid in "${reviewer_child_pids[@]}"; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    signal_run TERM "$pid"
  done
  for ((attempt = 0; attempt < 4; attempt++)); do
    alive=0
    for pid in "${reviewer_child_pids[@]}"; do
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && run_process_group_is_alive "$pid"; then
        alive=1
        break
      fi
    done
    (( alive )) || break
    sleep 0.1 &
    wait $! || true
  done
  for pid in "${reviewer_child_pids[@]}"; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    run_process_group_is_alive "$pid" && signal_run KILL "$pid"
  done
  reviewer_child_pids=()
}

on_termination_signal() {
  killed_by_signal=1
  terminate_reviewer_children
  if (( status_wait_active )); then
    status_wait_active=0
    load_run_state || true
    print_run_status || true
  fi
  exit 143
}
trap on_termination_signal TERM
trap on_termination_signal HUP
trap on_termination_signal INT

declare -A run_state=()

render_run_state() {
  local source=$1 target=$2
  shift 2
  bun -e '
const [source, target, ...pairs] = Bun.argv.slice(1);
const numericKeys = new Set([
  "pid", "starterPid", "startedAt", "finishedAt", "exitCode", "responseBytes", "review", "reviewers",
]);
let state = {};
try {
  const parsed = JSON.parse(await Bun.file(source).text());
  if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) state = parsed;
} catch {}
for (const pair of pairs) {
  const at = pair.indexOf("=");
  const key = pair.slice(0, at);
  const raw = pair.slice(at + 1);
  if (raw === "") state[key] = null;
  else if (numericKeys.has(key) && /^-?\d+$/.test(raw)) state[key] = Number(raw);
  else state[key] = raw;
}
await Bun.write(target, `${JSON.stringify(state, null, 2)}\n`);
' "$source" "$target" "$@"
}

load_run_state() {
  local key value
  run_state=()
  [[ -s "$RUN_FILE" ]] || return 0
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    run_state["$key"]="$value"
  done < <(bun -e '
let state = {};
try {
  const parsed = JSON.parse(await Bun.file(Bun.argv[1]).text());
  if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) state = parsed;
} catch {}
for (const [key, value] of Object.entries(state)) {
  if (value === null || typeof value === "object") continue;
  const text = String(value);
  if (/[\r\n]/.test(text)) continue;
  process.stdout.write(`${key}=${text}\n`);
}
' "$RUN_FILE")
}

update_run_state() {
  local temporary
  temporary="$(mktemp "$STATE_PATH/.$ROLE.run.XXXXXX")"
  chmod 600 "$temporary"
  render_run_state "$RUN_FILE" "$temporary" "$@"
  mv -f -- "$temporary" "$RUN_FILE"
}

cleanup_recorded_reporter_work_path() {
  local candidate=$1
  [[ "$ROLE" == reporter && -n "$candidate" ]] || return 0
  remove_reporter_work_path "$candidate" || return
  update_run_state 'workPath='
}

cleanup_recorded_invocation_path() {
  local candidate=$1
  [[ -n "$candidate" ]] || return 0
  remove_invocation_path "$candidate" || return
  update_run_state 'launchPath='
}

run_is_alive() {
  local pid=$1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null
}

run_process_group_is_alive() {
  local pid=$1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 -- "-$pid" 2>/dev/null
}

run_target_is_alive() {
  local pid=$1 run_mode=$2
  if [[ "$run_mode" == detached ]]; then
    run_process_group_is_alive "$pid"
  else
    run_is_alive "$pid"
  fi
}

run_record_is_alive() {
  local status=$1 pid=$2 starter_pid=$3
  run_is_alive "$pid" || {
    [[ "$status" == starting ]] && run_is_alive "$starter_pid"
  }
}

claim_run() {
  local claim_mode=$1 claim_pid=$2 claim_status=$3 claim_callback=$4
  local temporary run_id existing_pid existing_starter_pid starter_pid=''
  [[ "$claim_status" == starting ]] && starter_pid=$$
  run_id="$(bun -e 'console.log(crypto.randomUUID().slice(0, 6))')"
  temporary="$(mktemp "$STATE_PATH/.$ROLE.run.XXXXXX")"
  chmod 600 "$temporary"
  render_run_state /dev/null "$temporary" \
    "runId=$run_id" \
    "pid=$claim_pid" \
    "starterPid=$starter_pid" \
    "mode=$claim_mode" \
    "status=$claim_status" \
    "startedAt=$EPOCHSECONDS" \
    'finishedAt=' \
    'exitCode=' \
    "responsePath=$RESPONSE_FILE" \
    'responseBytes=' \
    "logPath=$RUN_LOG" \
    "callback=$claim_callback" \
    "review=$review_mode" \
    "reviewers=$reviewer_count" \
    'launchPath=' \
    'workPath='
  if ln -- "$temporary" "$RUN_FILE" 2>/dev/null; then
    rm -f -- "$temporary"
    return 0
  fi

  load_run_state
  existing_pid="${run_state[pid]:-}"
  existing_starter_pid="${run_state[starterPid]:-}"
  if run_record_is_alive "${run_state[status]:-}" "$existing_pid" "$existing_starter_pid"; then
    rm -f -- "$temporary"
    printf '%s: a consultation is already running; use "%s --status --wait-ms 0" or "%s --kill"\n' \
      "$ROLE" "$LAUNCHER_PATH" "$LAUNCHER_PATH" >&2
    exit 3
  fi
  rm -f -- "$RUN_FILE"
  if ln -- "$temporary" "$RUN_FILE" 2>/dev/null; then
    rm -f -- "$temporary"
    return 0
  fi
  rm -f -- "$temporary"
  printf '%s: could not claim the run lock: %s\n' "$ROLE" "$RUN_FILE" >&2
  exit 3
}

reset_response_file() {
  rm -f -- "$RESPONSE_FILE"
  : >"$RESPONSE_FILE"
  chmod 600 "$RESPONSE_FILE"
  update_run_state 'responseBytes=0'
}

format_elapsed() {
  local total=$1 hours minutes seconds
  (( total >= 0 )) || total=0
  hours=$(( total / 3600 ))
  minutes=$(( (total % 3600) / 60 ))
  seconds=$(( total % 60 ))
  if (( hours > 0 )); then
    printf '%dh%02dm%02ds' "$hours" "$minutes" "$seconds"
  elif (( minutes > 0 )); then
    printf '%dm%02ds' "$minutes" "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

title_with_spec() {
  local base=$1
  bun -e '
const [base, rawSpec] = Bun.argv.slice(1);
const maximumCodePoints = 120;
const spec = rawSpec.replace(/[\p{Cc}\p{Zl}\p{Zp}]/gu, (character) => {
  const codePoint = character.codePointAt(0).toString(16).padStart(4, "0");
  return `\\u${codePoint}`;
});
const prefix = `${base} [`;
const suffix = "]";
const fixedCodePoints = [...prefix].length + [...suffix].length;
const availableSpecCodePoints = maximumCodePoints - fixedCodePoints;
if (availableSpecCodePoints < 2) {
  console.error(`cannot add an agent spec to transcript title: ${base}`);
  process.exit(1);
}
const specCodePoints = [...spec];
let displayedSpec = spec;
if (specCodePoints.length > availableSpecCodePoints) {
  displayedSpec = `${specCodePoints.slice(0, availableSpecCodePoints - 1).join("")}…`;
}
console.log(`${prefix}${displayedSpec}${suffix}`);
' "$base" "$TITLE_SPEC_LABEL"
}

print_callback_result() {
  local status=$1 bytes=$2 elapsed=$3 run_id=$4
  printf '<garcon-amp-result agent="%s" ref="%s">\n\n' "$ROLE" "$run_id"
  if (( status == 0 )); then
    print_file_with_newline "$RESPONSE_FILE"
  else
    if (( reviewer_count > 1 )); then
      printf 'Failed: all %s reviewers exited without a result after %s; delegated question unanswered. Diagnostics: %s\n' \
        "$reviewer_count" "$elapsed" "$RUN_LOG"
      if (( bytes > 0 )); then
        printf '\n'
        print_file_with_newline "$RESPONSE_FILE"
      fi
    else
      printf 'Failed: async %s consultation exited %s after %s; delegated question unanswered. Diagnostics: %s\n' \
        "$ROLE_ACTIVITY_TITLE" "$status" "$elapsed" "$RUN_LOG"
    fi
    if (( reviewer_count == 1 && bytes > 0 )); then
      printf '\nPartial output (%s bytes; incomplete):\n\n' "$bytes"
      print_file_with_newline "$RESPONSE_FILE"
    fi
  fi
  printf '\n\n</garcon-amp-result>\n'
}

send_callback() {
  local status=$1 bytes=$2 elapsed run_id output
  local callback_title fallback_title send_status=0 fallback_status=0
  local -a callback_command callback_presentation
  load_run_state
  elapsed="$(format_elapsed "$(( EPOCHSECONDS - ${run_state[startedAt]:-$EPOCHSECONDS} ))")"
  run_id="${run_state[runId]:-unknown}"
  if (( status == 0 )); then
    callback_title="$ROLE_ACTIVITY_TITLE response (async)"
    callback_presentation=(--color "$ROLE_ACCENT")
  else
    callback_title="$ROLE_ACTIVITY_TITLE failed (async)"
    callback_presentation=(--message-style error)
  fi
  callback_title="$(title_with_spec "$callback_title")"
  callback_command=(
    "${GARCON_CLI_ARGV[@]}" resume-async "$CHAT_ID"
    --allow-steer
    --message-title "$callback_title"
    "${callback_presentation[@]}"
    --collapsible
    -
  )
  output="$(
    print_callback_result "$status" "$bytes" "$elapsed" "$run_id" \
      | (cd "$GARCON_PATH" && "${callback_command[@]}") 2>&1
  )" || send_status=$?

  if (( send_status != 0 )) || [[ "$output" != *"chat id: $CHAT_ID"* ]]; then
    printf '%s: callback delivery failed: %s\n' "$ROLE" "$output" >&2
    if (( status == 0 )); then
      fallback_title="$(title_with_spec "$ROLE_ACTIVITY_TITLE response (callback failed)")"
      add_transcript_rows \
        "$fallback_title" "$RESPONSE_FILE" \
        || fallback_status=$?
      if (( fallback_status != 0 )); then
        printf '%s: callback and fallback response row both failed; response remains at %s\n' \
          "$ROLE" "$RESPONSE_FILE" >&2
      else
        printf '%s: published fallback response row after callback failure\n' "$ROLE" >&2
      fi
    fi
    update_run_state 'callback=failed' || true
    return 1
  fi
  printf '%s: callback delivered\n%s\n' "$ROLE" "$output" >&2
  update_run_state 'callback=sent' || true
}

finalize_run() {
  local status=$1 bytes=0 final=$run_outcome
  run_owned=0
  if [[ -s "$RESPONSE_FILE" ]]; then
    bytes="$(wc -c <"$RESPONSE_FILE")"
  fi
  (( status == 0 )) || final=failed
  (( killed_by_signal == 0 )) || final=killed
  update_run_state \
    "status=$final" \
    "exitCode=$status" \
    "finishedAt=$EPOCHSECONDS" \
    "responseBytes=$bytes" \
    "launchPath=$invocation_path" \
    "workPath=$reporter_work_path" || return 1
  # A killed run needs no callback: whoever signalled it already knows.
  if [[ "$mode" == detached ]] && (( killed_by_signal == 0 )); then
    send_callback "$status" "$bytes" || true
  fi
}

print_run_status() {
  local reported="${run_state[status]:-none}" pid="${run_state[pid]:-0}"
  local starter_pid="${run_state[starterPid]:-0}" response_path
  if [[ -z "${run_state[runId]:-}" ]]; then
    printf 'status: none\n'
    return 0
  fi
  if [[ "$reported" == running || "$reported" == starting ]] && \
    ! run_record_is_alive "$reported" "$pid" "$starter_pid"; then
    reported=died
  fi
  printf 'status: %s\n' "$reported"
  if [[ "$reported" == running || "$reported" == starting ]]; then
    if [[ "${run_state[callback]:-}" == pending ]]; then
      printf 'wait: callback\n'
    else
      printf 'wait: blocking\n'
    fi
  fi
  response_path="${run_state[responsePath]:-$RESPONSE_FILE}"
  case "$reported" in
    finished|partial|failed|killed|died)
      if [[ -n "${run_state[responseBytes]:-}" && -s "$response_path" ]]; then
        printf 'response: %s\n' "$response_path"
      fi
      ;;
  esac
  case "$reported" in
    partial|failed|killed|died)
      printf 'log: %s\n' "${run_state[logPath]:-$RUN_LOG}"
      ;;
  esac
}

run_wait_is_settled() {
  local pinned=$1 attempt reported pid starter_pid
  for attempt in 0 1; do
    [[ "${run_state[runId]:-}" == "$pinned" ]] || return 0
    reported="${run_state[status]:-}"
    pid="${run_state[pid]:-0}"
    starter_pid="${run_state[starterPid]:-0}"
    if [[ "$reported" == running || "$reported" == starting ]]; then
      run_record_is_alive "$reported" "$pid" "$starter_pid" && return 1
    elif [[ "${run_state[callback]:-}" != pending ]]; then
      return 0
    elif run_is_alive "$pid"; then
      return 1
    fi

    # The runner may have committed its final state between our snapshot and
    # liveness check. Refresh once after observing its exit.
    (( attempt == 0 )) || return 0
    load_run_state
  done
}

do_status() {
  local pinned started deadline=0 interval
  load_run_state
  pinned="${run_state[runId]:-}"
  started=$SECONDS
  (( status_wait_bounded )) && deadline=$(( SECONDS + (status_wait_ms + 999) / 1000 ))
  status_wait_active=1
  while ! run_wait_is_settled "$pinned"; do
    if (( status_wait_bounded )) && (( SECONDS >= deadline )); then break; fi
    interval=0.25
    if (( ! status_wait_bounded && SECONDS - started >= 10 )); then interval=1; fi
    sleep "$interval" &
    wait $! || true
    load_run_state
  done
  status_wait_active=0
  print_run_status
}

signal_run() {
  local signal=$1 pid=$2
  kill -"$signal" -- "-$pid" 2>/dev/null || kill -"$signal" -- "$pid" 2>/dev/null || true
}

await_run_exit() {
  local pid=$1 run_mode=$2 attempts=$3
  while (( attempts > 0 )) && run_target_is_alive "$pid" "$run_mode"; do
    sleep 0.25
    attempts=$(( attempts - 1 ))
  done
}

do_kill() {
  local pid run_mode recorded_launch_path recorded_work_path cleanup_status=0
  load_run_state
  pid="${run_state[pid]:-0}"
  run_mode="${run_state[mode]:-}"
  if ! run_target_is_alive "$pid" "$run_mode"; then
    recorded_launch_path="${run_state[launchPath]:-}"
    recorded_work_path="${run_state[workPath]:-}"
    cleanup_recorded_invocation_path "$recorded_launch_path" || cleanup_status=$?
    cleanup_recorded_reporter_work_path "$recorded_work_path" || cleanup_status=$?
    load_run_state
    print_run_status
    return "$cleanup_status"
  fi
  signal_run TERM "$pid"
  await_run_exit "$pid" "$run_mode" 4
  if run_target_is_alive "$pid" "$run_mode"; then
    signal_run KILL "$pid"
    await_run_exit "$pid" "$run_mode" 8
  fi
  load_run_state
  recorded_launch_path="${run_state[launchPath]:-}"
  recorded_work_path="${run_state[workPath]:-}"
  cleanup_recorded_invocation_path "$recorded_launch_path" || cleanup_status=$?
  cleanup_recorded_reporter_work_path "$recorded_work_path" || cleanup_status=$?
  if [[ "${run_state[status]:-}" == running || "${run_state[status]:-}" == starting ]]; then
    update_run_state 'status=killed' "finishedAt=$EPOCHSECONDS" || true
  fi
  load_run_state
  print_run_status
  return "$cleanup_status"
}

do_start() {
  local waited=0 pid=''
  local -a detached_command=(setsid "$LAUNCHER_PATH" --run-detached)
  claim_run start 0 starting pending
  reset_response_file
  printf '%s' "$user_prompt" >"$PROMPT_FILE"
  chmod 600 "$PROMPT_FILE"
  rm -f -- "$RUN_LOG"
  : >"$RUN_LOG"
  chmod 600 "$RUN_LOG"

  if (( review_mode )); then detached_command+=(--review); fi
  if (( no_defaults )); then detached_command+=(--no-defaults); fi
  for index in "${!runtime_specs[@]}"; do
    detached_command+=(
      --spec "${runtime_specs[index]}"
      --run-spec-label "${runtime_spec_labels[index]}"
    )
  done
  detached_command+=("$PROMPT_FILE")
  "${detached_command[@]}" </dev/null >>"$RUN_LOG" 2>&1 &

  while (( waited < 200 )); do
    load_run_state
    pid="${run_state[pid]:-0}"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      break
    fi
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    rm -f -- "$RUN_FILE"
    printf '%s: detached consultation did not start; see %s\n' "$ROLE" "$RUN_LOG" >&2
    exit 1
  fi
  printf '%s started; result will arrive asynchronously.\n' "$ROLE_ACTIVITY_TITLE"
}

adopt_run() {
  if [[ ! -s "$RUN_FILE" ]]; then
    printf '%s: detached run state is missing: %s\n' "$ROLE" "$RUN_FILE" >&2
    exit 1
  fi
  create_invocation_path
  update_run_state \
    "pid=$$" \
    'starterPid=' \
    'status=running' \
    'mode=detached' \
    'callback=pending' \
    "review=$review_mode" \
    "reviewers=$reviewer_count" \
    "launchPath=$invocation_path"
  run_owned=1
}

case "$mode" in
  status) do_status; exit 0 ;;
  kill) do_kill; exit 0 ;;
  start) do_start; exit 0 ;;
  detached) adopt_run ;;
  blocking)
    create_invocation_path
    claim_run blocking "$$" running skipped
    reset_response_file
    run_owned=1
    ;;
esac
if [[ "$ROLE" == reporter ]]; then
  create_reporter_work_path
  update_run_state "workPath=$reporter_work_path"
fi

print_file_with_newline() {
  local file=$1
  cat "$file"
  if [[ "$(tail -c 1 "$file" | wc -l)" -eq 0 ]]; then
    printf '\n'
  fi
}

add_transcript_rows() {
  local title=$1 content_file=$2
  bun -e '
const [cliRunner, cliPath, chatId, title, contentPath, garconPath, role, accent] = Bun.argv.slice(1);
const maximumRowBytes = 64 * 1024;
const decoder = new TextDecoder("utf-8", { fatal: true });
const useMarkdown = Bun.file(contentPath).size <= maximumRowBytes;
let parts = [];
let byteLength = 0;

async function appendRow(content) {
  if (!content.trim()) {
    console.error(`${role}: cannot publish a whitespace-only transcript row`);
    process.exit(1);
  }
  const command = cliRunner === "bun" ? ["bun", cliPath] : [cliPath];
  command.push("add-row", chatId, "--color", accent, "--title", title);
  if (useMarkdown) command.push("--markdown");
  command.push("--collapsible", "-");
  const child = Bun.spawn({
    cmd: command,
    cwd: garconPath,
    env: process.env,
    stdin: "pipe",
    stdout: "ignore",
    stderr: "inherit",
  });
  child.stdin.write(content);
  child.stdin.end();
  const status = await child.exited;
  if (status !== 0) process.exit(status);
}

async function flush() {
  if (parts.length === 0) return;
  await appendRow(parts.join(""));
  parts = [];
  byteLength = 0;
}

function utf8ByteLength(character) {
  const codePoint = character.codePointAt(0);
  if (codePoint <= 0x7f) return 1;
  if (codePoint <= 0x7ff) return 2;
  if (codePoint <= 0xffff) return 3;
  return 4;
}

async function consume(text) {
  for (const character of text) {
    const characterBytes = utf8ByteLength(character);
    if (byteLength + characterBytes > maximumRowBytes) await flush();
    parts.push(character);
    byteLength += characterBytes;
  }
}

try {
  for await (const bytes of Bun.file(contentPath).stream()) {
    await consume(decoder.decode(bytes, { stream: true }));
  }
  await consume(decoder.decode());
  await flush();
} catch (error) {
  console.error(`${role}: failed to publish transcript row: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
' "$GARCON_CLI_RUNNER" "$GARCON_CLI_PATH" "$CHAT_ID" "$title" "$content_file" "$GARCON_PATH" "$ROLE" "$ROLE_ACCENT"
}

request_title="$ROLE_ACTIVITY_TITLE request"
if [[ "$mode" == detached ]]; then
  request_title+=' (async)'
elif [[ -n "$group_title_detail" ]]; then
  request_title+=" ($group_title_detail)"
fi
request_title="$(title_with_spec "$request_title")"

invocation_prompt=''
if [[ "$ROLE" == reporter ]]; then
  printf -v invocation_prompt '## Current request from the orchestrator

Launch-only working directory (removed when this run ends): %s
Private artifact directory (removed when this run ends): %s
Garcon CLI command: %s
Transcript query path: %s

The parent/orchestrator owns the user task, decisions, implementation, final verification, and user communication. Put transient files only in the private artifact directory and leave them there for launcher cleanup. No follow-up is available. Return one complete result.

Goal:
%s' \
    "$INVOCATION_PATH" "$WORK_PATH" "$GARCON_CLI_COMMAND" "$TRANSCRIPT_QUERY_PATH" "$user_prompt"
else
  printf -v invocation_prompt '## Current request from the orchestrator

Launch-only working directory (removed when this run ends): %s
Shared sandbox directory: %s

Treat this request as self-contained. The parent/orchestrator owns the user task, all intended changes to the target repository, integration, final verification, and user communication.

You may read any path available to the current OS user. The parent and every Garcon-Amp specialist for this chat share the sandbox. Reuse any checkout, source, or artifact named in the request or already present there; never duplicate one that is safe and usable for the requested operation. Only when the role prompt permits investigative writes, put them in the shared sandbox and give new artifacts distinct names. Acquire any source only when the role prompt permits it, the current request requires it, and no available source is safe and usable for that permitted operation; keep it at an absolute path in the shared sandbox and report its origin and path. Do not intentionally modify the target repository or its Git state.

Do not put artifacts or target checkouts in the launch-only directory. Return a complete result; no one can answer questions during this invocation.

%s' "$INVOCATION_PATH" "$SANDBOX_PATH" "$user_prompt"
fi

if [[ ! -f "$ROLE_PROMPT_PATH" || ! -r "$ROLE_PROMPT_PATH" ]]; then
  printf '%s: role prompt is unavailable: %s\n' "$ROLE" "$ROLE_PROMPT_PATH" >&2
  exit 1
fi
if [[ "$ROLE" == reporter ]] && {
  [[ -L "$TRANSCRIPT_QUERY_PATH" ]] \
    || [[ ! -f "$TRANSCRIPT_QUERY_PATH" ]] \
    || [[ ! -r "$TRANSCRIPT_QUERY_PATH" ]] \
    || [[ ! -x "$TRANSCRIPT_QUERY_PATH" ]];
}; then
  printf '%s: transcript query tool is unavailable: %s\n' "$ROLE" "$TRANSCRIPT_QUERY_PATH" >&2
  exit 1
fi
if [[ "$ROLE" == reporter ]] && {
  [[ -L "$TRANSCRIPT_XML_PATH" ]] \
    || [[ ! -f "$TRANSCRIPT_XML_PATH" ]] \
    || [[ ! -r "$TRANSCRIPT_XML_PATH" ]];
}; then
  printf '%s: transcript query library is unavailable: %s\n' "$ROLE" "$TRANSCRIPT_XML_PATH" >&2
  exit 1
fi
role_prompt="$(<"$ROLE_PROMPT_PATH")"
policy_prompt_path=$ROLE_PROMPT_PATH
if (( review_mode )); then
  if [[ ! -f "$REVIEW_PROMPT_PATH" || ! -r "$REVIEW_PROMPT_PATH" ]]; then
    printf '%s: review prompt is unavailable: %s\n' "$ROLE" "$REVIEW_PROMPT_PATH" >&2
    exit 1
  fi
  policy_prompt_path="$(mktemp "$STATE_PATH/.$ROLE.policy.XXXXXX")"
  temporary_files+=("$policy_prompt_path")
  chmod 600 "$policy_prompt_path"
  {
    printf '%s\n\n---\n\n' "$role_prompt"
    cat "$REVIEW_PROMPT_PATH"
  } >"$policy_prompt_path"
fi

print_invocation_prompt() {
  printf '%s\n' "$invocation_prompt"
}

render_codex_model_instructions_file() {
  bun -e '
process.stdout.write(`model_instructions_file=${JSON.stringify(Bun.argv[1])}`);
' "$policy_prompt_path"
}

render_codex_skills_override() {
  bun -e '
import path from "node:path";
import { homedir } from "node:os";
import { readdir, realpath, stat } from "node:fs/promises";

const [cwd, configuredCodexHome] = Bun.argv.slice(1);
const userHome = homedir();
const codexHome = configuredCodexHome || path.join(userHome, ".codex");
const roots = [
  path.join(codexHome, "skills"),
  path.join(codexHome, "skills", ".system"),
  path.join(userHome, ".agents", "skills"),
  "/etc/codex/skills",
];
for (let directory = cwd; ; directory = path.dirname(directory)) {
  roots.push(path.join(directory, ".agents", "skills"));
  roots.push(path.join(directory, ".codex", "skills"));
  if (directory === path.dirname(directory)) break;
}

const missing = (error) => error?.code === "ENOENT" || error?.code === "ENOTDIR";
const visitedDirectories = new Set();
const skillPaths = new Set();

const walk = async (directory, isRoot = false) => {
  let canonicalDirectory;
  try {
    canonicalDirectory = await realpath(directory);
  } catch (error) {
    if (isRoot && missing(error)) return;
    throw error;
  }
  if (visitedDirectories.has(canonicalDirectory)) return;
  visitedDirectories.add(canonicalDirectory);

  const entries = await readdir(canonicalDirectory, { withFileTypes: true });
  const skillPath = path.join(canonicalDirectory, "SKILL.md");
  try {
    if ((await stat(skillPath)).isFile()) {
      skillPaths.add(await realpath(skillPath));
    }
  } catch (error) {
    if (!missing(error)) throw error;
  }

  for (const entry of entries) {
    if (entry.name.startsWith(".")) continue;
    const entryPath = path.join(canonicalDirectory, entry.name);
    if (entry.isDirectory()) {
      await walk(entryPath);
    } else if (entry.isSymbolicLink() && (await stat(entryPath)).isDirectory()) {
      await walk(entryPath);
    }
  }
};

try {
  for (const root of roots) await walk(root, true);
  const entries = [...skillPaths]
    .sort()
    .map((skillPath) => `{path=${JSON.stringify(skillPath)},enabled=false}`);
  process.stdout.write(`skills.config=[${entries.join(",")}]`);
} catch (error) {
  console.error(`Codex skill enumeration failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
' "$INVOCATION_PATH" "${CODEX_HOME:-}"
}

render_opencode_config() {
  bun -e '
const [baseConfig, agentName, promptPath] = Bun.argv.slice(1);
const config = JSON.parse(baseConfig);
const agent = config.agent?.[agentName];
if (agent === undefined) {
  console.error(`OpenCode agent configuration is missing: ${agentName}`);
  process.exit(1);
}
agent.prompt = await Bun.file(promptPath).text();
process.stdout.write(JSON.stringify(config));
' "$OPENCODE_CONFIG_JSON" "$OPENCODE_AGENT_NAME" "$policy_prompt_path"
}

run_codex() {
  local events_file mcp_override model_instructions_file response_file sandbox_mode=danger-full-access
  local skills_override status
  local -a isolation_flags=(
    --disable apps
    --disable browser_use
    --disable browser_use_external
    --disable browser_use_full_cdp_access
    --disable computer_use
    --disable enable_mcp_apps
    --disable external_agent_memory_import
    --disable goals
    --disable hooks
    --disable in_app_browser
    --disable memories
    --disable multi_agent
    --disable multi_agent_v2
    --disable plugins
    --disable recommended_plugins
    --disable remote_plugin
    --disable skill_mcp_dependency_install
    --disable skill_search
    --disable tool_suggest
    --enable skip_host_skill_discovery
  )
  local -a command=(codex)

  if [[ "$ROLE" == finder ]]; then sandbox_mode=read-only; fi

  events_file="$(mktemp "$STATE_PATH/.$ROLE.$AGENT.events.XXXXXX")"
  response_file="$(mktemp "$STATE_PATH/.$ROLE.$AGENT.response.XXXXXX")"
  temporary_files+=("$events_file" "$response_file")
  chmod 600 "$events_file" "$response_file"

  if [[ "$EFFORT_OR_VARIANT" != default ]]; then
    command+=(-c "model_reasoning_effort=\"$EFFORT_OR_VARIANT\"")
  fi
  model_instructions_file="$(render_codex_model_instructions_file)" || return
  command+=(-c "$model_instructions_file")
  skills_override="$(render_codex_skills_override)" || return
  command+=(
    -c "$skills_override"
    -c skills.include_instructions=false
    -c skills.bundled.enabled=false
  )
  mcp_override="$({
    cd "$INVOCATION_PATH"
    codex mcp list --json "${isolation_flags[@]}"
  } | bun -e '
let servers;
try {
  servers = await new Response(Bun.stdin.stream()).json();
} catch {
  console.error("Codex emitted an invalid MCP server list");
  process.exit(1);
}
if (!Array.isArray(servers) || servers.some((server) => typeof server?.name !== "string" || !server.name)) {
  console.error("Codex emitted an invalid MCP server list");
  process.exit(1);
}
const names = [...new Set(servers.map((server) => server.name))].sort();
const disabled = names.map((name) => `${JSON.stringify(name)}={enabled=false}`);
process.stdout.write(`mcp_servers={${disabled.join(",")}}`);
')" || return
  command+=(-c "$mcp_override")
  command+=(
    "${isolation_flags[@]}"
    --ask-for-approval never
    --sandbox "$sandbox_mode"
    --cd "$INVOCATION_PATH"
    exec
    --skip-git-repo-check
    --ephemeral
  )
  command+=(
    --model "$MODEL"
    --json
    --output-last-message "$response_file"
  )

  set +e
  (
    cd "$INVOCATION_PATH"
    export GARCON_AMP_SPECIALIST_DEPTH=1
    print_invocation_prompt | "${command[@]}" -
  ) >"$events_file"
  status=$?
  set -e

  if (( status != 0 )); then
    cat "$events_file" >&2
    return "$status"
  fi

  if [[ -s "$response_file" ]]; then
    print_file_with_newline "$response_file"
    return
  fi

  bun -e '
const text = await Bun.file(Bun.argv[1]).text();
let result = "";
for (const line of text.split(/\r?\n/)) {
  if (!line) continue;
  const event = JSON.parse(line);
  if (event.type === "item.completed" && event.item?.type === "agent_message") {
    result = event.item.text ?? "";
  }
}
if (!result.trim()) {
  console.error("Codex completed without a final response");
  process.exit(1);
}
process.stdout.write(result.endsWith("\n") ? result : `${result}\n`);
' "$events_file"
}

run_claude() {
  local status tool_names='Bash,Edit,Glob,Grep,Read,Write' variable
  local -a clean_env=(env)
  local -a command

  if [[ "$ROLE" == finder ]]; then tool_names='Glob,Grep,Read'; fi
  command=(
    claude
    -p
    --safe-mode
    --model "$MODEL"
    --permission-mode dontAsk
    --permission-prompts none
    --no-session-persistence
    --strict-mcp-config
    --mcp-config '{"mcpServers":{}}'
    --disable-slash-commands
    --disallowed-tools 'Agent,Task'
    --no-chrome
    --append-system-prompt-file "$policy_prompt_path"
    --add-dir /
    --tools "$tool_names"
    --allowed-tools "$tool_names"
  )

  if [[ "$EFFORT_OR_VARIANT" != default ]]; then
    command+=(--effort "$EFFORT_OR_VARIANT")
  fi
  while IFS='=' read -r variable _; do
    case "$variable" in
      ANTHROPIC_*|CLAUDECODE|CLAUDE_*) clean_env+=(-u "$variable") ;;
    esac
  done < <(env)

  set +e
  (
    cd "$INVOCATION_PATH"
    export GARCON_AMP_SPECIALIST_DEPTH=1
    print_invocation_prompt | "${clean_env[@]}" "${command[@]}"
  )
  status=$?
  set -e

  return "$status"
}

run_pi() {
  local status tool_names=read,grep,find,ls,bash,edit,write
  local -a command

  if [[ "$ROLE" == finder ]]; then tool_names=read,grep,find,ls; fi
  command=(
    pi -p
    --provider "$PROVIDER"
    --model "$MODEL"
    --no-session
    --tools "$tool_names"
    --no-skills
    --no-prompt-templates
    --no-themes
    --no-context-files
    --append-system-prompt "$policy_prompt_path"
    --no-approve
  )
  if [[ "$EFFORT_OR_VARIANT" != default ]]; then
    command+=(--thinking "$EFFORT_OR_VARIANT")
  fi

  set +e
  (
    cd "$INVOCATION_PATH"
    export GARCON_AMP_SPECIALIST_DEPTH=1
    print_invocation_prompt | "${command[@]}"
  )
  status=$?
  set -e

  return "$status"
}

run_opencode() {
  local events_file export_error_file export_file response_file session_file session_id
  local status parse_status export_status opencode_config_json
  local -a isolated_env=(
    env
    GARCON_AMP_SPECIALIST_DEPTH=1
    OPENCODE_AUTO_SHARE=false
    OPENCODE_DISABLE_CLAUDE_CODE=true
    OPENCODE_DISABLE_EXTERNAL_SKILLS=true
    OPENCODE_DISABLE_LSP_DOWNLOAD=true
    OPENCODE_DISABLE_PROJECT_CONFIG=true
    OPENCODE_ENABLE_PARALLEL=false
    OPENCODE_ENABLE_QUESTION_TOOL=false
    OPENCODE_EXPERIMENTAL=false
    OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=false
    OPENCODE_EXPERIMENTAL_CODE_MODE=false
    OPENCODE_EXPERIMENTAL_EVENT_SYSTEM=false
    OPENCODE_EXPERIMENTAL_PARALLEL=false
    OPENCODE_EXPERIMENTAL_PLAN_MODE=false
    OPENCODE_EXPERIMENTAL_WORKSPACES=false
  )
  local -a command=(
    opencode run
    --pure
    --dir "$INVOCATION_PATH"
    --model "$PROVIDER/$MODEL"
    --agent "$OPENCODE_AGENT_NAME"
    --format json
  )

  events_file="$(mktemp "$STATE_PATH/.$ROLE.$AGENT.events.XXXXXX")"
  temporary_files+=("$events_file")
  chmod 600 "$events_file"
  export_file="$(mktemp "$SANDBOX_PATH/.$ROLE.$AGENT.export.XXXXXX")"
  temporary_files+=("$export_file")
  chmod 600 "$export_file"
  export_error_file="$(mktemp "$STATE_PATH/.$ROLE.$AGENT.export-error.XXXXXX")"
  temporary_files+=("$export_error_file")
  chmod 600 "$export_error_file"
  response_file="$(mktemp "$STATE_PATH/.$ROLE.$AGENT.response.XXXXXX")"
  temporary_files+=("$response_file")
  chmod 600 "$response_file"
  session_file="$(mktemp "$STATE_PATH/.$ROLE.$AGENT.session.XXXXXX")"
  temporary_files+=("$session_file")
  chmod 600 "$session_file"

  if [[ "$EFFORT_OR_VARIANT" != default ]]; then
    command+=(--variant "$EFFORT_OR_VARIANT")
  fi
  opencode_config_json="$(render_opencode_config)" || return
  set +e
  (
    cd "$INVOCATION_PATH"
    print_invocation_prompt \
      | "${isolated_env[@]}" OPENCODE_CONFIG_CONTENT="$opencode_config_json" "${command[@]}"
  ) >"$events_file"
  status=$?
  set -e

  if (( status != 0 )); then
    cat "$events_file" >&2
    return "$status"
  fi

  set +e
  bun -e '
const eventsPath = Bun.argv[1];
const sessionPath = Bun.argv[2];
const text = await Bun.file(eventsPath).text();
const sessionIDs = new Set();
for (const line of text.split(/\r?\n/)) {
  if (!line) continue;
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    console.error("OpenCode emitted invalid JSON");
    process.exit(1);
  }
  if (typeof event?.sessionID !== "string") {
    console.error("OpenCode emitted an event without a session identity");
    process.exit(1);
  }
  sessionIDs.add(event.sessionID);
}
const [sessionID] = sessionIDs;
if (sessionIDs.size !== 1 || !/^ses_[A-Za-z0-9_-]{1,64}$/.test(sessionID ?? "")) {
  console.error("OpenCode emitted no consistent session identity");
  process.exit(1);
}
await Bun.write(sessionPath, sessionID);
' "$events_file" "$session_file"
  parse_status=$?
  set -e

  if (( parse_status != 0 )); then
    cat "$events_file" >&2
    return 1
  fi

  session_id="$(<"$session_file")"
  set +e
  # OpenCode can truncate large exports on a pipe; direct regular-file output is required.
  (
    cd "$INVOCATION_PATH"
    "${isolated_env[@]}" OPENCODE_CONFIG_CONTENT="$opencode_config_json" \
      opencode export --pure "$session_id" </dev/null
  ) >"$export_file" 2>"$export_error_file"
  export_status=$?
  set -e
  if (( export_status != 0 )); then
    cat "$export_error_file" >&2
    printf '%s: OpenCode could not export session %s\n' "$ROLE" "$session_id" >&2
    return 1
  fi

  set +e
  bun -e '
const exportPath = Bun.argv[1];
const responsePath = Bun.argv[2];
const expectedSessionID = Bun.argv[3];
let exported;
try {
  exported = JSON.parse(await Bun.file(exportPath).text());
} catch {
  console.error("OpenCode emitted an invalid session export");
  process.exit(1);
}
if (exported?.info?.id !== expectedSessionID || !Array.isArray(exported?.messages)) {
  console.error("OpenCode emitted an invalid session export");
  process.exit(1);
}

const candidates = exported.messages.filter((message) =>
  message?.info?.role === "assistant" && message.info.summary !== true
);
let finalMessage;
for (const message of candidates) {
  const info = message.info;
  if (typeof info.id !== "string" || !Number.isFinite(info.time?.created)) {
    console.error("OpenCode emitted an invalid assistant message");
    process.exit(1);
  }
  if (
    !finalMessage
    || info.time.created > finalMessage.info.time.created
    || (info.time.created === finalMessage.info.time.created && info.id > finalMessage.info.id)
  ) finalMessage = message;
}

if (!finalMessage) {
  console.error(`OpenCode completed without a final response (session: ${expectedSessionID}, messages: ${exported.messages.length})`);
  process.exit(1);
}
const info = finalMessage.info;
const errorName = typeof info.error?.name === "string" ? info.error.name : "none";
if (
  info.sessionID !== expectedSessionID
  || info.error
  || info.finish !== "stop"
  || !Number.isFinite(info.time?.completed)
) {
  console.error(
    `OpenCode did not complete its final response (session: ${expectedSessionID}, messages: ${exported.messages.length}, finish: ${String(info.finish)}, error: ${errorName}, agent: ${String(info.agent)}, mode: ${String(info.mode)})`,
  );
  process.exit(1);
}
if (!Array.isArray(finalMessage.parts)) {
  console.error("OpenCode emitted an invalid assistant message");
  process.exit(1);
}
const result = finalMessage.parts
  .filter((part) =>
    part?.type === "text"
    && part.synthetic !== true
    && part.ignored !== true
    && typeof part.text === "string"
  )
  .map((part) => part.text)
  .join("\n");
if (!result.trim()) {
  console.error("OpenCode completed without a final response");
  process.exit(1);
}
await Bun.write(responsePath, result);
' "$export_file" "$response_file" "$session_id"
  parse_status=$?
  set -e
  if (( parse_status != 0 )); then
    cat "$export_error_file" >&2
    return 1
  fi

  if ! grep -q '[^[:space:]]' "$response_file"; then
    printf '%s: OpenCode completed without a final response\n' "$ROLE" >&2
    return 1
  fi

  print_file_with_newline "$response_file"
}

run_selected_agent() {
  case "$AGENT" in
    codex) run_codex ;;
    claude) run_claude ;;
    pi) run_pi ;;
    opencode) run_opencode ;;
    *)
      printf '%s: unsupported generated agent: %s\n' "$ROLE" "$AGENT" >&2
      return 1
      ;;
  esac
}

run_oracle_group() {
  local index status successes=0
  local -a response_files=() error_files=() child_statuses=()

  for index in "${!reviewer_specs[@]}"; do
    response_files[index]="$(mktemp "$STATE_PATH/.$ROLE.reviewer-response.XXXXXX")"
    temporary_files+=("${response_files[index]}")
    chmod 600 "${response_files[index]}"
    error_files[index]="$(mktemp "$STATE_PATH/.$ROLE.reviewer-error.XXXXXX")"
    temporary_files+=("${error_files[index]}")
    chmod 600 "${error_files[index]}"
  done

  reviewer_child_pids=()
  # Separate reviewer process groups let the launcher reap native descendants on termination.
  set -m
  for index in "${!reviewer_specs[@]}"; do
    (
      child_temporary_start=${#temporary_files[@]}
      trap 'remove_temporary_files_from "$child_temporary_start"' EXIT
      parse_agent_spec "${reviewer_specs[index]}"
      run_selected_agent
    ) >"${response_files[index]}" 2>"${error_files[index]}" &
    reviewer_child_pids[index]=$!
  done
  set +m

  for index in "${!reviewer_child_pids[@]}"; do
    if wait "${reviewer_child_pids[index]}"; then
      status=0
    else
      status=$?
    fi
    reviewer_child_pids[index]=''
    if (( status == 0 )) && ! grep -q '[^[:space:]]' "${response_files[index]}"; then
      printf '%s: reviewer %s completed without a final response\n' \
        "$ROLE" "$((index + 1))" >>"${error_files[index]}"
      status=1
    fi
    child_statuses[index]=$status
  done

  : >"$RESPONSE_FILE"
  if [[ "$mode" == detached ]]; then
    printf '%s reviewer results.\n\n' "$reviewer_count" >>"$RESPONSE_FILE"
  else
    printf 'Reviewer roster (launcher-authored; reviewer bodies may contain arbitrary headings):\n' \
      >>"$RESPONSE_FILE"
    for index in "${!reviewer_specs[@]}"; do
      printf '%s. Reviewer %s\n' "$((index + 1))" "$((index + 1))" >>"$RESPONSE_FILE"
    done
    printf '\n' >>"$RESPONSE_FILE"
  fi

  for index in "${!reviewer_specs[@]}"; do
    status=${child_statuses[index]}
    printf '## Reviewer %s\n\n' "$((index + 1))" >>"$RESPONSE_FILE"
    if (( status == 0 )); then
      successes=$((successes + 1))
      print_file_with_newline "${response_files[index]}" >>"$RESPONSE_FILE"
    else
      if [[ "$mode" == detached ]]; then
        printf 'Failed: reviewer exited %s. Diagnostics: %s\n' "$status" "$RUN_LOG" >>"$RESPONSE_FILE"
      else
        printf 'Failed: reviewer exited %s.\n' "$status" >>"$RESPONSE_FILE"
      fi
      printf '%s: reviewer %s exited %s\n' "$ROLE" "$((index + 1))" "$status" >&2
    fi
    if [[ -s "${error_files[index]}" ]]; then
      printf '%s: reviewer %s diagnostics:\n' "$ROLE" "$((index + 1))" >&2
      print_file_with_newline "${error_files[index]}" >&2
    fi
    if (( index + 1 < reviewer_count )); then
      printf '\n' >>"$RESPONSE_FILE"
    fi
  done

  if (( successes == 0 )); then
    return 1
  fi
  reviewer_success_count=$successes
  if (( successes < reviewer_count )); then
    run_outcome=partial
  fi
}

request_row_status=0
request_file="$(mktemp "$STATE_PATH/.$ROLE.request.XXXXXX")"
temporary_files+=("$request_file")
chmod 600 "$request_file"
printf '%s' "$user_prompt" >"$request_file"
add_transcript_rows "$request_title" "$request_file" \
  || request_row_status=$?
if (( request_row_status != 0 )); then
  printf '%s: request row failed; specialist was not invoked\n' "$ROLE" >&2
  exit "$request_row_status"
fi

agent_status=0
if (( reviewer_count > 1 )); then
  run_oracle_group || agent_status=$?
else
  run_selected_agent >"$RESPONSE_FILE" || agent_status=$?
fi

if ! cleanup_invocation_path; then
  agent_status=1
fi
if [[ "$ROLE" == reporter ]]; then
  if ! cleanup_reporter_work_path; then
    agent_status=1
  fi
fi

if (( agent_status != 0 )); then
  if [[ -s "$RESPONSE_FILE" ]]; then
    print_file_with_newline "$RESPONSE_FILE"
  fi
  exit "$agent_status"
fi
if ! grep -q '[^[:space:]]' "$RESPONSE_FILE"; then
  printf '%s: specialist completed without a final response\n' "$ROLE" >&2
  exit 1
fi

response_row_status=0
if [[ "$mode" == blocking ]]; then
  response_title="$ROLE_ACTIVITY_TITLE response"
  if [[ "$run_outcome" == partial ]]; then
    response_title+=" ($reviewer_success_count of $reviewer_count reviewers)"
  elif [[ -n "$group_title_detail" ]]; then
    response_title+=" ($group_title_detail)"
  fi
  response_title="$(title_with_spec "$response_title")"
  add_transcript_rows "$response_title" "$RESPONSE_FILE" \
    || response_row_status=$?
fi
print_file_with_newline "$RESPONSE_FILE"
if (( response_row_status != 0 )); then
  printf '%s: response row failed after the specialist completed\n' "$ROLE" >&2
  exit "$response_row_status"
fi
