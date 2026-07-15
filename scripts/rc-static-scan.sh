#!/usr/bin/env sh
# rc-static-scan.sh — deterministic static-analysis runner (Phase 2, Step 2.5).
#
# Runs the configured deterministic tools (secrets/CVE scanners + SAST/lint)
# over the changed files, wrapping each in the SAME hard-timeout watchdog the
# Google-slot invoker uses (run_capped, sourced from rc-lib-timeout.sh), and
# emits normalized findings as evidence for the council — NOT as a voting
# reviewer. See rules/static-analysis.md and .superpowers/sdd/phase2-shared-spec.md.
#
# Usage:
#   rc-static-scan.sh <base-ref> <head-ref-or-worktree> <changed-files-list-file>
#
#   <base-ref>                 git base ref for diff scoping (may be "").
#   <head-ref-or-worktree>     head ref (PR/staged) or worktree path (unstaged).
#   <changed-files-list-file>  file with the changed paths, one per line.
#
# Env (effective static_analysis.* config, matching rc-config.sh's knobs):
#   RC_STATIC_ANALYSIS  bool, default true. "false" => immediate no-op.
#   RC_STATIC_TOOLS     comma list, default all 8. Tools not listed are skipped
#                       (SKIPPED: <tool> — disabled).
#   RC_STATIC_TIMEOUT   posint seconds, default 60. Per-tool hard cap.
#   RC_SEMGREP_CONFIG   str, default p/default. "off" => semgrep skipped;
#                       "p/…"/"r/…"/http(s):// => a registry ruleset ref passed
#                       through as --config <ref>; "auto" => skipped (it uploads
#                       project metadata and REQUIRES metrics, incompatible with
#                       our --metrics=off); any other value => a repo-owned
#                       ruleset FILE path passed as --config <path> (falls back
#                       to p/default if unreadable).
#
# stdout (the output contract):
#   TIER_A
#   <normalized line>*        (gitleaks/trufflehog secrets, osv-scanner CVEs)
#   TIER_B
#   <normalized line>*        (semgrep/ruff/shellcheck/actionlint/hadolint)
#   SKIPPED: <tool> — <reason>*   reason ∈ {not installed, not triggered (...),
#                                 disabled, semgrep off, network-unreachable, timeout}
#   Normalized line = tier|tool|severity_raw|file|line|rule|message
#   (free-text fields are stripped of newlines and the '|' delimiter).
#
# Contract notes:
#   - NEVER gate on a tool's exit code (lint/scan tools exit non-zero when they
#     find something) — we always parse the tool's structured output file. Only
#     run_capped's timeout-kill codes (124/143/137) are treated as a failure.
#   - Security: only ever run REPO-OWNED tool config (a committed .gitleaks.toml,
#     a repo-owned semgrep ruleset path). Never fetch/execute a PR-supplied
#     config, ruleset, or plugin. (`--config auto`'s rule *fetch* is data, allowed.)
#   - trufflehog present but network-unreachable => "ran, 0 findings" + a
#     network-unreachable note; never errors the batch.
#
# exit: 0 always on a completed (or no-op) scan; 2 on usage error.

set -eu

# ---------------------------------------------------------------------------
# Usage / argument handling
# ---------------------------------------------------------------------------

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <base-ref> <head-ref-or-worktree> <changed-files-list-file>" >&2
  exit 2
fi

BASE_REF="$1"
HEAD_REF="$2"
CHANGED_LIST="$3"

# Enabled gate — checked before touching the changed-file list so a disabled
# run is a true immediate no-op (the orchestrator also gates on this; belt+braces).
if [ "${RC_STATIC_ANALYSIS:-true}" = "false" ]; then
  exit 0
fi

if [ ! -f "$CHANGED_LIST" ]; then
  echo "Usage: changed-files list not found: $CHANGED_LIST" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Shared hard-timeout watchdog (run_capped + KILL_GRACE), sourced — identical
# TERM-then-KILL escalation as the Google-slot invoker. run_capped sets LAST_RC.
# ---------------------------------------------------------------------------

_LIBDIR="${0%/*}"
if [ "$_LIBDIR" = "$0" ]; then
  _LIBDIR="."
fi
. "$_LIBDIR/rc-lib-timeout.sh"

# ---------------------------------------------------------------------------
# Effective config (env only — the orchestrator passes rc-config.sh's output in)
# ---------------------------------------------------------------------------

STATIC_TOOLS="${RC_STATIC_TOOLS:-gitleaks,trufflehog,osv-scanner,semgrep,ruff,shellcheck,actionlint,hadolint}"

STATIC_TIMEOUT="${RC_STATIC_TIMEOUT:-60}"
case "$STATIC_TIMEOUT" in
  '' | *[!0-9]*)
    echo "rc-static-scan: RC_STATIC_TIMEOUT='$STATIC_TIMEOUT' invalid; using 60" >&2
    STATIC_TIMEOUT=60
    ;;
esac
if [ "$STATIC_TIMEOUT" -le 0 ]; then
  STATIC_TIMEOUT=60
fi

SEMGREP_CONFIG="${RC_SEMGREP_CONFIG:-p/default}"

# Docker run-time gate (Phase 4) — opt-in, per-run. RC_STATIC_DOCKER_TOOLS is a
# comma list of tools to run via their official docker image THIS run when the
# tool is MISSING from PATH. Unset/empty => no docker (today's behavior exactly,
# config-invariant: the daemon is never even probed). REPO_ROOT is the repo the
# script scans — docker mounts it read-only at /src; DOCKER_AVAILABLE is a lazy
# once-probed cache ("" unknown, "yes"/"no" after the first daemon check).
STATIC_DOCKER_TOOLS="${RC_STATIC_DOCKER_TOOLS:-}"
REPO_ROOT="$(pwd -P)"
DOCKER_AVAILABLE=""

# Short wall-clock cap (seconds) for the `docker info` daemon probe — a
# stalled/booting daemon must not be able to hang the whole static scan
# before any per-tool timeout ever applies. Deliberately much shorter than
# STATIC_TIMEOUT: this is a liveness probe, not a scan.
DOCKER_PROBE_TIMEOUT=10

