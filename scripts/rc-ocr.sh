#!/usr/bin/env sh
# rc-ocr.sh — dispatch + deterministic mapper for an `ocr` (Alibaba
# OpenCodeReview) custom reviewer seat.
#
# Usage (the orchestrator passes ONLY these atoms — never free-form text):
#   rc-ocr.sh <slot> <result-file> --worktree
#   rc-ocr.sh <slot> <result-file> --commit <rev>
#   rc-ocr.sh <slot> <result-file> --range <base-rev> <head-rev>
#
# The script re-reads the council config itself (`rc-config.sh`, overridable via
# RC_CONFIG_SH; config dir ${RC_CONFIG_DIR:-.review-council}) and uses only the
# validated `reviewer.custom.<slot>.*` keys plus `settings.run_budget_seconds`.
#
# Output:
#   <result-file>       (also teed to stdout) — "TOOL: <slot> (ocr)" + §3.1
#                       markdown, OR one line
#                       "SKIPPED: <slot> (ocr) unavailable — ocr: <reason>".
#   <result-file>.meta  key=value routing data written by THIS script, never
#                       derived from model text: status family distinct role
#                       ocr_version findings dropped coverage [reason].
#   stderr              free-form notes + exactly one "ELAPSED: <seconds>".
#   exit                always 0 — the seat degrades, it never blocks a review.
#
# Isolation (spec §12.2, PR-1 contract):
#   - HOME is a fresh temp dir holding a council-written
#     .opencodereview/config.json (no secret in it) and a neutral rule file that
#     displaces the reviewed repo's own .opencodereview/rule.json;
#   - ocr runs under `env -i` with an allowlist — host vars such as
#     ANTHROPIC_BASE_URL / AWS_* never reach it;
#   - the provider key travels on a pipe (fd 3), never argv, never disk.
#   - the temp dir is removed on exit by a trap.
# Pre-flight (no LLM call): `ocr review --preview` (exclusion count + a changed
# path) and `ocr rules check --rule` (must report "Source: Custom (--rule)").
# Every gate is on the PARSED JSON, never on ocr's exit code.
#
# POSIX sh; no eval. The family map is sourced from rc-lib-family.sh and the
# hard-timeout watchdog (run_capped) from rc-lib-timeout.sh.

# SC2016: the jq programs below are single-quoted ON PURPOSE — $vars in them are
# jq variables, never shell expansions.
# shellcheck disable=SC2016
set -u
set -f # no globbing anywhere: config values are split on newlines below

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=rc-lib-timeout.sh
. "$SCRIPT_DIR/rc-lib-timeout.sh"
# shellcheck source-path=SCRIPTDIR source=rc-lib-family.sh
. "$SCRIPT_DIR/rc-lib-family.sh"

START_TS="$(date +%s)"
NL='
'

# --- state used by finish() (all defaults safe for an early SKIPPED) ---------
SLOT="${1:-}"
RESULT="${2:-}"
T=""
ROLE="signal"
FAMILY="unknown"
DISTINCT="false"
MODEL=""
OCR_VERSION=""
N_FINDINGS=0
N_DROPPED=0
COVERAGE=""

note() { printf 'rc-ocr: %s\n' "$*" >&2; }

# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  if [ -n "$T" ] && [ -d "$T" ]; then
    rm -rf "$T"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM HUP

# flat <text>: strip control chars, newline/tab -> space (no length cap).
flat() {
  printf '%s' "$1" | tr -d '\000-\010\013-\037\177' | tr '\n\t' '  '
}
# one_line <text>: flat + cap at 300 bytes (for reasons that may carry ocr text).
one_line() {
  flat "$1" | cut -c1-300
}

# label used in SKIPPED/TOOL lines: the slot only when it passed validation.
slot_label() {
  if valid_slot "$SLOT"; then printf '%s' "$SLOT"; else printf 'custom'; fi
}

write_meta() {
  # $1=status $2=reason
  [ -n "$RESULT" ] || return 0
  {
    printf 'status=%s\n' "$1"
    printf 'family=%s\n' "$FAMILY"
    printf 'distinct=%s\n' "$DISTINCT"
    printf 'role=%s\n' "$ROLE"
    printf 'ocr_version=%s\n' "$OCR_VERSION"
    printf 'findings=%s\n' "$N_FINDINGS"
    printf 'dropped=%s\n' "$N_DROPPED"
    printf 'coverage=%s\n' "$(flat "$COVERAGE")" # council-built: never capped
    if [ "$1" = skipped ]; then printf 'reason=%s\n' "$(one_line "$2")"; fi
  } >"$RESULT.meta" 2>/dev/null || note "cannot write $RESULT.meta"
}

