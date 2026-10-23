#!/usr/bin/env sh
# rc-seat.sh — dispatch for a custom reviewer seat run through an agent CLI
# harness: `codex`, `claude` (Claude Code) or `opencode`, against an
# `openrouter` or a local `ollama` provider. Sibling of
# rc-ocr.sh (which owns the `ocr` harness) and built to the same discipline.
#
# Usage (the orchestrator passes ONLY these atoms — never free-form text):
#   rc-seat.sh <slot> <result-file> [--confirmed] <prompt-file>
#
# <prompt-file> holds the full review prompt (lens + review instructions +
# context package) the orchestrator wrote — typically 200–300 KB, more than
# Linux allows in ONE argv element (MAX_ARG_STRLEN, 128 KB). So the prompt
# never travels on argv: it is copied into the private dir and fed to codex /
# claude on STDIN (both read the prompt from stdin when no positional prompt is
# given); opencode ignores stdin, so it gets the copy as an attached file in
# its cwd plus a fixed short message telling it to read that file in full.
# Missing, empty (whitespace only) or larger than 4 MB → SKIPPED.
# --confirmed records the operator's yes for a seat the reader marks
# `needs_confirm=true`; without it such a seat is SKIPPED before any harness
# binary is invoked.
#
# The script re-reads the council config itself (`rc-config.sh`, overridable via
# RC_CONFIG_SH; config dir ${RC_CONFIG_DIR:-.review-council}) and uses only the
# validated `reviewer.custom.<slot>.*` keys plus `settings.reviewer_timeout_seconds`
# and `settings.claude_max_turns`.
#
# Output:
#   <result-file>       (also teed to stdout) — "TOOL: <slot> (<model> via
#                       <harness>)" + the model's final answer (§3.1 markdown),
#                       control and bidi/C1 characters stripped; OR one line
#                       "SKIPPED: <slot> (<harness>) unavailable — <harness>: <reason>".
#   <result-file>.meta  key=value routing data written by THIS script, never
#                       derived from model text: status harness family distinct
#                       role model_check findings [reason].
#   stderr              free-form notes + exactly one "ELAPSED: <seconds>".
#   exit                always 0 — the seat degrades, it never blocks a review;
#                       an INT/TERM/HUP ends it as SKIPPED "interrupted" (the
#                       same three outputs) once the running child returns.
#
# Isolation:
#   - every harness runs under `env -i` with an allowlist (PATH, a throwaway
#     HOME, TMPDIR, LANG/LC_ALL, plus the harness's own vars) — host
#     ANTHROPIC_* / OPENAI_* / OPENROUTER_* never reach it;
#   - the harness's config home is a fresh private dir (CODEX_HOME,
#     CLAUDE_CONFIG_DIR, XDG_* + a council-written OPENCODE_CONFIG), so a
#     reviewed repo's own harness config / plugins cannot widen its tools;
#   - the tool surface is read-only by construction: codex `--sandbox
#     read-only`; claude `--tools=Read,Grep,Glob`; opencode deny-by-default
#     permissions + OPENCODE_DISABLE_PROJECT_CONFIG=1 + `--pure`;
#   - the harness's cwd is $T/repo, a `git stash create` + `git archive`
#     snapshot of the TRACKED working state — untracked and gitignored files
#     (an .env) are not in it; the live checkout is never the cwd;
#   - ollama: the model must already be in the local /api/tags list (no
#     harness ever pulls a repo-chosen model);
#   - claude: background / alias models are pinned to the configured model;
#   - an OpenRouter key travels on a pipe (fd 3), never argv, never disk;
#   - the prompt the harness reads is a user-only (0600) COPY inside the
#     private dir, never the orchestrator's file;
#   - the private dir (rc-seat-priv.XXXXXX) is removed on exit by a trap.
#
# POSIX sh; no eval. The family map is sourced from rc-lib-family.sh and the
# hard-timeout watchdog (run_capped) from rc-lib-timeout.sh.

# SC2016: the jq programs and the fd-3 shims below are single-quoted ON
# PURPOSE — $vars in them are jq variables / inner-shell expansions.
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
# opencode's project-config guard (OPENCODE_DISABLE_PROJECT_CONFIG) is
# undocumented; it was verified on this version, so anything older is skipped.
OPENCODE_MIN_VERSION=1.19.0
# Sanity cap only: the prompt goes on stdin / an attached file, not argv, so no
# OS argument limit applies; a prompt beyond this is a runaway context package.
PROMPT_MAX_BYTES=4194304
# opencode: the in-snapshot name of the prompt copy, and the fixed (never
# config- or prompt-derived) message that points the model at it. `opencode
# run -f` inlines the attachment TRUNCATED, so the model must read it in full.
OPENCODE_PROMPT_NAME=.review-council-prompt.md
OPENCODE_MSG="Your complete task and the full review context are in the attached file $OPENCODE_PROMPT_NAME. The attachment may be truncated, so read the WHOLE file with the read tool (in chunks, using offsets) before answering. Then follow its instructions exactly and answer in the format it specifies."
# OpenRouter: opt out of providers that train on / retain prompts (claude).
OR_EXTRA_BODY='{"provider":{"data_collection":"deny"}}'

