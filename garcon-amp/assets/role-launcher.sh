#!/usr/bin/env bash
set -euo pipefail

ROLE=__ROLE__
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
WORK_PATH=$GARCON_PATH
CONFIGURED_SPEC=''
PRIMARY_SPEC=''
TITLE_SPEC_LABEL=''

usage() {
  if [[ "$ROLE" == oracle ]]; then
    printf 'Usage: %s [--review] [--spec <agent-spec>] [--] <prompt>\n' "$ROLE" >&2
    printf '       %s --start [--review] [--spec <agent-spec>] [--additional-spec <agent-spec>]... [--] <prompt>\n' "$ROLE" >&2
  elif [[ "$ROLE" == reporter ]]; then
    printf 'Usage: %s <goal>\n' "$ROLE" >&2
    printf '       %s --start <goal>\n' "$ROLE" >&2
  else
    printf 'Usage: %s <prompt>\n' "$ROLE" >&2
    printf '       %s --start <prompt>\n' "$ROLE" >&2
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
spec_override=''
spec_override_set=0
additional_specs=()
reviewer_specs=()
reviewer_count=1
reviewer_success_count=1
run_outcome=finished
async_title_detail=async

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
      --spec)
        require_oracle_option --spec
        if (( spec_override_set )) || (( $# < 2 )) || [[ "$2" == --* ]]; then
          usage
          exit 2
        fi
        spec_override=$2
        spec_override_set=1
        shift 2
        ;;
      --additional-spec)
        require_oracle_option --additional-spec
        if [[ "$mode" != start && "$mode" != detached ]]; then
          printf '%s: --additional-spec requires --start\n' "$ROLE" >&2
          exit 2
        fi
        if (( $# < 2 )) || [[ "$2" == --* ]]; then
          usage
          exit 2
        fi
        additional_specs+=("$2")
        shift 2
        ;;
      *) break ;;
    esac
  done
fi

case "$mode" in
  blocking|start)
    if (( ! prompt_escaped )); then
      case "${1-}" in
        --*) usage; exit 2 ;;
      esac
    fi
    if (( $# != 1 )); then usage; exit 2; fi
    user_prompt=$1
    if [[ -z "${user_prompt//[[:space:]]/}" ]]; then
      printf '%s: prompt must not be empty\n' "$ROLE" >&2
      exit 2
    fi
    ;;
  detached)
    if (( $# != 1 )) || [[ ! -f "$1" || -L "$1" ]]; then usage; exit 2; fi
    user_prompt="$(<"$1")"
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
ROLE_PROVENANCE=$ROLE
if (( review_mode )); then
  ROLE_ACTIVITY_TITLE="$ROLE_TITLE review"
  ROLE_PROVENANCE="$ROLE review"
fi

require_private_directory() {
  local directory=$1
  if [[ ! -d "$directory" || -L "$directory" || ! -O "$directory" ]]; then
    printf '%s: unsafe or missing private directory: %s\n' "$ROLE" "$directory" >&2
    exit 1
  fi
}

require_private_directory "$STATE_PATH"

load_role_config() {
  local line spec='' matches=0
  if [[ ! -f "$CONFIG_PATH" || -L "$CONFIG_PATH" || ! -O "$CONFIG_PATH" || ! -r "$CONFIG_PATH" ]]; then
    printf '%s: unsafe or missing active role config: %s\n' "$ROLE" "$CONFIG_PATH" >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$ROLE="* ]]; then
      matches=$((matches + 1))
      spec="${line#*=}"
    fi
  done <"$CONFIG_PATH"
  if (( matches != 1 )) || [[ -z "$spec" ]]; then
    printf '%s: active role config must contain exactly one nonempty %s assignment: %s\n' \
      "$ROLE" "$ROLE" "$CONFIG_PATH" >&2
    exit 1
  fi

  CONFIGURED_SPEC=$spec
}

parse_agent_spec() {
  local spec=$1 first='' second='' third='' extra='' canonical=''
  AGENT=''
  PROVIDER=''
  MODEL=''
  EFFORT_OR_VARIANT=''
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

if [[ "$mode" != status && "$mode" != kill ]]; then
  load_role_config
  if ! parse_agent_spec "$CONFIGURED_SPEC"; then
    printf '%s: invalid active agent spec: %s\n' "$ROLE" "$CONFIGURED_SPEC" >&2
    exit 1
  fi

  PRIMARY_SPEC=$CONFIGURED_SPEC
  if (( spec_override_set )); then
    PRIMARY_SPEC=$spec_override
    if ! parse_agent_spec "$PRIMARY_SPEC"; then
      printf '%s: invalid --spec agent spec: %s\n' "$ROLE" "$PRIMARY_SPEC" >&2
      exit 2
    fi
  fi

  reviewer_specs=("$PRIMARY_SPEC")

  validated_additional_specs=()
  for spec in "${additional_specs[@]}"; do
    if ! parse_agent_spec "$spec"; then
      printf '%s: invalid --additional-spec agent spec: %s\n' "$ROLE" "$spec" >&2
      exit 2
    fi
    for selected_spec in "${validated_additional_specs[@]}"; do
      if [[ "$spec" == "$selected_spec" ]]; then
        printf '%s: duplicate reviewer agent spec: %s\n' "$ROLE" "$spec" >&2
        exit 2
      fi
    done
    validated_additional_specs+=("$spec")
    if [[ "$spec" == "$PRIMARY_SPEC" ]]; then
      if (( spec_override_set )); then
        printf '%s: duplicate reviewer agent spec: %s\n' "$ROLE" "$spec" >&2
        exit 2
      fi
      continue
    fi
    reviewer_specs+=("$spec")
  done
  reviewer_count=${#reviewer_specs[@]}
  TITLE_SPEC_LABEL=$PRIMARY_SPEC
  if (( reviewer_count > 1 )); then
    async_title_detail+=", $reviewer_count reviewers"
    TITLE_SPEC_LABEL="primary: $PRIMARY_SPEC"
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
  WORK_PATH=$GARCON_PATH
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
on_termination_signal() {
  killed_by_signal=1
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
  local temporary run_id existing_pid existing_starter_pid display_pid starter_pid=''
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
    'responseBytes=0' \
    "logPath=$RUN_LOG" \
    "callback=$claim_callback" \
    "review=$review_mode" \
    "reviewers=$reviewer_count" \
    'workPath='
  if ln -- "$temporary" "$RUN_FILE" 2>/dev/null; then
    rm -f -- "$temporary"
    return 0
  fi

  load_run_state
  existing_pid="${run_state[pid]:-}"
  existing_starter_pid="${run_state[starterPid]:-}"
  if run_record_is_alive "${run_state[status]:-}" "$existing_pid" "$existing_starter_pid"; then
    display_pid=$existing_pid
    run_is_alive "$display_pid" || display_pid=$existing_starter_pid
    rm -f -- "$temporary"
    printf '%s: a consultation is already running (pid %s); use "%s --status --wait-ms 0" or "%s --kill"\n' \
      "$ROLE" "$display_pid" "$LAUNCHER_PATH" "$LAUNCHER_PATH" >&2
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

send_callback() {
  local status=$1 bytes=$2 elapsed run_id output
  local callback_title fallback_title send_status=0 fallback_status=0
  local -a callback_command callback_presentation
  load_run_state
  elapsed="$(format_elapsed "$(( EPOCHSECONDS - ${run_state[startedAt]:-$EPOCHSECONDS} ))")"
  run_id="${run_state[runId]:-unknown}"
  if (( status == 0 )); then
    if [[ "$run_outcome" == partial ]]; then
      callback_title="$ROLE_ACTIVITY_TITLE response (async, $reviewer_success_count of $reviewer_count reviewers)"
    else
      callback_title="$ROLE_ACTIVITY_TITLE response ($async_title_detail)"
    fi
    callback_presentation=(--color "$ROLE_ACCENT")
  else
    callback_title="$ROLE_ACTIVITY_TITLE failed ($async_title_detail)"
    callback_presentation=(--message-style error)
  fi
  callback_title="$(title_with_spec "$callback_title")"
  callback_command=(
    "${GARCON_CLI_ARGV[@]}" send-async "$CHAT_ID"
    --allow-steer
    --message-title "$callback_title"
    "${callback_presentation[@]}"
    --collapsible
    -
  )
  if (( status == 0 )); then
    output="$(
      {
        printf '[garcon-amp %s result: %s]\n\n' "$ROLE_PROVENANCE" "$run_id"
        print_file_with_newline "$RESPONSE_FILE"
      } | (cd "$GARCON_PATH" && "${callback_command[@]}") 2>&1
    )" || send_status=$?
  else
    output="$(
      {
        printf '[garcon-amp %s result: %s]\n\n' "$ROLE_PROVENANCE" "$run_id"
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
      } | (cd "$GARCON_PATH" && "${callback_command[@]}") 2>&1
    )" || send_status=$?
  fi

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
    "workPath=$reporter_work_path" || return 1
  # A killed run needs no callback: whoever signalled it already knows.
  if [[ "$mode" == detached ]] && (( killed_by_signal == 0 )); then
    send_callback "$status" "$bytes" || true
  fi
}

print_run_status() {
  local reported="${run_state[status]:-none}" pid="${run_state[pid]:-0}"
  local starter_pid="${run_state[starterPid]:-0}" reference
  if [[ -z "${run_state[runId]:-}" ]]; then
    printf 'role: %s\nstatus: none\n' "$ROLE"
    return 0
  fi
  if [[ "$reported" == running || "$reported" == starting ]] && \
    ! run_record_is_alive "$reported" "$pid" "$starter_pid"; then
    reported=died
  fi
  reference="${run_state[finishedAt]:-}"
  [[ -n "$reference" ]] || reference=$EPOCHSECONDS
  printf 'role: %s\n' "$ROLE"
  printf 'run: %s\n' "${run_state[runId]}"
  printf 'status: %s\n' "$reported"
  printf 'mode: %s\n' "${run_state[mode]:-unknown}"
  printf 'pid: %s\n' "$pid"
  if [[ "${run_state[review]:-0}" == 1 ]]; then
    printf 'review: yes\n'
  else
    printf 'review: no\n'
  fi
  printf 'reviewers: %s\n' "${run_state[reviewers]:-1}"
  printf 'elapsed: %s\n' "$(format_elapsed "$(( reference - ${run_state[startedAt]:-$reference} ))")"
  if [[ -n "${run_state[exitCode]:-}" ]]; then
    printf 'exit: %s\n' "${run_state[exitCode]}"
  fi
  printf 'callback: %s\n' "${run_state[callback]:-skipped}"
  printf 'response: %s (%s bytes)\n' "${run_state[responsePath]:-$RESPONSE_FILE}" "${run_state[responseBytes]:-0}"
  printf 'log: %s\n' "${run_state[logPath]:-$RUN_LOG}"
}

run_wait_is_settled() {
  local pinned=$1 reported="${run_state[status]:-}"
  local pid="${run_state[pid]:-0}" starter_pid="${run_state[starterPid]:-0}"
  [[ "${run_state[runId]:-}" == "$pinned" ]] || return 0
  if [[ "$reported" == running || "$reported" == starting ]]; then
    run_record_is_alive "$reported" "$pid" "$starter_pid" && return 1
    return 0
  fi
  # A terminal detached run remains unsettled while callback delivery is in flight.
  [[ "${run_state[callback]:-}" == pending ]] && run_is_alive "$pid" && return 1
  return 0
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
  local pid run_mode recorded_work_path cleanup_status=0
  load_run_state
  pid="${run_state[pid]:-0}"
  run_mode="${run_state[mode]:-}"
  if ! run_target_is_alive "$pid" "$run_mode"; then
    recorded_work_path="${run_state[workPath]:-}"
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
  recorded_work_path="${run_state[workPath]:-}"
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
  printf '%s' "$user_prompt" >"$PROMPT_FILE"
  chmod 600 "$PROMPT_FILE"
  rm -f -- "$RUN_LOG"
  : >"$RUN_LOG"
  chmod 600 "$RUN_LOG"

  if (( review_mode )); then detached_command+=(--review); fi
  if (( spec_override_set )); then detached_command+=(--spec "$spec_override"); fi
  for spec in "${additional_specs[@]}"; do
    detached_command+=(--additional-spec "$spec")
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
  print_run_status
}

adopt_run() {
  if [[ ! -s "$RUN_FILE" ]]; then
    printf '%s: detached run state is missing: %s\n' "$ROLE" "$RUN_FILE" >&2
    exit 1
  fi
  update_run_state \
    "pid=$$" \
    'starterPid=' \
    'status=running' \
    'mode=detached' \
    'callback=pending' \
    "review=$review_mode" \
    "reviewers=$reviewer_count"
  run_owned=1
}

case "$mode" in
  status) do_status; exit 0 ;;
  kill) do_kill; exit 0 ;;
  start) do_start; exit 0 ;;
  detached) adopt_run ;;
  blocking) claim_run blocking "$$" running skipped; run_owned=1 ;;