emit_elapsed() {
  _now="$(date +%s)"
  printf 'ELAPSED: %s\n' "$((_now - START_TS))" >&2
}

# skip <reason>: the single SKIPPED exit path.
skip() {
  _reason="$(one_line "$1")"
  _line="SKIPPED: $(slot_label) (ocr) unavailable — ocr: $_reason"
  if [ -z "$COVERAGE" ]; then
    COVERAGE="ocr${OCR_VERSION:+ $OCR_VERSION} · $(slot_label)${MODEL:+ ($MODEL)}: SKIPPED — $_reason"
  fi
  N_FINDINGS=0
  printf '%s\n' "$_line"
  if [ -n "$RESULT" ]; then
    printf '%s\n' "$_line" >"$RESULT" 2>/dev/null || note "cannot write $RESULT"
  fi
  write_meta skipped "$_reason"
  emit_elapsed
  exit 0
}

# succeed <status> <markdown-file>: the single success exit path.
succeed() {
  if [ -n "$RESULT" ]; then
    { printf 'TOOL: %s (ocr)\n' "$SLOT"; cat "$2"; } >"$RESULT" 2>/dev/null ||
      note "cannot write $RESULT"
  fi
  printf 'TOOL: %s (ocr)\n' "$SLOT"
  cat "$2"
  write_meta "$1" ""
  emit_elapsed
  exit 0
}

# ---------------------------------------------------------------------------
# Validators (defence in depth: the reader validates too)
# ---------------------------------------------------------------------------
valid_slot() {
  case "$1" in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}
valid_modelslug() {
  [ -n "$1" ] || return 1
  [ "${#1}" -le 128 ] || return 1
  case "$1" in
    *[!A-Za-z0-9._:~@/-]*) return 1 ;;
    [!A-Za-z0-9~@]*) return 1 ;;
  esac
  return 0
}
valid_envname() {
  case "$1" in
    '' | [0-9]* | *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}
is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 9 ]
}
valid_flag_token() {
  [ -n "$1" ] && [ "${#1}" -le 256 ] || return 1
  case "$1" in
    *[!A-Za-z0-9._:/@=,+%*?-]*) return 1 ;; # glob chars allowed (--exclude)
  esac
  return 0
}
# reserved_flag <token>: isolation-critical ocr flags, never settable.
reserved_flag() {
  case "$1" in
    --rule | --rule=* | --repo | --repo=* | --from | --from=* | --to | --to=* | \
      --commit | --commit=* | --tools | --tools=* | --provider | --provider=* | \
      --model | --model=* | --output | --output=* | --format | --format=* | \
      --audience | --audience=* | --resume | --resume=* | --preview | --preview=*)
      return 0
      ;;
    --*) return 1 ;;
    # single-dash: any shorthand cluster touching -c -f -o -p (incl. attached
    # values such as -o/x or -cabc) is reserved.
    -*[cfop]*) return 0 ;;
  esac
  return 1
}
reserved_env() {
  case "$1" in
    HOME | PATH | TMPDIR | OCR_NO_UPDATE | OPENROUTER_API_KEY) return 0 ;;
  esac
  [ -n "${API_KEY_ENV:-}" ] && [ "$1" = "$API_KEY_ENV" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
[ "$#" -ge 3 ] || skip "usage: rc-ocr.sh <slot> <result-file> --worktree|--commit <rev>|--range <base> <head>"
valid_slot "$SLOT" || skip "invalid slot name"
[ -n "$RESULT" ] || skip "usage: empty result-file"
MODE="$3"
REV_A=""
REV_B=""
case "$MODE" in
  --worktree) [ "$#" -eq 3 ] || skip "usage: --worktree takes no revs" ;;
  --commit)
    [ "$#" -eq 4 ] || skip "usage: --commit <rev>"
    REV_A="$4"
    ;;
  --range)
    [ "$#" -eq 5 ] || skip "usage: --range <base-rev> <head-rev>"
    REV_A="$4"
    REV_B="$5"
    ;;
  *) skip "usage: unknown mode" ;;
esac