# --- state used by finish() (all defaults safe for an early SKIPPED) ---------
SLOT="${1:-}"
RESULT="${2:-}"
T=""
HARNESS=""
ROLE="signal"
FAMILY="unknown"
DISTINCT="false"
MODEL=""
MODEL_CHECK="argv"
N_FINDINGS=0
CONFIRMED=false
FINISHING="" # set by skip/succeed: a terminal path is writing the outputs

note() { printf 'rc-seat: %s\n' "$*" >&2; }

# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  if [ -n "$T" ] && [ -d "$T" ]; then
    # opencode/codex may leave read-only dirs (e.g. caches) behind.
    chmod -R u+rwx "$T" 2>/dev/null
    rm -rf "$T"
  fi
}
trap cleanup EXIT

# on_signal: INT/TERM/HUP end the seat like any other failure — the normal
# SKIPPED outputs (result, .meta, ELAPSED), then exit 0 via skip, whose exit
# runs the EXIT trap (cleanup). Further signals are ignored from here on, so
# the handler can't recurse or run twice; if skip/succeed is already writing
# the outputs, it is left to finish (and exit) rather than double-written.
# NB: sh runs a trap only after the current FOREGROUND child returns, so a
# signal to this script alone may take effect only once the harness call ends
# (the run itself stays bounded by run_capped's hard cap).
# shellcheck disable=SC2329 # invoked via trap
on_signal() {
  trap '' INT TERM HUP
  [ -n "$FINISHING" ] && return 0
  skip "interrupted"
}
trap on_signal INT TERM HUP

# flat <text>: strip control chars, newline/tab -> space (no length cap).
flat() {
  printf '%s' "$1" | tr -d '\000-\010\013-\037\177' | tr '\n\t' '  '
}
# one_line <text>: flat + cap at 300 bytes (for reasons that may carry tool text).
one_line() {
  flat "$1" | cut -c1-300
}

# label used in SKIPPED/TOOL lines: the slot only when it passed validation.
slot_label() {
  if valid_slot "$SLOT"; then printf '%s' "$SLOT"; else printf 'custom'; fi
}
# harness label: only a known harness name, never raw config text.
harness_label() {
  case "$HARNESS" in
    codex | claude | opencode | ocr) printf '%s' "$HARNESS" ;;
    *) printf 'seat' ;;
  esac
}

write_meta() {
  # $1=status $2=reason
  [ -n "$RESULT" ] || return 0
  {
    printf 'status=%s\n' "$1"
    printf 'harness=%s\n' "$(harness_label)"
    printf 'family=%s\n' "$FAMILY"
    printf 'distinct=%s\n' "$DISTINCT"
    printf 'role=%s\n' "$ROLE"
    printf 'model_check=%s\n' "$MODEL_CHECK"
    printf 'findings=%s\n' "$N_FINDINGS"
    if [ "$1" = skipped ]; then printf 'reason=%s\n' "$(one_line "$2")"; fi
  } >"$RESULT.meta" 2>/dev/null || note "cannot write $RESULT.meta"
}

emit_elapsed() {
  _now="$(date +%s)"
  printf 'ELAPSED: %s\n' "$((_now - START_TS))" >&2
}

# skip <reason>: the single SKIPPED exit path.
skip() {
  FINISHING=1
  _reason="$(one_line "$1")"
  _hl="$(harness_label)"
  _line="SKIPPED: $(slot_label) ($_hl) unavailable — $_hl: $_reason"
  N_FINDINGS=0
  printf '%s\n' "$_line"
  if [ -n "$RESULT" ]; then
    printf '%s\n' "$_line" >"$RESULT" 2>/dev/null || note "cannot write $RESULT"
  fi
  write_meta skipped "$_reason"
  emit_elapsed
  exit 0
}

# succeed <markdown-file>: the single success exit path.
succeed() {
  FINISHING=1
  _hdr="TOOL: $SLOT ($MODEL via $HARNESS)"
  if [ -n "$RESULT" ]; then
    { printf '%s\n' "$_hdr"; cat "$1"; } >"$RESULT" 2>/dev/null ||
      note "cannot write $RESULT"
  fi
  printf '%s\n' "$_hdr"
  cat "$1"
  write_meta complete ""
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

# version_ge <v> <min>: is dotted-numeric version <v> >= <min>? Each part is
# compared as a number (missing parts count as 0). Anything that is not a
# plain dotted-numeric version (empty, a prefix/suffix, an empty part) is
# unparseable and returns false — treated as below the minimum.
version_ge() {
  case "$1" in
    '' | .* | *. | *..* | *[!0-9.]*) return 1 ;;
  esac
  _vg_a="$1."
  _vg_b="$2."
  while [ -n "$_vg_a" ] || [ -n "$_vg_b" ]; do
    _vg_x="${_vg_a%%.*}"
    _vg_y="${_vg_b%%.*}"
    _vg_a="${_vg_a#*.}"
    _vg_b="${_vg_b#*.}"
    # strip leading zeros so the numbers never read as octal / overflow
    _vg_x="$(printf '%s' "${_vg_x:-0}" | sed 's/^0*//')"
    _vg_y="$(printf '%s' "${_vg_y:-0}" | sed 's/^0*//')"
    [ "${#_vg_x}" -le 9 ] || return 1
    [ "${_vg_x:-0}" -gt "${_vg_y:-0}" ] && return 0
    [ "${_vg_x:-0}" -lt "${_vg_y:-0}" ] && return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
USAGE="usage: rc-seat.sh <slot> <result-file> [--confirmed] <prompt-file>"
if [ "$#" -ge 3 ] && [ "$3" = --confirmed ]; then
  CONFIRMED=true
  shift 3
  set -- "$SLOT" "$RESULT" "$@"
fi
[ "$#" -eq 3 ] || skip "$USAGE"
valid_slot "$SLOT" || skip "invalid slot name"
[ -n "$RESULT" ] || skip "usage: empty result-file"
PROMPT_FILE="$3"
[ -n "$PROMPT_FILE" ] || skip "usage: empty prompt-file"

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
_h="$(cfg "$P.harness")"
[ -n "$_h" ] || skip "slot '$SLOT' is not configured"
case "$_h" in
  codex | claude | opencode) HARNESS="$_h" ;;
  ocr)
    HARNESS=ocr
    skip "harness ocr is dispatched by rc-ocr.sh"
    ;;
  *) skip "unsupported harness '$(one_line "$_h" | cut -c1-40)'" ;;