esac

rm -f -- "$RESPONSE_FILE"
: >"$RESPONSE_FILE"
chmod 600 "$RESPONSE_FILE"
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
  console.error(`${role}: failed to publish ${title}: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
' "$GARCON_CLI_RUNNER" "$GARCON_CLI_PATH" "$CHAT_ID" "$title" "$content_file" "$GARCON_PATH" "$ROLE" "$ROLE_ACCENT"
}

request_title="$ROLE_ACTIVITY_TITLE request"
if [[ "$mode" == detached ]]; then
  request_title+=" ($async_title_detail)"
fi
request_title="$(title_with_spec "$request_title")"

invocation_prompt=''
if [[ "$ROLE" == reporter ]]; then
  printf -v invocation_prompt '## Current request from the orchestrator

Private working directory (removed when this run ends): %s
Garcon CLI command: %s
Transcript query path: %s

Treat this request as self-contained. The parent/orchestrator owns the user task, decisions, implementation, final verification, and user communication. Use only sources and source locators supplied in the goal. Put transient files only in the private working directory and leave them there for launcher cleanup. Do not modify any source transcript, repository, Git state, or Garcon chat. Do not delegate or ask questions. Return one complete result.

Goal:
%s' \
    "$WORK_PATH" "$GARCON_CLI_COMMAND" "$TRANSCRIPT_QUERY_PATH" "$user_prompt"
else
  printf -v invocation_prompt '## Current request from the orchestrator

Initial working directory: %s
Shared sandbox directory: %s

Treat this request as self-contained. The parent/orchestrator owns the user task, all intended changes to the target repository, integration, final verification, and user communication.

You may read any path available to the current OS user. The parent and every Garcon-Amp specialist for this chat share the sandbox. Reuse any checkout, source, or artifact named in the request or already present there; never duplicate one that is safe and usable for the requested operation. Put direct investigative writes in the shared sandbox and give new artifacts distinct names. Acquire any source only when the role prompt permits it, the current request requires it, and no available source is safe and usable for that permitted operation; keep it at an absolute path in the shared sandbox and report its origin and path. Do not intentionally modify the target repository or its Git state, and do not delegate to another agent.

Return a complete result; no one can answer questions during this invocation.

%s' "$GARCON_PATH" "$SANDBOX_PATH" "$user_prompt"
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
invocation_prompt="${role_prompt}"$'\n\n---\n\n'"${invocation_prompt}"
if (( review_mode )); then
  if [[ ! -f "$REVIEW_PROMPT_PATH" || ! -r "$REVIEW_PROMPT_PATH" ]]; then
    printf '%s: review prompt is unavailable: %s\n' "$ROLE" "$REVIEW_PROMPT_PATH" >&2
    exit 1
  fi
fi

print_invocation_prompt() {
  printf '%s\n' "$invocation_prompt"
  if (( review_mode )); then
    printf '\n---\n\n'
    cat "$REVIEW_PROMPT_PATH"
  fi
}

run_codex() {
  local events_file response_file status
  local -a command=(codex)

  events_file="$(mktemp "$STATE_PATH/.$ROLE.$AGENT.events.XXXXXX")"
  response_file="$(mktemp "$STATE_PATH/.$ROLE.$AGENT.response.XXXXXX")"
  temporary_files+=("$events_file" "$response_file")
  chmod 600 "$events_file" "$response_file"

  if [[ "$EFFORT_OR_VARIANT" != default ]]; then
    command+=(-c "model_reasoning_effort=\"$EFFORT_OR_VARIANT\"")
  fi
  command+=(
    --ask-for-approval never
    --sandbox danger-full-access
    --cd "$WORK_PATH"
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
    cd "$WORK_PATH"
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
  local status variable
  local -a clean_env=(env)
  local -a command=(
    claude
    -p
    --model "$MODEL"
    --permission-mode dontAsk
    --no-session-persistence
    --add-dir /
    --tools 'Bash,Edit,Glob,Grep,Read,Write'
    --allowed-tools 'Bash,Edit,Glob,Grep,Read,Write'
  )

  if [[ "$EFFORT_OR_VARIANT" != default ]]; then
    command+=(--effort "$EFFORT_OR_VARIANT")
  fi
  while IFS='=' read -r variable _; do
    case "$variable" in
      CLAUDECODE|CLAUDE_*) clean_env+=(-u "$variable") ;;
    esac
  done < <(env)

  set +e
  (
    cd "$WORK_PATH"
    print_invocation_prompt | "${clean_env[@]}" "${command[@]}"
  )
  status=$?
  set -e

  return "$status"
}

run_pi() {
  local status
  local -a command=(
    pi -p
    --provider "$PROVIDER"
    --model "$MODEL"
    --no-session
    --tools read,grep,find,ls,bash,edit,write
    --no-skills
    --no-prompt-templates
    --no-approve
  )
  if [[ "$EFFORT_OR_VARIANT" != default ]]; then
    command+=(--thinking "$EFFORT_OR_VARIANT")
  fi

  set +e
  (
    cd "$WORK_PATH"
    print_invocation_prompt | "${command[@]}"
  )
  status=$?
  set -e

  return "$status"
}

run_opencode() {
  local events_file export_error_file export_file response_file session_file session_id
  local status parse_status export_status
  local -a command=(
    opencode run
    --pure
    --dir "$WORK_PATH"
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
  set +e
  (
    cd "$WORK_PATH"
    print_invocation_prompt | env OPENCODE_CONFIG_CONTENT="$OPENCODE_CONFIG_JSON" "${command[@]}"
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
    cd "$WORK_PATH"
    env OPENCODE_CONFIG_CONTENT="$OPENCODE_CONFIG_JSON" \
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
  local index status label successes=0
  local -a response_files=() error_files=() child_pids=() child_statuses=()

  for index in "${!reviewer_specs[@]}"; do
    response_files[index]="$(mktemp "$STATE_PATH/.$ROLE.reviewer-response.XXXXXX")"
    temporary_files+=("${response_files[index]}")
    chmod 600 "${response_files[index]}"
    error_files[index]="$(mktemp "$STATE_PATH/.$ROLE.reviewer-error.XXXXXX")"
    temporary_files+=("${error_files[index]}")
    chmod 600 "${error_files[index]}"
  done

  for index in "${!reviewer_specs[@]}"; do
    (
      child_temporary_start=${#temporary_files[@]}
      trap 'remove_temporary_files_from "$child_temporary_start"' EXIT
      parse_agent_spec "${reviewer_specs[index]}"
      run_selected_agent
    ) >"${response_files[index]}" 2>"${error_files[index]}" &
    child_pids[index]=$!
  done

  for index in "${!child_pids[@]}"; do
    if wait "${child_pids[index]}"; then
      status=0
    else
      status=$?
    fi
    if (( status == 0 )) && ! grep -q '[^[:space:]]' "${response_files[index]}"; then
      printf '%s: reviewer %s completed without a final response\n' \
        "$ROLE" "$((index + 1))" >>"${error_files[index]}"
      status=1
    fi
    child_statuses[index]=$status
  done

  : >"$RESPONSE_FILE"
  printf 'Reviewer roster (launcher-authored; reviewer bodies may contain arbitrary headings):\n' \
    >>"$RESPONSE_FILE"
  for index in "${!reviewer_specs[@]}"; do
    printf '%s. %s\n' "$((index + 1))" "${reviewer_specs[index]}" >>"$RESPONSE_FILE"
  done
  printf '\n' >>"$RESPONSE_FILE"

  for index in "${!reviewer_specs[@]}"; do
    status=${child_statuses[index]}
    label=${reviewer_specs[index]}
    printf '## Reviewer %s — %s\n\n' "$((index + 1))" "$label" >>"$RESPONSE_FILE"
    if (( status == 0 )); then
      successes=$((successes + 1))
      print_file_with_newline "${response_files[index]}" >>"$RESPONSE_FILE"
    else
      printf 'Failed: reviewer exited %s. Diagnostics: %s\n' "$status" "$RUN_LOG" >>"$RESPONSE_FILE"
      printf '%s: reviewer %s (%s) exited %s\n' \
        "$ROLE" "$((index + 1))" "$label" "$status" >&2
    fi
    if [[ -s "${error_files[index]}" ]]; then
      printf '%s: reviewer %s (%s) diagnostics:\n' "$ROLE" "$((index + 1))" "$label" >&2
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
  response_title="$(title_with_spec "$ROLE_ACTIVITY_TITLE response")"
  add_transcript_rows "$response_title" "$RESPONSE_FILE" \
    || response_row_status=$?
fi
print_file_with_newline "$RESPONSE_FILE"
if (( response_row_status != 0 )); then
  printf '%s: response row failed after the specialist completed\n' "$ROLE" >&2
  exit "$response_row_status"
fi