# ---------------------------------------------------------------------------
# Config (re-read here; the orchestrator passes no config values)
# ---------------------------------------------------------------------------
CONFIG_SH="${RC_CONFIG_SH:-$SCRIPT_DIR/rc-config.sh}"
CFG="$("$CONFIG_SH" "${RC_CONFIG_DIR:-.review-council}")" || CFG=""

# cfg <key>: value of the first exact "<key>=" line (split on the FIRST '=').
cfg() {
  _k="$1="
  _cfg_ifs=$IFS
  IFS=$NL
  for _l in $CFG; do
    case "$_l" in
      "$_k"*)
        IFS=$_cfg_ifs
        printf '%s' "${_l#"$_k"}"
        return 0
        ;;
    esac
  done
  IFS=$_cfg_ifs
  return 0
}

P="reviewer.custom.$SLOT"
HARNESS="$(cfg "$P.harness")"
[ -n "$HARNESS" ] || skip "slot '$SLOT' is not configured"
[ "$HARNESS" = ocr ] || skip "slot harness is '$(one_line "$HARNESS")', not ocr"

ROLE="$(cfg "$P.role")"
case "$ROLE" in signal | reviewer) ;; *) ROLE=signal ;; esac

MODEL="$(cfg "$P.model")"
if ! valid_modelslug "$MODEL"; then
  MODEL=""
  skip "invalid or empty model"
fi
FAMILY="$(rc_family "$MODEL")"
if rc_family_distinct "$FAMILY"; then DISTINCT=true; else DISTINCT=false; fi

ENABLED="$(cfg "$P.enabled")"
[ "$ENABLED" = false ] && skip "slot disabled"

PROVIDER="$(cfg "$P.provider")"
[ -n "$PROVIDER" ] || PROVIDER=openrouter
case "$PROVIDER" in
  openrouter | ollama) ;;
  *) skip "unsupported provider '$(one_line "$PROVIDER")'" ;;
esac

API_KEY_ENV=""
if [ "$PROVIDER" = openrouter ]; then
  API_KEY_ENV="$(cfg "$P.api_key_env")"
  [ -n "$API_KEY_ENV" ] || API_KEY_ENV=OPENROUTER_API_KEY
  valid_envname "$API_KEY_ENV" || skip "invalid api_key_env"
fi

EFFORT="$(cfg "$P.opt.effort")"
case "$EFFORT" in
  low) ROUNDS=1 ;;
  medium) ROUNDS=2 ;;
  high) ROUNDS=3 ;;
  *)
    [ -n "$EFFORT" ] && note "invalid effort '$(one_line "$EFFORT")'; using low"
    EFFORT=low
    ROUNDS=1
    ;;
esac

CONCURRENCY="$(cfg "$P.opt.concurrency")"
if [ -n "$CONCURRENCY" ]; then
  if ! is_uint "$CONCURRENCY" || [ "$CONCURRENCY" -lt 1 ] || [ "$CONCURRENCY" -gt 32 ]; then
    note "invalid concurrency; using ocr's default"
    CONCURRENCY=""
  fi
fi

TOKBUDGET="$(cfg "$P.opt.max_tokens_budget")"
if [ -n "$TOKBUDGET" ] && ! is_uint "$TOKBUDGET"; then
  note "invalid max_tokens_budget; using 0 (ocr default)"
  TOKBUDGET=0
fi
[ -n "$TOKBUDGET" ] || TOKBUDGET=0

TIMEOUT_MIN="$(cfg "$P.opt.timeout_minutes")"
if [ -n "$TIMEOUT_MIN" ]; then
  if ! is_uint "$TIMEOUT_MIN" || [ "$TIMEOUT_MIN" -lt 1 ]; then
    note "invalid timeout_minutes; deriving from run budget"
    TIMEOUT_MIN=""
  fi
fi

RUN_BUDGET="$(cfg settings.run_budget_seconds)"
if ! is_uint "$RUN_BUDGET" || [ "$RUN_BUDGET" -lt 1 ]; then RUN_BUDGET=600; fi