esac
# claude reports the model it actually ran (JSON .modelUsage); codex and
# opencode do not, so their model is only what we put on argv.
if [ "$HARNESS" = claude ]; then MODEL_CHECK=reported; fi

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

# Script-side confirm lock: a seat the reader marks needs_confirm=true (e.g. a
# committed-only, non-ollama seat) runs only with the operator's --confirmed.
# Checked before any harness binary is resolved or run (opencode's --version
# probe included), so an unconfirmed seat never egresses. An absent key (an
# older reader) means false.
if [ "$(cfg "$P.needs_confirm")" = true ] && [ "$CONFIRMED" != true ]; then
  skip "not confirmed by the operator"
fi

PROVIDER="$(cfg "$P.provider")"
[ -n "$PROVIDER" ] || PROVIDER=openrouter
case "$PROVIDER" in
  openrouter | ollama) ;;
  *) skip "unsupported provider '$(one_line "$PROVIDER" | cut -c1-40)'" ;;
esac

API_KEY_ENV=""
if [ "$PROVIDER" = openrouter ]; then
  API_KEY_ENV="$(cfg "$P.api_key_env")"
  [ -n "$API_KEY_ENV" ] || API_KEY_ENV=OPENROUTER_API_KEY
  valid_envname "$API_KEY_ENV" || skip "invalid api_key_env"
fi

# Hard cap (seconds): opt.timeout_minutes × 60, else 20 minutes for a local
# (ollama) seat — local models are slow — else the shared reviewer timeout.
CAP=""
TIMEOUT_MIN="$(cfg "$P.opt.timeout_minutes")"
if [ -n "$TIMEOUT_MIN" ]; then
  if is_uint "$TIMEOUT_MIN" && [ "$TIMEOUT_MIN" -ge 1 ]; then
    CAP=$((TIMEOUT_MIN * 60))
  else
    if [ "$PROVIDER" = ollama ]; then
      note "invalid timeout_minutes; using the 20-minute local default"
    else
      note "invalid timeout_minutes; using settings.reviewer_timeout_seconds"
    fi
  fi
fi
if [ -z "$CAP" ] && [ "$PROVIDER" = ollama ]; then
  CAP=1200
fi
if [ -z "$CAP" ]; then
  CAP="$(cfg settings.reviewer_timeout_seconds)"
  if ! is_uint "$CAP" || [ "$CAP" -lt 1 ]; then CAP=600; fi
fi

MAX_TURNS=""
if [ "$HARNESS" = claude ]; then
  MAX_TURNS="$(cfg "$P.opt.max_turns")"
  if ! is_uint "$MAX_TURNS" || [ "$MAX_TURNS" -lt 1 ]; then
    MAX_TURNS="$(cfg settings.claude_max_turns)"
    if ! is_uint "$MAX_TURNS" || [ "$MAX_TURNS" -lt 1 ]; then MAX_TURNS=30; fi
  fi
fi
note "harness=$HARNESS provider=$PROVIDER cap_s=$CAP${MAX_TURNS:+ max_turns=$MAX_TURNS}"

# ---------------------------------------------------------------------------
# Prompt (checked here; copied into the private dir below — never on argv)
# ---------------------------------------------------------------------------
[ -f "$PROMPT_FILE" ] && [ -r "$PROMPT_FILE" ] || skip "prompt file missing or unreadable"
_psize="$(wc -c <"$PROMPT_FILE" 2>/dev/null | tr -d ' ')"
is_uint "$_psize" || skip "cannot size the prompt file"
[ "$_psize" -gt 0 ] || skip "empty prompt"
[ "$_psize" -le "$PROMPT_MAX_BYTES" ] || skip "prompt too large (> 4 MB)"
[ -n "$(tr -d ' \t\r\n' <"$PROMPT_FILE" | head -c 1)" ] || skip "empty prompt"