# ---------------------------------------------------------------------------
# Scratch buffers (TIER_A / TIER_B / SKIPPED accumulate as tools run, so the
# final output is grouped regardless of the order tools finish in).
# ---------------------------------------------------------------------------

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/rc-static.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

STDERR_CAP="$WORKDIR/stderr"     # a tool's stderr/progress (reused per tool)
TA="$WORKDIR/tier_a"
TB="$WORKDIR/tier_b"
SK="$WORKDIR/skipped"
: >"$TA"
: >"$TB"
: >"$SK"

# ---------------------------------------------------------------------------
# jq extraction filters — one per tool. Each emits `tier|tool|sev|file|line|
# rule|message` per finding, with newlines and '|' stripped from free-text
# fields (san) so every finding is exactly one clean 7-field line.
# ---------------------------------------------------------------------------

SAN='def san: tostring|gsub("[\r\n|]";" ");'

GITLEAKS_FILTER="$SAN"'
  .[]? | [$tier,$tool,"critical",(.File//""|san),((.StartLine//0)|tostring),
          ("gitleaks:"+((.RuleID//"secret")|san)),(.Description//"secret detected"|san)]
  | join("|")'

# trufflehog emits newline-delimited JSON (one object per finding); jq streams
# these object-by-object (no slurp), so the filter operates on each in turn.
TRUFFLEHOG_FILTER="$SAN"'
  select(.Verified==true)
  | [$tier,$tool,"critical",
     ((.SourceMetadata.Data.Git.file // .SourceMetadata.Data.Filesystem.file // "")|san),
     ((.SourceMetadata.Data.Git.line // 0)|tostring),
     ("trufflehog:"+((.DetectorName//"secret")|ascii_downcase|san)),
     (("verified "+(.DetectorName//"secret")+" secret")|san)]
  | join("|")'

# osv-scanner emits a single JSON object; the filter walks results/packages/vulns.
# osv severity: prefer the advisory's level word (.database_specific.severity,
# e.g. CRITICAL/HIGH/MEDIUM), then the max_severity of the package group that
# actually contains THIS vuln's id — a package can hold several groups with
# different severities, so grabbing the first group would mis-assign. Never
# .severity[].score — that is a CVSS *vector* string (CVSS:3.1/AV:N/...), not a
# level. rule id is tool-prefixed (`osv-scanner:<id>`).
OSV_FILTER="$SAN"'
  .results[]? as $r | ($r.packages[]?) as $p | ($p.vulnerabilities[]?) as $v
  | [$tier,$tool,
     (($v.database_specific.severity
       // first($p.groups[]? | select((.ids // []) | index($v.id)) | .max_severity)
       // "UNKNOWN")|san),
     (($r.source.path // "")|san),"",
     ("osv-scanner:"+(($v.id//"vuln")|ascii_downcase|san)),
     ((($v.id//"CVE")+" "+($v.summary // $v.details // "known vulnerability"))|san)]
  | join("|")'

SEMGREP_FILTER="$SAN"'
  .results[]? | [$tier,$tool,((.extra.severity//"INFO")|san),(.path//""|san),
                 ((.start.line//0)|tostring),("semgrep:"+((.check_id//"rule")|san)),
                 (.extra.message//"semgrep finding"|san)]
  | join("|")'

RUFF_FILTER="$SAN"'
  .[]? | [$tier,$tool,"warning",(.filename//""|san),((.location.row//0)|tostring),
          ("ruff:"+((.code//"E")|san)),(.message//"ruff finding"|san)]
  | join("|")'

SHELLCHECK_FILTER="$SAN"'
  .comments[]? | [$tier,$tool,(.level//"warning"|san),(.file//""|san),
                  ((.line//0)|tostring),("shellcheck:SC"+((.code//0)|tostring)),
                  (.message//"shellcheck finding"|san)]
  | join("|")'

ACTIONLINT_FILTER="$SAN"'
  .[]? | [$tier,$tool,(.kind//"error"|san),(.filepath//""|san),((.line//0)|tostring),
          ("actionlint:"+((.kind//"error")|san)),(.message//"actionlint finding"|san)]
  | join("|")'

HADOLINT_FILTER="$SAN"'
  .[]? | [$tier,$tool,(.level//"warning"|san),(.file//""|san),((.line//0)|tostring),
          ("hadolint:"+((.code//"DL")|san)),(.message//"hadolint finding"|san)]
  | join("|")'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# add_skip <tool> <reason>: record a skip line (stdout output block).
add_skip() {
  printf 'SKIPPED: %s — %s\n' "$1" "$2" >>"$SK"
}

# tool_configured <tool>: is the tool present in the effective RC_STATIC_TOOLS list?
tool_configured() {
  case ",$STATIC_TOOLS," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# any_changed: at least one changed file was passed in.
any_changed() {
  [ -s "$CHANGED_LIST" ]
}

# ---------------------------------------------------------------------------
# Docker run-time gate helpers (Phase 4). All are inert when
# RC_STATIC_DOCKER_TOOLS is empty — tool_docker_enabled short-circuits on the
# list membership before ever probing the daemon, so an unset env is a true
# no-op (config-invariance).
# ---------------------------------------------------------------------------

# docker_image_for <tool>: the pinned image for a docker-supported scanner, or
# "" for anything else. Only the 4 core scanners are supported; the lint tools
# (ruff/shellcheck/actionlint/hadolint) return "" and never run via docker.
# `:latest` is intentional — an opt-in convenience gate, not a reproducible pin.
docker_image_for() {
  case "$1" in
    gitleaks) echo "ghcr.io/gitleaks/gitleaks:latest" ;;
    trufflehog) echo "ghcr.io/trufflesecurity/trufflehog:latest" ;;
    semgrep) echo "semgrep/semgrep:latest" ;;
    osv-scanner) echo "ghcr.io/google/osv-scanner:latest" ;;
    *) echo "" ;;
  esac
}

# docker_available: true iff the docker CLI is on PATH AND its daemon answers
# within DOCKER_PROBE_TIMEOUT. The daemon probe runs through the SAME
# run_capped watchdog every tool invocation uses — a stalled/booting daemon
# hangs `docker info` indefinitely otherwise, which would block the whole
# static scan before any per-tool timeout ever applies. Probed at most once
# (cached in DOCKER_AVAILABLE) so N docker tools don't each pay the daemon
# round-trip. CLI presence is checked FIRST so the daemon is never probed
# when docker isn't even installed.
docker_available() {
  if [ -z "$DOCKER_AVAILABLE" ]; then
    if command -v docker >/dev/null 2>&1; then
      _da_out="$WORKDIR/docker_info_probe"
      run_capped "$DOCKER_PROBE_TIMEOUT" "$_da_out" docker info
      if [ "${LAST_RC:-0}" -eq 0 ]; then
        DOCKER_AVAILABLE=yes
      else
        DOCKER_AVAILABLE=no
      fi
    else
      DOCKER_AVAILABLE=no
    fi
  fi
  [ "$DOCKER_AVAILABLE" = yes ]
}

# tool_docker_listed <tool>: is the tool in the effective RC_STATIC_DOCKER_TOOLS list?
tool_docker_listed() {
  case ",$STATIC_DOCKER_TOOLS," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# tool_docker_enabled <tool>: true iff the tool is opted into docker this run,
# has a supported image, AND the daemon is up. List membership is checked FIRST
# so the daemon is never probed unless a docker run is actually possible.
tool_docker_enabled() {
  tool_docker_listed "$1" || return 1
  [ -n "$(docker_image_for "$1")" ] || return 1
  docker_available
}

# ---------------------------------------------------------------------------
# Domain-trigger matchers (by basename, except workflows which are path-shaped).
# ---------------------------------------------------------------------------

is_python() { case "${1##*/}" in *.py) return 0 ;; *) return 1 ;; esac; }
is_shell() { case "${1##*/}" in *.sh | *.bash) return 0 ;; *) return 1 ;; esac; }
is_dockerfile() { case "${1##*/}" in Dockerfile | Dockerfile.* | *.Dockerfile | *.dockerfile) return 0 ;; *) return 1 ;; esac; }
is_workflow() { case "$1" in *.github/workflows/*.yml | *.github/workflows/*.yaml) return 0 ;; *) return 1 ;; esac; }

# is_lockfile <path>: a dependency manifest/lockfile osv-scanner understands.
is_lockfile() {
  case "${1##*/}" in
    package-lock.json | yarn.lock | pnpm-lock.yaml | Gemfile.lock | go.sum | go.mod \
      | Cargo.lock | composer.lock | Pipfile.lock | poetry.lock | mix.lock \
      | pubspec.lock | gradle.lockfile | packages.lock.json)
      return 0
      ;;
    requirements*.txt)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# has_shell_shebang <path>: readable file whose first line is a sh/bash shebang
# (shellcheck's domain extends to extension-less scripts).
has_shell_shebang() {
  [ -r "$1" ] || return 1
  IFS= read -r _hs_first <"$1" 2>/dev/null || return 1
  case "$_hs_first" in
    '#!'*sh | '#!'*sh' '*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# CLI-shape probes (Risk #7 — do not hardcode a version's subcommand shape)
# ---------------------------------------------------------------------------

# gitleaks_modern: true if this gitleaks exposes the v8.19+ `git`/`dir`/`stdin`
# subcommands (older releases use `detect`). Unknown version => assume modern.
gitleaks_modern() {
  _gm_v="$(gitleaks version 2>/dev/null || true)"
  if [ -z "$_gm_v" ]; then
    _gm_v="$(gitleaks --version 2>/dev/null || true)"
  fi
  _gm_v="$(printf '%s' "$_gm_v" | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
  [ -n "$_gm_v" ] || return 0
  _gm_maj="${_gm_v%%.*}"
  _gm_min="${_gm_v#*.}"
  if [ "$_gm_maj" -gt 8 ]; then return 0; fi
  if [ "$_gm_maj" -eq 8 ] && [ "$_gm_min" -ge 19 ]; then return 0; fi
  return 1
}

# osv_v2: true if this osv-scanner uses the v2 `scan source` subcommand shape
# (v1 takes bare `--lockfile=`). Unknown version => assume v2 (current).
osv_v2() {
  _ov_v="$(osv-scanner --version 2>/dev/null || true)"
  _ov_v="$(printf '%s' "$_ov_v" | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
  [ -n "$_ov_v" ] || return 0
  _ov_maj="${_ov_v%%.*}"
  [ "$_ov_maj" -ge 2 ]
}

# semgrep_can_baseline: --baseline-commit aborts on unstaged changes / non-git;
# only use it for a clean git base with no unstaged working-tree changes.
semgrep_can_baseline() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  [ -n "$BASE_REF" ] || return 1
  git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1 || return 1
  if ! git diff --quiet >/dev/null 2>&1; then return 1; fi
  return 0
}

# worktree_head: true when <head-ref-or-worktree> is the working tree rather than
# a distinct, resolvable git ref — i.e. Review Council's local staged/unstaged
# review mode, where the orchestrator passes head="." (or a worktree path) with
# base="HEAD". A git-RANGE scan there (gitleaks --log-opts="HEAD..", trufflehog
# --since-commit HEAD --branch .) would cover an empty/invalid range and silently
# report 0 findings — so the Tier-A range scanners switch to a working-tree scan
# instead (mirroring semgrep's full-scan fallback). Also true when base==head.
worktree_head() {
  case "$HEAD_REF" in
    '' | '.' | './' | /* | ./* | ../*) return 0 ;;
  esac
  [ -d "$HEAD_REF" ] && return 0
  [ "$BASE_REF" = "$HEAD_REF" ] && return 0
  # A ref we cannot resolve to a commit can't anchor a range either — treat it as
  # worktree/unknown (only meaningful when we are inside a git work tree).
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git rev-parse --verify --quiet "${HEAD_REF}^{commit}" >/dev/null 2>&1 || return 0
  fi
  return 1
}

# network_failed: the last tool's captured stderr shows an egress/DNS failure.
network_failed() {
  [ -f "$STDERR_CAP" ] || return 1
  grep -qiE 'no such host|network is unreachable|connection refused|dial tcp|i/o timeout|context deadline exceeded|tls handshake|could not resolve|temporary failure in name resolution|no route to host|connection reset|network error|error verifying|failed to verify' "$STDERR_CAP" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Run helpers — every tool invocation goes through run_capped so a wedged tool
# can't outlive STATIC_TIMEOUT.
# ---------------------------------------------------------------------------

# hit_timeout: run_capped's last child was TERM/KILLed at the cap.
hit_timeout() {
  case "${LAST_RC:-0}" in
    124 | 143 | 137) return 0 ;;
    *) return 1 ;;
  esac
}

# exec_failed <accepted-codes>: true when the last capped run (LAST_RC) exited
# with a code NOT in the space-separated <accepted-codes> list — a genuine tool
# failure (crash, bad args, runtime error) whose partial/garbage report must NOT
# be parsed into a tier buffer. Lint/scan tools legitimately exit non-zero when
# they FIND something, so callers pass the tool's real accepted set (typically
# "0 1" = clean/findings). Timeouts (124/143/137) are ruled out by hit_timeout
# first and are not this function's concern.
exec_failed() {
  _xf_rc="${LAST_RC:-0}"
  for _xf_ok in $1; do
    if [ "$_xf_rc" = "$_xf_ok" ]; then return 1; fi
  done
  return 0
}

# run_report <argv...>: the tool writes its OWN structured output (via a flag in
# argv, e.g. gitleaks -r / semgrep --output); run_capped just caps it and
# captures its stderr/progress to STDERR_CAP.
run_report() {
  : >"$STDERR_CAP"
  run_capped "$STATIC_TIMEOUT" "$STDERR_CAP" "$@"
}

# run_stdout <report> <argv...>: the tool prints structured output to STDOUT; we
# redirect that stdout into <report> (via an exec'd sh -c so the pid stays the
# tool's, keeping the cap's TERM/KILL effective) and its stderr to STDERR_CAP,
# so parsing always sees clean JSON even when the tool logs progress to stderr.
run_stdout() {
  _rs_report="$1"
  shift
  : >"$STDERR_CAP"
  : >"$_rs_report"
  run_capped "$STATIC_TIMEOUT" "$STDERR_CAP" sh -c 'exec "$@" >"$0"' "$_rs_report" "$@"
}

# emit_findings <report> <buffer> <jq-args...>: parse the tool's structured
# output into normalized lines, appending to the tier buffer. jq failures
# (empty/absent/garbage output) degrade to zero findings, never an error.
emit_findings() {
  _ef_report="$1"
  _ef_buf="$2"
  shift 2
  [ -s "$_ef_report" ] || return 0
  _ef_lines="$(jq -r "$@" "$_ef_report" 2>/dev/null || true)"
  [ -n "$_ef_lines" ] || return 0
  printf '%s\n' "$_ef_lines" >>"$_ef_buf"
}

# file_in_changed <path>: is <path> (normalized) one of the changed files?
file_in_changed() {
  _fc_t="${1#./}"
  while IFS= read -r _fc_cf || [ -n "$_fc_cf" ]; do
    [ -n "$_fc_cf" ] || continue
    _fc_c="${_fc_cf#./}"
    if [ "$_fc_c" = "$_fc_t" ]; then return 0; fi
  done <"$CHANGED_LIST"
  return 1
}

# ± context window (lines) around a changed hunk kept by filter_changed_hunks —
# pins the "small context window" the docs (rules/static-analysis.md, lever 3)
# leave to the implementation. A finding within HUNK_CTX lines of a changed
# range is treated as belonging to that change.
HUNK_CTX=3

# filter_changed <lines-file>: emit only the normalized lines whose file field
# is a changed file (FILE-level). This is the graceful fallback used by
# filter_changed_hunks when a file's changed line-ranges can't be derived
# (git unavailable / not a repo / no diff). Prints kept lines to stdout.
filter_changed() {
  while IFS='|' read -r _flt_tier _flt_tool _flt_sev _flt_file _flt_line _flt_rule _flt_msg || [ -n "${_flt_tier:-}" ]; do
    [ -n "${_flt_tier:-}" ] || continue
    if file_in_changed "$_flt_file"; then
      printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$_flt_tier" "$_flt_tool" "$_flt_sev" "$_flt_file" "$_flt_line" "$_flt_rule" "$_flt_msg"
    fi
  done <"$1"
}

# changed_ranges <file>: print the NEW-side changed-line ranges of <file> as
# "start end" pairs (one per line), derived from git's unified=0 diff. Empty
# output means "not derivable" (git unavailable, not a repo, or no diff for the
# file) — callers fall back to a FILE-level keep. Hunk header @@ -a,b +c,d @@
# gives new-side range [c, c+d-1]; d defaults to 1 when omitted; d=0 is a pure
# deletion (no new-side lines) and is skipped.
changed_ranges() {
  _cr_file="$1"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if worktree_head; then
    # Local staged/unstaged mode: base ref vs the working tree.
    _cr_diff="$(git diff --unified=0 "$BASE_REF" -- "$_cr_file" 2>/dev/null || true)"
  else
    _cr_diff="$(git diff --unified=0 "$BASE_REF" "$HEAD_REF" -- "$_cr_file" 2>/dev/null || true)"
  fi
  [ -n "$_cr_diff" ] || return 0
  printf '%s\n' "$_cr_diff" | awk '
    /^@@ / {
      plus = $3            # the "+c,d" field of "@@ -a,b +c,d @@"
      sub(/^\+/, "", plus)
      n = split(plus, p, ",")
      start = p[1] + 0
      if (n >= 2) { d = p[2] + 0 } else { d = 1 }
      if (d <= 0) { next }  # pure deletion — no new-side lines
      print start, (start + d - 1)
    }'
}

# filter_changed_hunks <lines-file>: emit only the normalized lines whose file
# is changed AND whose line number lands within ±HUNK_CTX of one of that file's
# changed NEW-side ranges — the changed-hunk post-filter for semgrep's full-scan
# fallback (when --baseline-commit can't be used). If a file's ranges can't be
# derived (no git / not a repo / no diff), it degrades to the FILE-level keep so
# the batch is never errored and real findings are never dropped wholesale.
filter_changed_hunks() {
  while IFS='|' read -r _fh_tier _fh_tool _fh_sev _fh_file _fh_line _fh_rule _fh_msg || [ -n "${_fh_tier:-}" ]; do
    [ -n "${_fh_tier:-}" ] || continue
    file_in_changed "$_fh_file" || continue
    _fh_ranges="$(changed_ranges "$_fh_file")"
    _fh_keep=0
    if [ -z "$_fh_ranges" ]; then
      # No derivable ranges — FILE-level fallback (keep the changed file's line).
      _fh_keep=1
    else
      case "$_fh_line" in
        '' | *[!0-9]*)
          # Unparseable line — keep rather than risk dropping a real finding.
          _fh_keep=1
          ;;
        *)
          if printf '%s\n' "$_fh_ranges" | awk -v ln="$_fh_line" -v ctx="$HUNK_CTX" '
               { if (ln >= $1 - ctx && ln <= $2 + ctx) { f = 1 } }
               END { exit(f ? 0 : 1) }'; then
            _fh_keep=1
          fi
          ;;
      esac
    fi
    if [ "$_fh_keep" -eq 1 ]; then
      printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$_fh_tier" "$_fh_tool" "$_fh_sev" "$_fh_file" "$_fh_line" "$_fh_rule" "$_fh_msg"
    fi
  done <"$1"
}

# strip_src_prefix <lines-file>: normalize docker tools' container paths back to
# repo-relative. A docker scan mounts the repo read-only at /src, so the tool's
# reported FILE field comes back as /src/<path> (semgrep, trufflehog, osv-scanner
# all do this; gitleaks scanning `.` from -w /src already reports relative, so it
# passes through untouched). filter_changed / filter_changed_hunks compare the
# FILE field against the repo-relative changed list, so this MUST run before
# them. Reads tier|tool|sev|file|line|rule|msg, strips a leading /src/ from the
# file field only, and prints every line back through.
strip_src_prefix() {
  while IFS='|' read -r _sp_tier _sp_tool _sp_sev _sp_file _sp_line _sp_rule _sp_msg || [ -n "${_sp_tier:-}" ]; do
    [ -n "${_sp_tier:-}" ] || continue
    case "$_sp_file" in
      /src/*) _sp_file="${_sp_file#/src/}" ;;
    esac
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "$_sp_tier" "$_sp_tool" "$_sp_sev" "$_sp_file" "$_sp_line" "$_sp_rule" "$_sp_msg"
  done <"$1"
}

# ---------------------------------------------------------------------------
# Per-tool runners (probe + trigger already checked by the dispatcher below;
# each builds its diff-scoped argv, runs it capped, and parses the output).
# ---------------------------------------------------------------------------

run_gitleaks() {
  if ! any_changed; then
    add_skip gitleaks "not triggered (no matching files)"
    return
  fi
  _gl_report="$WORKDIR/gitleaks.json"
  : >"$_gl_report"
  if gitleaks_modern; then _gl_modern=1; else _gl_modern=0; fi
  if worktree_head; then _gl_wth=1; else _gl_wth=0; fi
  if [ "$_gl_wth" -eq 1 ]; then
    # Local staged/unstaged mode: no distinct head ref, so a git-range scan
    # (--log-opts="HEAD..") would cover 0 commits and silently report nothing.
    # Scan the working-tree files directly instead (modern: `dir`; old: `detect
    # --no-git` treats --source as a plain directory, not git history).
    if [ "$_gl_modern" -eq 1 ]; then
      set -- gitleaks dir
    else
      set -- gitleaks detect --no-git --source .
    fi
  else
    if [ "$_gl_modern" -eq 1 ]; then
      set -- gitleaks git
    else
      set -- gitleaks detect --source .
    fi
    if [ -n "$BASE_REF" ]; then set -- "$@" --log-opts="$BASE_REF..$HEAD_REF"; fi
  fi
  set -- "$@" -f json -r "$_gl_report"
  if [ -f .gitleaks.toml ]; then set -- "$@" -c .gitleaks.toml; fi
  # modern subcommands (git/dir) take the scan path as a trailing positional
  if [ "$_gl_modern" -eq 1 ]; then set -- "$@" .; fi
  run_report "$@"
  if hit_timeout; then
    add_skip gitleaks "timeout"
    return
  fi
  if exec_failed "0 1"; then
    add_skip gitleaks "execution failed (exit ${LAST_RC:-0})"
    return
  fi
  if [ "$_gl_wth" -eq 1 ]; then
    # Working-tree scan covers UNCHANGED files too; a secret in an unchanged file
    # must not report as if this change introduced it — keep only changed files.
    _gl_tmp="$WORKDIR/gitleaks_lines"
    : >"$_gl_tmp"
    emit_findings "$_gl_report" "$_gl_tmp" --arg tier TIER_A --arg tool gitleaks "$GITLEAKS_FILTER"
    filter_changed "$_gl_tmp" >>"$TA"
  else
    emit_findings "$_gl_report" "$TA" --arg tier TIER_A --arg tool gitleaks "$GITLEAKS_FILTER"
  fi
}

run_trufflehog() {
  if ! any_changed; then
    add_skip trufflehog "not triggered (no matching files)"
    return
  fi
  _th_report="$WORKDIR/trufflehog.json"
  if worktree_head; then _th_wth=1; else _th_wth=0; fi
  if [ "$_th_wth" -eq 1 ]; then
    # Local staged/unstaged mode: no distinct head branch, so --since-commit
    # HEAD --branch . forms an invalid/empty git range. Scan the working tree.
    set -- trufflehog filesystem . --results=verified --json
  else
    set -- trufflehog git "file://." --results=verified --json
    if [ -n "$BASE_REF" ]; then set -- "$@" --since-commit "$BASE_REF"; fi
    if [ -n "$HEAD_REF" ]; then set -- "$@" --branch "$HEAD_REF"; fi
  fi
  run_stdout "$_th_report" "$@"
  if hit_timeout; then
    add_skip trufflehog "timeout"
    return
  fi
  # trufflehog's only clean exit is 0. A non-0 exit is either the graceful
  # network-degrade case (a live-verification egress failure) or a genuine tool
  # failure — distinguish them by the stderr signature, never leak a garbage
  # report into Tier A either way.
  if exec_failed "0"; then
    if network_failed; then
      add_skip trufflehog "network-unreachable"
    else
      add_skip trufflehog "execution failed (exit ${LAST_RC:-0})"
    fi
    return
  fi
  _th_before="$(wc -l <"$TA" 2>/dev/null || echo 0)"
  if [ "$_th_wth" -eq 1 ]; then
    # Working-tree scan covers UNCHANGED files too; a secret in an unchanged file
    # must not report as if this change introduced it — keep only changed files.
    _th_tmp="$WORKDIR/trufflehog_lines"
    : >"$_th_tmp"
    emit_findings "$_th_report" "$_th_tmp" --arg tier TIER_A --arg tool trufflehog "$TRUFFLEHOG_FILTER"
    filter_changed "$_th_tmp" >>"$TA"
  else
    emit_findings "$_th_report" "$TA" --arg tier TIER_A --arg tool trufflehog "$TRUFFLEHOG_FILTER"
  fi
  _th_after="$(wc -l <"$TA" 2>/dev/null || echo 0)"
  # Graceful network degrade (Risk #3): 0 verified findings ADDED TO $TA (i.e.
  # after the changed-file filter above) + a network error in the tool's stderr
  # => "ran, 0 findings" + a note. Never errors the batch.
  if [ "$_th_before" -eq "$_th_after" ] && network_failed; then
    add_skip trufflehog "network-unreachable"
  fi
}

run_osv() {
  set --
  while IFS= read -r _osv_f || [ -n "$_osv_f" ]; do
    [ -n "$_osv_f" ] || continue
    if is_lockfile "$_osv_f"; then set -- "$@" --lockfile="$_osv_f"; fi
  done <"$CHANGED_LIST"
  if [ "$#" -eq 0 ]; then
    add_skip osv-scanner "not triggered (no matching files)"
    return
  fi
  _osv_report="$WORKDIR/osv.json"
  if osv_v2; then
    run_stdout "$_osv_report" osv-scanner scan source "$@" --format json
  else
    run_stdout "$_osv_report" osv-scanner "$@" --format json
  fi
  if hit_timeout; then
    add_skip osv-scanner "timeout"
    return
  fi
  if exec_failed "0 1"; then
    add_skip osv-scanner "execution failed (exit ${LAST_RC:-0})"
    return
  fi
  emit_findings "$_osv_report" "$TA" --arg tier TIER_A --arg tool osv-scanner "$OSV_FILTER"
}

run_semgrep() {
  if ! any_changed; then
    add_skip semgrep "not triggered (no matching files)"
    return
  fi
  _sg_cfg="$SEMGREP_CONFIG"
  # Resolve the config ref. `auto` uploads project metadata to tailor rules and
  # REQUIRES semgrep metrics on — incompatible with our hardcoded --metrics=off
  # (and with the least-egress posture), so it is not runnable here: skip with
  # guidance. Registry refs (p/…, r/…, http(s)://) pass through as --config (rule
  # *fetch* is data, allowed — same basis as auto's fetch). Anything else is a
  # repo-owned ruleset FILE path; if unreadable, fall back to the p/default pack
  # with a note (never fetch/execute an untrusted/typo'd path).
  case "$_sg_cfg" in
    auto)
      add_skip semgrep "config 'auto' needs metrics/telemetry (incompatible with --metrics=off) — set semgrep_config to a pack like p/default or a repo-owned ruleset path"
      return
      ;;
    p/* | r/* | http://* | https://*)
      : # registry/remote ref — use as-is
      ;;
    *)
      if [ ! -f "$_sg_cfg" ] || [ ! -r "$_sg_cfg" ]; then
        echo "rc-static-scan: semgrep_config '$_sg_cfg' not a readable file; using p/default" >&2
        _sg_cfg="p/default"
      fi
      ;;
  esac
  _sg_report="$WORKDIR/semgrep.json"
  _sg_fallback=1
  set -- semgrep scan --config "$_sg_cfg" --json --output "$_sg_report" --metrics=off
  if semgrep_can_baseline; then
    _sg_fallback=0
    set -- "$@" --baseline-commit "$BASE_REF"
  fi
  set -- "$@" .
  run_report "$@"
  if hit_timeout; then
    add_skip semgrep "timeout"
    return
  fi
  if exec_failed "0 1"; then
    add_skip semgrep "execution failed (exit ${LAST_RC:-0})"
    return
  fi
  _sg_tmp="$WORKDIR/semgrep_lines"
  : >"$_sg_tmp"
  emit_findings "$_sg_report" "$_sg_tmp" --arg tier TIER_B --arg tool semgrep "$SEMGREP_FILTER"
  if [ "$_sg_fallback" -eq 1 ]; then
    # Full-scan fallback: keep only findings that land in (or within HUNK_CTX of)
    # a changed hunk — not merely a changed file (drops legacy hits on untouched
    # lines inside a changed file). Degrades to FILE-level when git can't scope.
    filter_changed_hunks "$_sg_tmp" >>"$TB"
  else
    while IFS= read -r _sg_l || [ -n "$_sg_l" ]; do
      printf '%s\n' "$_sg_l"
    done <"$_sg_tmp" >>"$TB"
  fi
}

run_ruff() {
  set --
  while IFS= read -r _rf_f || [ -n "$_rf_f" ]; do
    [ -n "$_rf_f" ] || continue
    if is_python "$_rf_f"; then set -- "$@" "$_rf_f"; fi
  done <"$CHANGED_LIST"
  if [ "$#" -eq 0 ]; then
    add_skip ruff "not triggered (no matching files)"
    return
  fi
  _rf_report="$WORKDIR/ruff.json"
  run_stdout "$_rf_report" ruff check --output-format json --exit-zero "$@"
  if hit_timeout; then
    add_skip ruff "timeout"
    return
  fi
  if exec_failed "0 1"; then
    add_skip ruff "execution failed (exit ${LAST_RC:-0})"
    return
  fi
  emit_findings "$_rf_report" "$TB" --arg tier TIER_B --arg tool ruff "$RUFF_FILTER"
}

run_shellcheck() {
  set --
  while IFS= read -r _sc_f || [ -n "$_sc_f" ]; do
    [ -n "$_sc_f" ] || continue
    if is_shell "$_sc_f" || has_shell_shebang "$_sc_f"; then set -- "$@" "$_sc_f"; fi
  done <"$CHANGED_LIST"
  if [ "$#" -eq 0 ]; then
    add_skip shellcheck "not triggered (no matching files)"
    return
  fi
  _sc_report="$WORKDIR/shellcheck.json"
  run_stdout "$_sc_report" shellcheck --format json1 "$@"
  if hit_timeout; then
    add_skip shellcheck "timeout"
    return
  fi
  if exec_failed "0 1"; then
    add_skip shellcheck "execution failed (exit ${LAST_RC:-0})"
    return
  fi
  emit_findings "$_sc_report" "$TB" --arg tier TIER_B --arg tool shellcheck "$SHELLCHECK_FILTER"
}

run_actionlint() {
  set --
  while IFS= read -r _al_f || [ -n "$_al_f" ]; do
    [ -n "$_al_f" ] || continue
    if is_workflow "$_al_f"; then set -- "$@" "$_al_f"; fi
  done <"$CHANGED_LIST"
  if [ "$#" -eq 0 ]; then
    add_skip actionlint "not triggered (no matching files)"
    return
  fi
  _al_report="$WORKDIR/actionlint.json"
  run_stdout "$_al_report" actionlint -format '{{json .}}' "$@"
  if hit_timeout; then
    add_skip actionlint "timeout"
    return
  fi
  if exec_failed "0 1"; then
    add_skip actionlint "execution failed (exit ${LAST_RC:-0})"
    return
  fi
  emit_findings "$_al_report" "$TB" --arg tier TIER_B --arg tool actionlint "$ACTIONLINT_FILTER"
}

run_hadolint() {
  set --
  while IFS= read -r _hd_f || [ -n "$_hd_f" ]; do
    [ -n "$_hd_f" ] || continue
    if is_dockerfile "$_hd_f"; then set -- "$@" "$_hd_f"; fi
  done <"$CHANGED_LIST"
  if [ "$#" -eq 0 ]; then
    add_skip hadolint "not triggered (no matching files)"
    return
  fi
  _hd_report="$WORKDIR/hadolint.json"
  run_stdout "$_hd_report" hadolint --format json "$@"
  if hit_timeout; then
    add_skip hadolint "timeout"
    return
  fi
  if exec_failed "0 1"; then
    add_skip hadolint "execution failed (exit ${LAST_RC:-0})"
    return
  fi
  emit_findings "$_hd_report" "$TB" --arg tier TIER_B --arg tool hadolint "$HADOLINT_FILTER"
}

# ---------------------------------------------------------------------------
# docker_scan <tool> — run a MISSING core scanner via its pinned docker image
# (Phase 4). Runs in FILESYSTEM mode (no git-in-container: sidesteps the
# worktree ".git-is-a-file" problem and needs no --baseline-commit), mounts the
# repo read-only at /src, then parses with the SAME per-tool *_FILTER +
# emit_findings the native runner uses, strips the /src mount prefix, and
# applies the same changed-file scoping. Each per-tool case mirrors its native
# runner's skip/timeout/exec-failed handling. Reached only from the dispatch
# elif (tool absent from PATH + opted into RC_STATIC_DOCKER_TOOLS + daemon up).
# ---------------------------------------------------------------------------
docker_scan() {
  _dk_tool="$1"
  _dk_img="$(docker_image_for "$_dk_tool")"
  _dk_raw="$WORKDIR/dk_raw"
  _dk_stripped="$WORKDIR/dk_stripped"
  : >"$_dk_raw"
  : >"$_dk_stripped"
  case "$_dk_tool" in
    gitleaks)
      if ! any_changed; then
        add_skip gitleaks "not triggered (no matching files)"
        return
      fi
      _dk_report="$WORKDIR/gitleaks.json"
      : >"$_dk_report"
      # gitleaks writes its report to a FILE, so $WORKDIR is mounted writable;
      # `dir .` from -w /src reports repo-relative paths (strip is then a no-op).
      run_report docker run --rm --entrypoint gitleaks \
        -v "$REPO_ROOT:/src:ro" -v "$WORKDIR:$WORKDIR" -w /src "$_dk_img" \
        dir -f json -r "$_dk_report" --no-banner .
      if hit_timeout; then
        add_skip gitleaks "timeout"
        return
      fi
      if exec_failed "0 1"; then
        add_skip gitleaks "execution failed (exit ${LAST_RC:-0})"
        return
      fi
      emit_findings "$_dk_report" "$_dk_raw" --arg tier TIER_A --arg tool gitleaks "$GITLEAKS_FILTER"
      strip_src_prefix "$_dk_raw" >"$_dk_stripped"
      filter_changed "$_dk_stripped" >>"$TA"
      ;;
    trufflehog)
      if ! any_changed; then
        add_skip trufflehog "not triggered (no matching files)"
        return
      fi
      _dk_report="$WORKDIR/trufflehog.json"
      # Filesystem mode reports .SourceMetadata.Data.Filesystem.file = /src/… .
      run_stdout "$_dk_report" docker run --rm --entrypoint trufflehog \
        -v "$REPO_ROOT:/src:ro" -w /src "$_dk_img" \
        filesystem /src --results=verified --json
      if hit_timeout; then
        add_skip trufflehog "timeout"
        return
      fi
      # Same network-degrade split as native run_trufflehog: only clean exit is 0.
      if exec_failed "0"; then
        if network_failed; then
          add_skip trufflehog "network-unreachable"
        else
          add_skip trufflehog "execution failed (exit ${LAST_RC:-0})"
        fi
        return
      fi
      _dk_before="$(wc -l <"$TA" 2>/dev/null || echo 0)"
      # Filesystem scan covers UNCHANGED files too — keep only changed files.
      emit_findings "$_dk_report" "$_dk_raw" --arg tier TIER_A --arg tool trufflehog "$TRUFFLEHOG_FILTER"
      strip_src_prefix "$_dk_raw" >"$_dk_stripped"
      filter_changed "$_dk_stripped" >>"$TA"
      _dk_after="$(wc -l <"$TA" 2>/dev/null || echo 0)"
      if [ "$_dk_before" -eq "$_dk_after" ] && network_failed; then
        add_skip trufflehog "network-unreachable"
      fi
      ;;
    semgrep)
      if ! any_changed; then
        add_skip semgrep "not triggered (no matching files)"
        return
      fi
      # Resolve the config ref exactly like native run_semgrep, with one docker
      # narrowing: a repo-owned local ruleset FILE can't be mounted through this
      # light gate, so it (readable or not) falls back to p/default with a note.
      _dk_cfg="$SEMGREP_CONFIG"
      case "$_dk_cfg" in
        auto)
          add_skip semgrep "config 'auto' needs metrics/telemetry (incompatible with --metrics=off) — set semgrep_config to a pack like p/default or a repo-owned ruleset path"
          return
          ;;
        p/* | r/* | http://* | https://*)
          : # registry/remote ref — use as-is
          ;;
        *)
          if [ -f "$_dk_cfg" ]; then
            echo "rc-static-scan: semgrep_config '$_dk_cfg' is a local ruleset; not supported over docker, using p/default" >&2
          else
            echo "rc-static-scan: semgrep_config '$_dk_cfg' not a readable file; using p/default" >&2
          fi
          _dk_cfg="p/default"
          ;;
      esac
      _dk_report="$WORKDIR/semgrep.json"
      # STDOUT JSON; -w /tmp gives semgrep a writable cwd (it errors on read-only).
      # FULL scan (no --baseline-commit) + the changed-hunk post-filter below.
      run_stdout "$_dk_report" docker run --rm --entrypoint semgrep \
        -v "$REPO_ROOT:/src:ro" -w /tmp "$_dk_img" \
        scan --config "$_dk_cfg" --metrics=off --json /src
      if hit_timeout; then
        add_skip semgrep "timeout"
        return
      fi
      if exec_failed "0 1"; then
        add_skip semgrep "execution failed (exit ${LAST_RC:-0})"
        return
      fi
      emit_findings "$_dk_report" "$_dk_raw" --arg tier TIER_B --arg tool semgrep "$SEMGREP_FILTER"
      strip_src_prefix "$_dk_raw" >"$_dk_stripped"
      filter_changed_hunks "$_dk_stripped" >>"$TB"
      ;;
    osv-scanner)
      set --
      while IFS= read -r _dk_f || [ -n "$_dk_f" ]; do
        [ -n "$_dk_f" ] || continue
        if is_lockfile "$_dk_f"; then set -- "$@" --lockfile="$_dk_f"; fi
      done <"$CHANGED_LIST"
      if [ "$#" -eq 0 ]; then
        add_skip osv-scanner "not triggered (no matching files)"
        return
      fi
      _dk_report="$WORKDIR/osv.json"
      # Entrypoint is /osv-scanner (bare `osv-scanner` is not on the image PATH).
      # source.path comes back as /src/<lockfile>; strip restores the repo-
      # relative path we passed — no changed-file filter needed (same as native).
      run_stdout "$_dk_report" docker run --rm --entrypoint /osv-scanner \
        -v "$REPO_ROOT:/src:ro" -w /src "$_dk_img" \
        scan source "$@" --format json
      if hit_timeout; then
        add_skip osv-scanner "timeout"
        return
      fi
      if exec_failed "0 1"; then
        add_skip osv-scanner "execution failed (exit ${LAST_RC:-0})"
        return
      fi
      emit_findings "$_dk_report" "$_dk_raw" --arg tier TIER_A --arg tool osv-scanner "$OSV_FILTER"
      strip_src_prefix "$_dk_raw" >>"$TA"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Dispatch — iterate the canonical 8 in a fixed order so every tool is
# accounted for (configured? => probe => trigger => run). A skip at any gate
# records a reason; the batch never stops early.
# ---------------------------------------------------------------------------

for _tool in gitleaks trufflehog osv-scanner semgrep ruff shellcheck actionlint hadolint; do
  if ! tool_configured "$_tool"; then
    add_skip "$_tool" "disabled"
    continue
  fi
  # semgrep_config=off disables semgrep regardless of install/trigger.
  if [ "$_tool" = "semgrep" ] && [ "$SEMGREP_CONFIG" = "off" ]; then
    add_skip semgrep "semgrep off"
    continue
  fi
  # A natively-installed tool ALWAYS wins — the docker path is only ever a
  # fallback for a tool that is MISSING from PATH and opted into the per-run
  # RC_STATIC_DOCKER_TOOLS gate (with the daemon up). A lint tool, or any tool
  # not opted in / no daemon, stays "not installed" exactly as before.
  if command -v "$_tool" >/dev/null 2>&1; then
    case "$_tool" in
      gitleaks) run_gitleaks ;;
      trufflehog) run_trufflehog ;;
      osv-scanner) run_osv ;;
      semgrep) run_semgrep ;;
      ruff) run_ruff ;;
      shellcheck) run_shellcheck ;;
      actionlint) run_actionlint ;;
      hadolint) run_hadolint ;;
    esac
  elif tool_docker_enabled "$_tool"; then
    docker_scan "$_tool"
  else
    add_skip "$_tool" "not installed"
  fi
done

# ---------------------------------------------------------------------------
# Emit the output contract: TIER_A block, TIER_B block, then SKIPPED lines.
# ---------------------------------------------------------------------------

emit_file() {
  [ -s "$1" ] || return 0
  while IFS= read -r _em_l || [ -n "$_em_l" ]; do
    printf '%s\n' "$_em_l"
  done <"$1"
}

echo "TIER_A"
emit_file "$TA"
echo "TIER_B"
emit_file "$TB"
emit_file "$SK"

exit 0