# Free-form trusted extras (the reader emits these only from trusted layers).
FLAGS=""
FLAGS_BAD=""
ENV_EXTRA=""
LLM_TIMEOUT_OVERRIDE=""
_old_ifs=$IFS
IFS=$NL
for _l in $CFG; do
  case "$_l" in
    "$P.flag."*)
      _tok="${_l#*=}"
      if ! valid_flag_token "$_tok"; then
        FLAGS_BAD="a flag token has invalid characters"
      elif reserved_flag "$_tok"; then
        FLAGS_BAD="'$_tok' is a reserved (isolation-critical) ocr flag"
      else
        FLAGS="$FLAGS$_tok$NL"
      fi
      ;;
    "$P.env."*)
      _kv="${_l#"$P.env."}"
      _name="${_kv%%=*}"
      _val="${_kv#*=}"
      if ! valid_envname "$_name"; then
        note "ignoring env extra with an invalid name"
      elif reserved_env "$_name"; then
        note "ignoring reserved env name '$_name'"
      elif [ "$(printf '%s' "$_val" | tr -d '\000-\037\177')" != "$_val" ]; then
        note "ignoring env extra '$_name' (control characters)"
      elif [ "$_name" = OCR_LLM_TIMEOUT ]; then
        LLM_TIMEOUT_OVERRIDE="$_val"
      else
        ENV_EXTRA="$ENV_EXTRA$_name=$_val$NL"
      fi
      ;;
  esac
done
IFS=$_old_ifs
# Fail closed, like the reader: a half-applied list could shift a value onto a
# flag, so one bad token drops the whole list.
if [ -n "$FLAGS_BAD" ]; then
  note "ignoring all harness flags: $FLAGS_BAD"
  FLAGS=""
fi

# ---------------------------------------------------------------------------
# Budget: ocr's --timeout is minutes and is multiplied by effort rounds
# (verified: internal/agent/agent.go — timeout × Template.ReviewRounds()).
# ---------------------------------------------------------------------------
RESERVE=$((RUN_BUDGET / 3))
if [ -n "$TIMEOUT_MIN" ]; then
  DEADLINE_MIN="$TIMEOUT_MIN"
else
  DEADLINE_MIN=$(((RUN_BUDGET - RESERVE) / 60))
  [ "$DEADLINE_MIN" -ge 1 ] || DEADLINE_MIN=1
fi
[ "$DEADLINE_MIN" -le 180 ] || DEADLINE_MIN=180
HARD_CAP_S=$((DEADLINE_MIN * 60 * ROUNDS + 90))
LLM_TIMEOUT_S=$((DEADLINE_MIN * 60))
[ "$LLM_TIMEOUT_S" -le 600 ] || LLM_TIMEOUT_S=600
if [ -n "$LLM_TIMEOUT_OVERRIDE" ]; then LLM_TIMEOUT_S="$LLM_TIMEOUT_OVERRIDE"; fi
note "budget deadline_min=$DEADLINE_MIN rounds=$ROUNDS hard_cap_s=$HARD_CAP_S llm_timeout_s=$LLM_TIMEOUT_S effort=$EFFORT"

# ---------------------------------------------------------------------------
# Binaries, key, target
# ---------------------------------------------------------------------------
JQ="$(command -v "${RC_JQ:-jq}" 2>/dev/null || true)"
[ -n "$JQ" ] || skip "jq not installed"
OCR="$(command -v "${RC_OCR_BIN:-ocr}" 2>/dev/null || true)"
[ -n "$OCR" ] || skip "ocr not installed"

KEY=""
if [ "$PROVIDER" = openrouter ]; then
  # printenv reads the value by NAME — no eval, value never in argv.
  KEY="$(printenv "$API_KEY_ENV" 2>/dev/null || true)"
  [ -n "$KEY" ] || skip "$API_KEY_ENV not set"
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || skip "not inside a git repository"

resolve_rev() {
  case "$1" in
    '' | -*) return 1 ;;
  esac
  git rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null
}
SHA_A=""
SHA_B=""
if [ -n "$REV_A" ]; then
  SHA_A="$(resolve_rev "$REV_A")" || SHA_A=""
  [ -n "$SHA_A" ] || skip "ref not found locally: $REV_A"
fi
if [ -n "$REV_B" ]; then
  SHA_B="$(resolve_rev "$REV_B")" || SHA_B=""
  [ -n "$SHA_B" ] || skip "ref not found locally: $REV_B"
fi