# ---------------------------------------------------------------------------
# Binaries, key, target
# ---------------------------------------------------------------------------
JQ="$(command -v "${RC_JQ:-jq}" 2>/dev/null || true)"
[ -n "$JQ" ] || skip "jq not installed"
case "$HARNESS" in
  codex) _bin="${RC_CODEX_BIN:-codex}" ;;
  claude) _bin="${RC_CLAUDE_BIN:-claude}" ;;
  opencode) _bin="${RC_OPENCODE_BIN:-opencode}" ;;
esac
BIN="$(command -v "$_bin" 2>/dev/null || true)"
[ -n "$BIN" ] || skip "$HARNESS not installed"

KEY=""
if [ "$PROVIDER" = openrouter ]; then
  # printenv reads the value by NAME — no eval, value never in argv.
  KEY="$(printenv "$API_KEY_ENV" 2>/dev/null || true)"
  [ -n "$KEY" ] || skip "$API_KEY_ENV not set"
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || skip "not inside a git repository"

# --- ollama: the model must already be pulled --------------------------------
# `codex --oss` (and Ollama on first use) PULLS a missing model, so a
# repo-chosen slug could make the operator's Ollama download an arbitrary
# model — possibly from a registry host named in the slug. Require an exact
# name in the local /api/tags list (an untagged slug also matches
# <slug>:latest, Ollama's own normalisation) before any harness binary runs.
# RC_OLLAMA_TAGS_URL is a test hook (operator env, never config).
if [ "$PROVIDER" = ollama ]; then
  CURL="$(command -v curl 2>/dev/null || true)"
  [ -n "$CURL" ] || skip "curl not installed (needed to check the Ollama model)"
  _tags="$("$CURL" -q -fsS --noproxy '*' --max-time 5 \
    "${RC_OLLAMA_TAGS_URL:-http://127.0.0.1:11434/api/tags}" 2>/dev/null)" ||
    skip "ollama not reachable"
  _have="$(printf '%s' "$_tags" | "$JQ" -r --arg m "$MODEL" '
    [(.models // [])[] | .name? | strings] as $n
    | ($m | split("/") | last | contains(":") | not) as $untagged
    | any($n[]; . == $m or ($untagged and . == $m + ":latest"))' 2>/dev/null)" ||
    skip "ollama not reachable"
  case "$_have" in
    true) ;;
    false) skip "model not pulled in Ollama: $MODEL (run: ollama pull $MODEL)" ;;
    *) skip "ollama not reachable" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Private dir: throwaway HOME / TMPDIR / harness config home. The prefix is
# rc-seat-priv.*, never an orchestrator result-dir prefix.
# ---------------------------------------------------------------------------
T="$(mktemp -d "${TMPDIR:-/tmp}/rc-seat-priv.XXXXXX")" || T=""
[ -n "$T" ] && [ -d "$T" ] || skip "cannot create temp dir"
chmod 700 "$T"
mkdir -p "$T/home" "$T/tmp" "$T/repo" || skip "cannot populate temp dir"

# The harness reads a user-only COPY of the prompt (never the orchestrator's
# path). The size must match: a short copy would silently truncate the review.
PROMPT_COPY="$T/prompt.md"
(umask 077 && cat "$PROMPT_FILE" >"$PROMPT_COPY") 2>/dev/null || skip "cannot read the prompt file"
chmod 600 "$PROMPT_COPY"
[ "$(wc -c <"$PROMPT_COPY" | tr -d ' ')" = "$_psize" ] || skip "cannot read the prompt file"

# ---------------------------------------------------------------------------
# Snapshot: the harness's cwd is $T/repo, a copy of the TRACKED working state
# (staged + unstaged edits to tracked files), never the live checkout — so an
# untracked .env or a gitignored file is simply not there to be read. `git
# stash create` makes a dangling commit (no ref, no stash entry, no working
# tree change); empty output = no tracked changes → HEAD. It refreshes a
# private COPY of the index (GIT_INDEX_FILE), never the live one: two seats
# snapshotting one repo at once raced on index.lock, and the loser exited 1
# with no stderr at all. `git archive` is run from the top level (from a
# subdir it would archive only that subdir), to a file so its exit status is
# not hidden behind tar's. No .git in the copy.
# ---------------------------------------------------------------------------
# snap_fail <what> <stderr-file> <exit>: SKIPPED with git's own last stderr
# line, or "<what> failed (exit <n>)" when it wrote none.
snap_fail() {
  _why=""
  [ -s "$2" ] && _why="$(one_line "$(grep -v '^[[:space:]]*$' "$2" | tail -n 1)" | cut -c1-200)"
  skip "could not snapshot the repo: ${_why:-$1 failed (exit $3)}"
}
git -C "$ROOT" rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1 ||
  skip "could not snapshot the repo: no HEAD commit"
_idx="$(git -C "$ROOT" rev-parse --path-format=absolute --git-path index 2>/dev/null)" || _idx=""
{ [ -n "$_idx" ] && cp "$_idx" "$T/index" 2>/dev/null; } ||
  skip "could not snapshot the repo: cannot copy the git index"
SNAP="$(GIT_AUTHOR_NAME=review-council GIT_AUTHOR_EMAIL=review-council@localhost \
  GIT_COMMITTER_NAME=review-council GIT_COMMITTER_EMAIL=review-council@localhost \
  GIT_INDEX_FILE="$T/index" git -C "$ROOT" stash create 2>"$T/snap.err")" ||
  snap_fail "git stash create" "$T/snap.err" $?
[ -n "$SNAP" ] || SNAP=HEAD
git -C "$ROOT" archive --format=tar "$SNAP" >"$T/snap.tar" 2>"$T/snap.err" ||
  snap_fail "git archive" "$T/snap.err" $?
tar -xf "$T/snap.tar" -C "$T/repo" 2>"$T/snap.err" || snap_fail "tar" "$T/snap.err" $?
rm -f "$T/snap.tar" "$T/snap.err" "$T/index"

# opencode: its read tool is confined to its cwd (external_directory: deny), so
# the prompt copy goes INTO the snapshot. Whatever the repo tracks under that
# name (even a symlink pointing out of the snapshot) is removed first, and the
# copy is created with noclobber, so the write can never follow a link.
if [ "$HARNESS" = opencode ]; then
  _ocp="$T/repo/$OPENCODE_PROMPT_NAME"
  rm -rf "$_ocp" 2>/dev/null
  (set -C && umask 077 && cat "$PROMPT_COPY" >"$_ocp") 2>/dev/null ||
    skip "cannot place the prompt in the snapshot"
fi

# ---------------------------------------------------------------------------
# env -i allowlist. Everything the harness sees is listed here; nothing else
# leaks. Values are host paths / fixed literals (no newline), so the list is
# split on newlines; every argv element is appended explicitly below.
# ---------------------------------------------------------------------------
ENV_LIST="PATH=$PATH${NL}HOME=$T/home${NL}TMPDIR=$T/tmp$NL"
if [ -n "${LANG:-}" ]; then ENV_LIST="${ENV_LIST}LANG=$LANG$NL"; fi
if [ -n "${LC_ALL:-}" ]; then ENV_LIST="${ENV_LIST}LC_ALL=$LC_ALL$NL"; fi

case "$HARNESS" in
  codex)
    mkdir -p "$T/codex" || skip "cannot populate temp dir"
    ENV_LIST="${ENV_LIST}CODEX_HOME=$T/codex$NL"
    ;;
  claude)
    mkdir -p "$T/claude" || skip "cannot populate temp dir"
    ENV_LIST="${ENV_LIST}CLAUDE_CONFIG_DIR=$T/claude$NL"
    if [ "$PROVIDER" = ollama ]; then
      # A NON-SECRET placeholder: Ollama ignores the token but Claude Code
      # refuses to start without one.
      ENV_LIST="${ENV_LIST}ANTHROPIC_BASE_URL=http://127.0.0.1:11434${NL}ANTHROPIC_AUTH_TOKEN=ollama$NL"
    else
      # ANTHROPIC_AUTH_TOKEN (the key) arrives via fd 3; CLAUDE_CODE_EXTRA_BODY
      # (hard-coded, never config-derived) is appended at the run below.
      ENV_LIST="${ENV_LIST}ANTHROPIC_BASE_URL=https://openrouter.ai/api$NL"
    fi
    ENV_LIST="${ENV_LIST}ANTHROPIC_API_KEY=${NL}CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1${NL}DISABLE_TELEMETRY=1$NL"
    # Claude Code's background "small/fast" calls and model aliases default to
    # Claude models — via OpenRouter that would silently send the code to
    # Anthropic. Pin every one to the configured (validated) model.
    ENV_LIST="${ENV_LIST}ANTHROPIC_SMALL_FAST_MODEL=$MODEL${NL}ANTHROPIC_DEFAULT_HAIKU_MODEL=$MODEL$NL"
    ENV_LIST="${ENV_LIST}ANTHROPIC_DEFAULT_SONNET_MODEL=$MODEL${NL}ANTHROPIC_DEFAULT_OPUS_MODEL=$MODEL$NL"
    ;;
  opencode)
    mkdir -p "$T/xdg/config" "$T/xdg/data" "$T/xdg/cache" "$T/xdg/state" ||
      skip "cannot populate temp dir"
    # OPENCODE_DISABLE_PROJECT_CONFIG=1 is THE boundary: without it a repo
    # opencode.json can grant write+bash and a repo plugin runs JavaScript.
    ENV_LIST="${ENV_LIST}XDG_CONFIG_HOME=$T/xdg/config${NL}XDG_DATA_HOME=$T/xdg/data${NL}XDG_CACHE_HOME=$T/xdg/cache${NL}XDG_STATE_HOME=$T/xdg/state$NL"
    ENV_LIST="${ENV_LIST}OPENCODE_CONFIG=$T/opencode.json${NL}OPENCODE_DISABLE_PROJECT_CONFIG=1$NL"
    ;;
esac