# Worktree mode: never use ocr's own workspace mode — it also reviews UNTRACKED
# files, so a stray non-ignored file (an .env, a local config) would be sent
# to the provider although the council's target is tracked changes only.
# Instead snapshot the tracked working tree (staged + unstaged) as a dangling
# commit with `git stash create` — it writes objects only, moves no ref and
# touches no file — and review HEAD..snapshot as a range.
if [ "$MODE" = "--worktree" ]; then
  SHA_A="$(resolve_rev HEAD)" || SHA_A=""
  [ -n "$SHA_A" ] || skip "no HEAD commit to diff the working tree against"
  SHA_B="$(GIT_AUTHOR_NAME=review-council GIT_AUTHOR_EMAIL=review-council@localhost \
    GIT_COMMITTER_NAME=review-council GIT_COMMITTER_EMAIL=review-council@localhost \
    git stash create 2>/dev/null)" || SHA_B=""
  [ -n "$SHA_B" ] || skip "no tracked changes in the working tree"
  MODE="--range"
fi

# ---------------------------------------------------------------------------
# Isolated HOME
# ---------------------------------------------------------------------------
T="$(mktemp -d "${TMPDIR:-/tmp}/rc-ocr.XXXXXX")" || T=""
[ -n "$T" ] && [ -d "$T" ] || skip "cannot create temp dir"
chmod 700 "$T"
mkdir -p "$T/.opencodereview" "$T/tmp" || skip "cannot populate temp dir"
RULE="$T/rule.json"
printf '%s' '{"rules":[{"path":"**","rule":"","merge_system_rule":true}],"exclude":["__none__"]}' >"$RULE"

if [ "$PROVIDER" = openrouter ]; then
  # Preset provider: no api_key here — ocr's env fallback reads
  # OPENROUTER_API_KEY, which only the run's env (via fd 3) carries.
  "$JQ" -n --arg m "$MODEL" '{provider:"openrouter", model:$m,
    providers:{openrouter:{url:"https://openrouter.ai/api/v1", model:$m,
      extra_body:{provider:{data_collection:"deny"}}}}}' \
    >"$T/.opencodereview/config.json" || skip "cannot write ocr config"
else
  # ollama is a custom provider in ocr (no preset, no env fallback): ocr
  # refuses one without an api_key, so a NON-SECRET placeholder is required.
  "$JQ" -n --arg m "$MODEL" '{provider:"ollama", model:$m,
    custom_providers:{ollama:{url:"http://127.0.0.1:11434/v1", protocol:"openai",
      api_key:"ollama", model:$m, models:[$m]}}}' \
    >"$T/.opencodereview/config.json" || skip "cannot write ocr config"
fi

# ---------------------------------------------------------------------------
# env -i allowlist. Everything ocr sees is listed here; nothing else leaks.
# ---------------------------------------------------------------------------
ENV_LIST="PATH=$PATH${NL}HOME=$T${NL}TMPDIR=$T/tmp${NL}OCR_NO_UPDATE=1${NL}OCR_LLM_TIMEOUT=$LLM_TIMEOUT_S$NL"
if [ -n "${LANG:-}" ]; then ENV_LIST="${ENV_LIST}LANG=$LANG$NL"; fi
if [ -n "${LC_ALL:-}" ]; then ENV_LIST="${ENV_LIST}LC_ALL=$LC_ALL$NL"; fi
ENV_LIST="$ENV_LIST$ENV_EXTRA"

# Target flags (SHAs only; worktree mode became a range above).
TARGET=""
case "$MODE" in
  --commit) TARGET="--commit$NL$SHA_A$NL" ;;
  --range) TARGET="--from$NL$SHA_A$NL--to$NL$SHA_B$NL" ;;
esac

# last_log_line <file>: ocr's own last diagnostic line, sanitised.
last_log_line() {
  [ -s "$1" ] || return 0
  one_line "$(grep -v '^[[:space:]]*$' "$1" | tail -n 1)" | cut -c1-200
}

# --- ocr version (no LLM call) ----------------------------------------------
IFS=$NL
# shellcheck disable=SC2086 # deliberate newline split of the allowlist
set -- $ENV_LIST
IFS=$_old_ifs
run_capped 30 "$T/version.log" env -i "$@" "$OCR" --version
_v="$(head -n 1 "$T/version.log" 2>/dev/null | awk '{print $2}')"
case "$_v" in
  v[0-9]*) OCR_VERSION="$(printf '%s' "$_v" | tr -cd 'A-Za-z0-9._+-' | cut -c1-40)" ;;
esac

# --- pre-flight 1: preview (no LLM call) ------------------------------------
IFS=$NL
# shellcheck disable=SC2086
set -- $ENV_LIST "$OCR" review --preview --format json --audience agent \
  --rule "$RULE" --repo "$ROOT" -o "$T/preview.json" $TARGET