# --- opencode: minimum version + council-written config --------------------------
if [ "$HARNESS" = opencode ]; then
  _old_ifs=$IFS
  IFS=$NL
  # shellcheck disable=SC2086 # deliberate newline split of the allowlist
  set -- $ENV_LIST
  IFS=$_old_ifs
  # cwd = the private dir: before the version is known to be a tested one,
  # opencode must not see the reviewed repo (its config / plugins).
  (
    cd "$T" || exit 0
    run_capped 30 "$T/version.log" env -i "$@" "$BIN" --version 3<&-
  )
  _v="$(grep -v '^[[:space:]]*$' "$T/version.log" 2>/dev/null | head -n 1 | tr -d ' \r')"
  if ! version_ge "$_v" "$OPENCODE_MIN_VERSION"; then
    _vs="$(printf '%s' "$_v" | tr -cd 'A-Za-z0-9._+-' | cut -c1-40)"
    skip "opencode ${_vs:-unknown} is older than the minimum tested version $OPENCODE_MIN_VERSION"
  fi

  # The model is a jq --arg, never string-concatenated into JSON. Permissions
  # are deny-by-default; only the four read-only tools are allowed.
  if [ "$PROVIDER" = ollama ]; then
    _prov='{ollama:{npm:"@ai-sdk/openai-compatible", name:"Ollama",
      options:{baseURL:"http://127.0.0.1:11434/v1"}, models:{($m):{}}}}'
  else
    # opencode's built-in openrouter provider reads OPENROUTER_API_KEY (fd 3).
    _prov='{openrouter:{models:{($m):{options:{provider:{data_collection:"deny"}}}}}}'
  fi
  "$JQ" -n --arg p "$PROVIDER" --arg m "$MODEL" '{
    "$schema":"https://opencode.ai/config.json", autoupdate:false,
    share:"disabled", enabled_providers:[$p],
    model:($p + "/" + $m), small_model:($p + "/" + $m),
    permission:{"*":"deny", read:"allow", grep:"allow", glob:"allow",
      list:"allow", external_directory:"deny"},
    provider:'"$_prov"'}' >"$T/opencode.json" || skip "cannot write opencode config"
fi

# ---------------------------------------------------------------------------
# The run. argv: env -i <allowlist> /bin/sh -c <shim> <stdout-file>
# <stdin-file> <harness argv...>. The shim (a fixed literal per key target —
# never config-derived) reads the key from fd 3 when there is one, closes fd 3,
# and execs the harness with its stdout in <stdout-file> and its stdin from
# <stdin-file> (the prompt copy for codex/claude; /dev/null for opencode);
# run_capped captures stderr. run_capped itself runs the child with
# </dev/null, which is why the prompt redirect has to live in the shim.
# ---------------------------------------------------------------------------
case "$PROVIDER:$HARNESS" in
  openrouter:claude)
    SHIM='IFS= read -r K <&3 || [ -n "$K" ]; exec 3<&-; ANTHROPIC_AUTH_TOKEN=$K; export ANTHROPIC_AUTH_TOKEN; K=; o=$0; f=$1; shift; exec "$@" >"$o" <"$f"'
    ;;
  openrouter:*)
    SHIM='IFS= read -r K <&3 || [ -n "$K" ]; exec 3<&-; OPENROUTER_API_KEY=$K; export OPENROUTER_API_KEY; K=; o=$0; f=$1; shift; exec "$@" >"$o" <"$f"'
    ;;
  *)
    SHIM='exec 3<&-; o=$0; f=$1; shift; exec "$@" >"$o" <"$f"'
    ;;
esac
case "$HARNESS" in
  opencode) STDIN_SRC=/dev/null ;;
  *) STDIN_SRC="$PROMPT_COPY" ;;
esac

OUT="$T/out"
LAST="$T/last.txt"
_old_ifs=$IFS
IFS=$NL
# shellcheck disable=SC2086 # deliberate newline split of the allowlist
set -- $ENV_LIST
IFS=$_old_ifs
if [ "$HARNESS:$PROVIDER" = claude:openrouter ]; then
  set -- "$@" "CLAUDE_CODE_EXTRA_BODY=$OR_EXTRA_BODY"
fi
set -- env -i "$@" /bin/sh -c "$SHIM" "$OUT" "$STDIN_SRC" "$BIN"
case "$HARNESS" in
  codex)
    # No positional prompt: `codex exec` then reads the prompt from stdin.
    # OpenRouter: an inline provider whose key codex reads from
    # OPENROUTER_API_KEY (exported by the shim from fd 3). Fixed literals only.
    set -- "$@" exec
    if [ "$PROVIDER" = ollama ]; then
      set -- "$@" --oss --local-provider ollama
    else
      set -- "$@" -c "model_providers.openrouter={ name='OpenRouter', base_url='https://openrouter.ai/api/v1', wire_api='responses', env_key='OPENROUTER_API_KEY' }" \
        -c model_provider="openrouter"
    fi
    # Strip *KEY*/*SECRET*/*TOKEN* vars from the commands codex spawns (its
    # default forwards them), so a prompt-injected `env` cannot print the key;
    # codex itself still reads OPENROUTER_API_KEY for its own requests.
    set -- "$@" -c shell_environment_policy.ignore_default_excludes=false
    set -- "$@" --sandbox read-only --skip-git-repo-check -m "$MODEL" -o "$LAST"
    ;;
  claude)
    # No positional prompt: `claude -p` then reads the prompt from stdin.
    # --tools= MUST be the '=' form: the flag is variadic and would swallow
    # any following positional.
    set -- "$@" -p --tools=Read,Grep,Glob --restricted --strict-mcp-config \
      --setting-sources "" --permission-mode dontAsk --max-turns "$MAX_TURNS" \
      --no-session-persistence --output-format json --model "$MODEL"
    ;;
  opencode)
    # `opencode run` ignores stdin. The prompt is the attached file (relative
    # to the snapshot cwd); `--` ends the -f array so the fixed message is the
    # positional message, not a second file.
    set -- "$@" run --pure --format json --model "$PROVIDER/$MODEL" \
      -f "$OPENCODE_PROMPT_NAME" -- "$OPENCODE_MSG"
    ;;
esac

# The harness runs with cwd = the tracked-only snapshot ($T/repo), in a
# subshell so relative result/prompt paths stay valid here. The key reaches the
# shim through fd 3: run_capped closes stdin, so it can't be stdin; fd 3
# survives timeout/env and is closed by the shim before exec (which then
# points stdin at the prompt copy).
if [ "$PROVIDER" = openrouter ]; then
  printf '%s\n' "$KEY" | (
    cd "$T/repo" || exit 0
    run_capped "$CAP" "$T/run.log" "$@" 3<&0
    printf '%s\n' "$LAST_RC" >"$T/run.rc"
  )
else
  (
    cd "$T/repo" || exit 0
    run_capped "$CAP" "$T/run.log" "$@" 3<&-
    printf '%s\n' "$LAST_RC" >"$T/run.rc"
  )
fi
RUN_RC="$(cat "$T/run.rc" 2>/dev/null || echo 1)"
[ -n "$RUN_RC" ] || RUN_RC=1

case "$RUN_RC" in
  124 | 137 | 143)
    KEY=""
    skip "timed out after ${CAP}s"
    ;;
esac

# ---------------------------------------------------------------------------
# Extract the final answer (sanitised) + the harness's own error text.
#   ANSWER  $T/answer.md — model text, control + bidi/C1 characters stripped
#   ERRTXT  $T/err.txt   — only error-shaped text (never the model's answer and
#                          never the prompt echo), for the classifier below
#   HREASON a harness-specific skip reason, if any
# ---------------------------------------------------------------------------
JQ_CLEAN='
def clean: tostring | explode
  | map(select(. == 9 or . == 10 or (. >= 32 and . != 127 and (. < 128 or . > 159)
               and . != 1564 and . != 8206 and . != 8207
               and (. < 8234 or . > 8238) and (. < 8294 or . > 8297))))
  | implode;
'
ANSWER="$T/answer.md"
ERRTXT="$T/err.txt"
HREASON=""
: >"$ANSWER"
: >"$ERRTXT"
[ -f "$OUT" ] || : >"$OUT"
[ -f "$T/run.log" ] || : >"$T/run.log"