IFS=$_old_ifs
run_capped 120 "$T/preview.log" env -i "$@"
if ! "$JQ" -e 'type=="object" and (.files|type)=="array"' "$T/preview.json" >/dev/null 2>&1; then
  skip "preview failed (exit $LAST_RC): $(last_log_line "$T/preview.log")"
fi
PV_TOTAL="$("$JQ" -r '(.total_files // (.files|length)) | tonumber? // 0' "$T/preview.json")"
PV_EXCL="$("$JQ" -r '(.excluded_count // ([.files[]|select(.will_review!=true)]|length)) | tonumber? // 0' "$T/preview.json")"
PV_PATH="$("$JQ" -r '[.files[] | select(.will_review==true) | .path
  | select(type=="string" and length > 0 and (explode | all(. >= 32 and . != 127)))][0] // empty' "$T/preview.json")"
is_uint "$PV_TOTAL" || PV_TOTAL=0
is_uint "$PV_EXCL" || PV_EXCL=0
[ -n "$PV_PATH" ] || skip "nothing to review ($PV_TOTAL changed, $PV_EXCL excluded by ocr)"

# --- pre-flight 2: rules must be pinned to the council's neutral file -------
IFS=$NL
# shellcheck disable=SC2086
set -- $ENV_LIST "$OCR" rules check --rule "$RULE" --repo "$ROOT" -- "$PV_PATH"
IFS=$_old_ifs
run_capped 60 "$T/rules.log" env -i "$@"
grep -Fqx 'Source: Custom (--rule)' "$T/rules.log" 2>/dev/null || skip "repo rules would apply"

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------
OUT="$T/out.json"
IFS=$NL
# shellcheck disable=SC2086
set -- $ENV_LIST
IFS=$_old_ifs
if [ "$PROVIDER" = openrouter ]; then
  # The key reaches ocr's environment through fd 3: run_capped closes stdin, so
  # it can't be stdin; fd 3 survives timeout/env and is closed before exec.
  # shellcheck disable=SC2016 # $K/$0/$@ expand in the inner sh, by design
  set -- "$@" /bin/sh -c 'IFS= read -r K <&3 || [ -n "$K" ]; exec 3<&-; OPENROUTER_API_KEY=$K; export OPENROUTER_API_KEY; K=; exec "$0" "$@"'
fi
IFS=$NL
# shellcheck disable=SC2086
set -- "$@" "$OCR" review --format json --audience agent -o "$OUT" \
  --rule "$RULE" --repo "$ROOT" --provider "$PROVIDER" --model "$MODEL" \
  --effort "$EFFORT" --timeout "$DEADLINE_MIN" $TARGET
IFS=$_old_ifs
[ -n "$CONCURRENCY" ] && set -- "$@" --concurrency "$CONCURRENCY"
[ "$TOKBUDGET" -gt 0 ] && set -- "$@" --max-tokens-budget "$TOKBUDGET"
IFS=$NL
# shellcheck disable=SC2086
set -- "$@" $FLAGS
IFS=$_old_ifs

if [ "$PROVIDER" = openrouter ]; then
  printf '%s\n' "$KEY" | {
    run_capped "$HARD_CAP_S" "$T/run.log" env -i "$@" 3<&0
    printf '%s\n' "$LAST_RC" >"$T/run.rc"
  }
  RUN_RC="$(cat "$T/run.rc" 2>/dev/null || echo 1)"
else
  run_capped "$HARD_CAP_S" "$T/run.log" env -i "$@"
  RUN_RC="$LAST_RC"
fi
KEY=""

# ---------------------------------------------------------------------------
# Post-run gates (parsed JSON, never the exit code)
# ---------------------------------------------------------------------------
if [ ! -s "$OUT" ]; then
  case "$RUN_RC" in
    124 | 137 | 143) skip "timeout (killed at the ${HARD_CAP_S}s hard cap; no output)" ;;
  esac
  skip "no output (exit $RUN_RC): $(last_log_line "$T/run.log")"
fi
"$JQ" -e 'type=="object"' "$OUT" >/dev/null 2>&1 || skip "invalid output (not JSON)"
_schema="$("$JQ" -r '.manifest.schema_version // "" | tostring' "$OUT")"
[ "$_schema" = "ocr.run-manifest/v1" ] || skip "invalid output (schema_version '$(one_line "$_schema" | cut -c1-60)')"
[ "$RUN_RC" = 0 ] || note "ocr exited $RUN_RC; using its JSON anyway"