case "$HARNESS" in
  codex)
    # The answer is ONLY the -o file. Never fall back to the transcript: it
    # echoes the prompt (and so the reviewed code) back.
    if [ -s "$LAST" ]; then
      "$JQ" -Rrs "$JQ_CLEAN"'clean' "$LAST" >"$ANSWER" 2>/dev/null || : >"$ANSWER"
    fi
    if [ -z "$(tr -d ' \t\r\n' <"$ANSWER")" ]; then
      HREASON="no final answer from the model"
    fi
    # codex's own errors are "ERROR: ..." / "Error: ..." lines; the rest of
    # its stderr is the transcript (prompt echo) and is not classified.
    grep -hE '^(ERROR|Error|error)[: ]' "$T/run.log" "$OUT" >>"$ERRTXT" 2>/dev/null
    ;;
  claude)
    cat "$T/run.log" >>"$ERRTXT"
    if "$JQ" -e 'type == "object"' "$OUT" >/dev/null 2>&1; then
      _sub="$("$JQ" -r '.subtype // "" | tostring' "$OUT" | tr -cd 'A-Za-z0-9_.-' | cut -c1-60)"
      _iserr="$("$JQ" -r '.is_error == true' "$OUT")"
      if [ "$_iserr" = false ] && [ "$_sub" = success ]; then
        "$JQ" -r "$JQ_CLEAN"'.result // "" | clean' "$OUT" >"$ANSWER" 2>/dev/null || : >"$ANSWER"
      else
        case "$_sub" in
          '' | success) HREASON="error result" ;;
          *) HREASON="$_sub" ;;
        esac
        "$JQ" -r '(.result // "" | tostring),
          (if .api_error_status then "HTTP \(.api_error_status)" else empty end),
          (.errors // [] | tostring)' "$OUT" >>"$ERRTXT" 2>/dev/null
      fi
      # model check: did Claude Code run the model we asked for?
      # Exclusive: ANY other key (e.g. a background claude-haiku-* call) means
      # code may have gone to another model — family unknown, findings kept.
      if ! "$JQ" -e --arg m "$MODEL" '(.modelUsage // {}) | type == "object" and keys == [$m]' "$OUT" >/dev/null 2>&1; then
        _ran="$("$JQ" -r '(.modelUsage // {}) | if type == "object" then keys | join(",") else "" end' "$OUT" 2>/dev/null)"
        note "claude ran model(s) '$(one_line "$_ran" | cut -c1-120)', not the configured '$MODEL' — family set to unknown"
        FAMILY=unknown
        DISTINCT=false
      fi
    else
      # not JSON: a startup failure printed text instead.
      cat "$OUT" >>"$ERRTXT"
      HREASON="invalid output (not JSON)"
    fi
    ;;
  opencode)
    cat "$T/run.log" >>"$ERRTXT"
    # JSON events, one per line; the final answer is every `text` part of the
    # message that carried the LAST text part (earlier messages are interim
    # text before tool calls). Non-JSON lines are error text.
    "$JQ" -Rnr "$JQ_CLEAN"'
      [inputs | fromjson? | select(type == "object" and .type == "text"
        and (.part | type) == "object" and (.part.text | type) == "string")] as $t
      | if ($t | length) == 0 then empty
        else ($t[-1].part.messageID) as $mid
          | [$t[] | select(.part.messageID == $mid) | .part.text] | join("\n") | clean
        end' "$OUT" >"$ANSWER" 2>/dev/null || : >"$ANSWER"
    "$JQ" -Rnr '[inputs | fromjson? | select(type == "object" and .type == "error")]
      | .[] | (.error // {} | tostring)' "$OUT" >>"$ERRTXT" 2>/dev/null
    "$JQ" -Rr 'select((try (fromjson | type) catch "text") != "object")' "$OUT" >>"$ERRTXT" 2>/dev/null
    ;;
esac

# Provider key in the answer: a prompt-injected model can read the key (codex
# runs shell commands, and the key is in codex's own environment). Discard the
# whole answer when it carries the key: plain, spaced, split or upper-cased
# (any 16 of its hex characters in a row, after dropping everything else),
# reversed, or base64. The key travels on stdin only, never argv or disk.
if [ -n "$KEY" ]; then
  tr -d ' \t\r\n' <"$ANSWER" >"$T/answer.flat"
  # never an empty pattern list: BSD grep -f then matches every line
  B64="$(printf '%s' "$KEY" | base64 2>/dev/null | tr -d '\n')"
  if printf '%s\n' "$KEY" | awk -v f="$ANSWER" '
      function hexonly(s) { s = tolower(s); gsub(/[^0-9a-f]/, "", s); return s }
      NR == 1 { k = hexonly($0) }
      END {
        n = length(k) < 16 ? length(k) : 16
        if (n < 8) exit 1
        r = ""
        for (i = length(k); i > 0; i--) r = r substr(k, i, 1)
        m = 0
        for (i = 1; i + n - 1 <= length(k); i++) { w[++m] = substr(k, i, n); w[++m] = substr(r, i, n) }
        c = ""
        while ((getline l < f) > 0) {
          s = c hexonly(l)
          for (j = 1; j <= m; j++) if (index(s, w[j])) exit 0
          c = length(s) < n ? s : substr(s, length(s) - n + 2)
        }
        exit 1
      }' ||
    { [ -n "$B64" ] && printf '%s\n' "$B64" | grep -qF -f - "$T/answer.flat"; }; then
    KEY=""
    B64=""
    skip "answer contained the provider key"
  fi
fi
KEY=""
B64=""

# valid: non-empty AND heading-anchored Findings + Overall Assessment lines
# (the same regexes as rc-invoke-provider.sh's classify OK-guard).
if [ -n "$(tr -d ' \t\r\n' <"$ANSWER")" ] &&
  grep -qiE '^[[:space:]]*(#+[[:space:]]*)?findings([[:space:]]*:|[[:space:]]*$)' "$ANSWER" 2>/dev/null &&
  grep -qiE '^[[:space:]]*(#+[[:space:]]*)?overall assessment([[:space:]]*:|[[:space:]]*$)' "$ANSWER" 2>/dev/null; then
  [ "$RUN_RC" = 0 ] || note "$HARNESS exited $RUN_RC; using its final answer anyway"
  N_FINDINGS="$(grep -ciE '^[[:space:]]*([-*+][[:space:]]+)?(\*\*)?`?severity`?(\*\*)?[[:space:]]*:' "$ANSWER" 2>/dev/null)"
  is_uint "$N_FINDINGS" || N_FINDINGS=0
  succeed "$ANSWER"
fi

# ---------------------------------------------------------------------------
# Classify the failure from error text only (never the prompt or the answer).
# ---------------------------------------------------------------------------
err_has() { grep -qiE "$1" "$ERRTXT" 2>/dev/null; }
if err_has '(^|[^0-9])401([^0-9]|$)|invalid[ _-]?api[ _-]?key|unauthori[sz]ed|authentication[ _-]?(failed|error)'; then
  skip "auth failure"
fi
if err_has '(^|[^0-9])402([^0-9]|$)|insufficient[ _-]?credits?|payment required'; then
  skip "out of credit"
fi
if err_has '(^|[^0-9])429([^0-9]|$)|rate[ _-]?limit|too many requests'; then
  skip "rate limited"
fi
if [ "$PROVIDER" = ollama ] &&
  err_has 'no running ollama|connection refused|econnrefused|cannot connect|unable to connect|failed to connect|connection error|error sending request'; then
  skip "ollama not reachable"
fi
[ -n "$HREASON" ] && skip "$HREASON"
if [ -z "$(tr -d ' \t\r\n' <"$ANSWER")" ]; then
  skip "no final answer from the model (exit $RUN_RC)"
fi
skip "invalid output (no Findings/Overall Assessment)"