_v="$("$JQ" -r '.manifest.execution.ocr_version // "" | tostring' "$OUT" | tr -cd 'A-Za-z0-9._+-' | cut -c1-40)"
[ -n "$_v" ] && OCR_VERSION="$_v"

_xp="$("$JQ" -r '.manifest.execution.provider // "" | tostring' "$OUT")"
_xm="$("$JQ" -r '.manifest.execution.model // "" | tostring' "$OUT")"
if [ "$_xp" != "$PROVIDER" ] || [ "$_xm" != "$MODEL" ]; then
  note "ocr ran provider/model '$(one_line "$_xp")/$(one_line "$_xm")', not the configured '$PROVIDER/$MODEL' — family set to unknown"
  FAMILY=unknown
  DISTINCT=false
fi

# --- stats (numbers + sanitised one-line strings only) -----------------------
JQ_LIB='
def arr: if type == "array" then . else [] end;
def clean: tostring | explode
  | map(select(. == 9 or . == 10 or (. >= 32 and . != 127 and (. < 128 or . > 159)
               and (. < 8234 or . > 8238) and (. < 8294 or . > 8297))))
  | implode;
def oneline: clean | gsub("[\\n\\t]+"; " ");
def sel: [(.manifest.coverage.selected | arr)[] | .path | select(type == "string")];
def kept: sel as $s | [(.comments | arr)[] | select(type == "object")
  | select((.path | type) == "string" and (.path as $p | any($s[]; . == $p)))];
def sev: (.severity // "") | (if type == "string" then ascii_downcase else "" end)
  | if . == "critical" then "critical" elif . == "high" then "important" else "suggestion" end;
'
STATS="$("$JQ" -r "$JQ_LIB"'
  (.manifest.coverage // {}) as $c
  | ($c.failed | arr) as $f
  | "selected=\(sel | length)",
    "covered=\((($c.completed | arr) | length) + (($c.reused | arr) | length))",
    "failed=\($f | length)",
    "failed_by=\($f | map(.classification // "unknown" | oneline) | group_by(.)
       | map("\(.[0]) (\(length))") | join(", "))",
    "terminal=\(.manifest.terminal_state // "" | oneline)",
    "warnings=\(.warnings | arr | length)",
    "total=\(.comments | arr | length)",
    "kept=\(kept | length)",
    "n_crit=\(kept | map(select(sev == "critical")) | length)",
    "n_imp=\(kept | map(select(sev == "important")) | length)",
    "n_sug=\(kept | map(select(sev == "suggestion")) | length)",
    "message=\(.message // "" | oneline | .[0:200])"
' "$OUT" 2>/dev/null)" || skip "invalid output (unreadable structure)"

get_stat() {
  _k="$1="
  _old_ifs2=$IFS
  IFS=$NL
  for _l in $STATS; do
    case "$_l" in "$_k"*)
      IFS=$_old_ifs2
      printf '%s' "${_l#"$_k"}"
      return 0
      ;;
    esac
  done
  IFS=$_old_ifs2
}
S_SEL="$(get_stat selected)"
S_DONE="$(get_stat covered)"
S_FAILED="$(get_stat failed)"
S_FAILED_BY="$(get_stat failed_by)"
S_TERM="$(get_stat terminal)"
S_WARN="$(get_stat warnings)"
S_TOTAL="$(get_stat total)"
S_KEPT="$(get_stat kept)"
S_MSG="$(get_stat message)"
N_FINDINGS="$S_KEPT"
N_DROPPED=$((S_TOTAL - S_KEPT))

_failed_txt="$S_FAILED failed"
[ "$S_FAILED" -gt 0 ] && _failed_txt="$_failed_txt: $S_FAILED_BY"
_drop_txt="$N_DROPPED comments dropped (path not reviewed)"
[ "$N_DROPPED" -eq 1 ] && _drop_txt="1 comment dropped (path not reviewed)"
COVERAGE="ocr ${OCR_VERSION:-unknown-version} · $SLOT ($MODEL): reviewed $S_DONE/$S_SEL selected files · $_failed_txt · $PV_EXCL of $PV_TOTAL changed files excluded before review · $_drop_txt · $S_WARN warnings"

if [ "$S_FAILED" -eq 0 ] && [ "$S_TERM" = complete ]; then
  STATUS=complete
elif [ "$S_DONE" -gt 0 ]; then
  STATUS=partial
else
  _why="${S_MSG:-nothing reviewed}"
  [ "$S_FAILED" -gt 0 ] && _why="$_why (failed: $S_FAILED_BY)"
  skip "$_why"
fi

# ---------------------------------------------------------------------------
# Render §3.1 markdown (deterministic; ocr text only ever appears as fenced data)
# ---------------------------------------------------------------------------
MD="$T/findings.md"
"$JQ" -r --arg slot "$SLOT" --arg model "$MODEL" --arg coverage "$COVERAGE" \
  --arg status "$STATUS" "$JQ_LIB"'
def fence: clean as $t
  | ([($t | match("`+"; "g") | .length)] | max // 0) as $n
  | ("`" * (if $n + 1 < 3 then 3 else $n + 1 end)) as $f
  | $f + "\n" + $t + (if ($t | endswith("\n")) then "" else "\n" end) + $f;
def int0: if type == "number" then floor else (tonumber? // 0) end | if . < 0 then 0 else . end;
# split_issue: [first sentence (or first line), the rest] of cleaned text.
def split_issue: sub("^\\s+"; "")
  | (if test("[.!?](?=\\s|$)|\\n")
     then (match("[.!?](?=\\s|$)|\\n") | if .string == "\\n" then .offset else .offset + 1 end)
     else length end) as $i
  | [(.[0:$i] | oneline), (.[$i:] | sub("^\\s+"; ""))];
def finding($i):
  (.path | oneline) as $p
  | (.start_line | int0) as $s
  | ((.end_line | int0) | if . < $s then $s else . end) as $e
  | (.content // "" | clean) as $c
  | ($c | split_issue) as [$fs, $tail]
  | (if ($fs | length) > 200 then ($fs[0:199] + "…") else $fs end) as $issue
  | (if ($fs | length) > 200 then $c else $tail end) as $rest
  | (.category // "other" | tostring | ascii_downcase | gsub("[^a-z0-9-]+"; "-")
     | gsub("^-+|-+$"; "") | if . == "" then "other" else . end) as $cat
  | (.existing_code // "" | clean | split("\n") | .[0:30] | join("\n") | .[0:2000]) as $code
  | "#### ocr finding \($i)",
    "- `severity`: \(sev)",
    "- `confidence`: low",
    "- `location`: \($p):\($s)",
    "- `symbol`: \(if $s == 0 then "file-level" else "L\($s)-L\($e)" end)",
    "- `concern`: ocr-\($cat)",
    "- `issue`: \(if $issue == "" then "ocr gave no description." else $issue end)",
    (if ($rest | length) > 0
       then "- `why_it_matters`: ocr\u0027s own text, quoted as untrusted data:\n\n" + ($rest | fence) + "\n"
       else "- `why_it_matters`: No further detail from ocr — see issue." end),
    (if ((.suggestion_code // "") | tostring | length) > 0
       then "- `recommendation`: ocr\u0027s proposed code, quoted as untrusted data:\n\n" + (.suggestion_code | fence) + "\n"
       else "- `recommendation`: No fix proposed by ocr — see issue." end),
    (if $s == 0
       then "- `how_to_verify`: Open \($p) (file-level comment) and check the claim in issue against the file."
       else "- `how_to_verify`: Open \($p) lines \($s)–\($e) and check the claim in issue against the code." end
     + (if ($code | length) > 0 then " The code ocr quoted (untrusted data):\n\n" + ($code | fence) + "\n" else "" end)),
    "- `source`: \($slot)",
    "";
kept as $k
| "### Findings", "",
  (if ($k | length) == 0 then "No issues found", ""
   else range(0; $k | length) as $i | $k[$i] | finding($i + 1) end),
  "### What\u0027s Good", "",
  "N/A — ocr does not report positives.", "",
  "### Overall Assessment", "",
  "ocr (\($model)) reported \($k | length) finding(s) — \($k | map(select(sev == "critical")) | length) critical, \($k | map(select(sev == "important")) | length) important, \($k | map(select(sev == "suggestion")) | length) suggestion — with status \($status). Coverage: \($coverage). ocr findings are unverified single-model output (confidence low); a file ocr did not review is not a file the council calls clean."
' "$OUT" >"$MD" 2>"$T/render.err" || skip "invalid output (render failed: $(last_log_line "$T/render.err"))"

succeed "$STATUS" "$MD"
