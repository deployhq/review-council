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
#   RC_SEMGREP_CONFIG   str, default auto. "off" => semgrep skipped; "auto" =>
#                       --config auto; any other value => a repo-owned ruleset
#                       path passed as --config <path>.
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

SEMGREP_CONFIG="${RC_SEMGREP_CONFIG:-auto}"

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
OSV_FILTER="$SAN"'
  .results[]? as $r | ($r.packages[]?) as $p | ($p.vulnerabilities[]?)
  | [$tier,$tool,
     ((.database_specific.severity // ((.severity // [])[0].score) // "UNKNOWN")|san),
     (($r.source.path // "")|san),"",
     ("osv:"+((.id//"vuln")|ascii_downcase|san)),
     (((.id//"CVE")+" "+(.summary // .details // "known vulnerability"))|san)]
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

# filter_changed <lines-file>: emit only the normalized lines whose file field
# is a changed file — the changed-hunk post-filter for semgrep's full-scan
# fallback (when --baseline-commit can't be used). Prints kept lines to stdout.
filter_changed() {
  while IFS='|' read -r _flt_tier _flt_tool _flt_sev _flt_file _flt_line _flt_rule _flt_msg || [ -n "${_flt_tier:-}" ]; do
    [ -n "${_flt_tier:-}" ] || continue
    if file_in_changed "$_flt_file"; then
      printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$_flt_tier" "$_flt_tool" "$_flt_sev" "$_flt_file" "$_flt_line" "$_flt_rule" "$_flt_msg"
    fi
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
  if [ "$_gl_modern" -eq 1 ]; then
    set -- gitleaks git
  else
    set -- gitleaks detect --source .
  fi
  if [ -n "$BASE_REF" ]; then set -- "$@" --log-opts="$BASE_REF..$HEAD_REF"; fi
  set -- "$@" -f json -r "$_gl_report"
  if [ -f .gitleaks.toml ]; then set -- "$@" -c .gitleaks.toml; fi
  if [ "$_gl_modern" -eq 1 ]; then set -- "$@" .; fi
  run_report "$@"
  if hit_timeout; then
    add_skip gitleaks "timeout"
    return
  fi
  emit_findings "$_gl_report" "$TA" --arg tier TIER_A --arg tool gitleaks "$GITLEAKS_FILTER"
}

run_trufflehog() {
  if ! any_changed; then
    add_skip trufflehog "not triggered (no matching files)"
    return
  fi
  _th_report="$WORKDIR/trufflehog.json"
  set -- trufflehog git "file://." --results=verified --json
  if [ -n "$BASE_REF" ]; then set -- "$@" --since-commit "$BASE_REF"; fi
  if [ -n "$HEAD_REF" ]; then set -- "$@" --branch "$HEAD_REF"; fi
  run_stdout "$_th_report" "$@"
  if hit_timeout; then
    add_skip trufflehog "timeout"
    return
  fi
  _th_before="$(wc -l <"$TA" 2>/dev/null || echo 0)"
  emit_findings "$_th_report" "$TA" --arg tier TIER_A --arg tool trufflehog "$TRUFFLEHOG_FILTER"
  _th_after="$(wc -l <"$TA" 2>/dev/null || echo 0)"
  # Graceful network degrade (Risk #3): 0 verified findings + a network error in
  # the tool's stderr => "ran, 0 findings" + a note. Never errors the batch.
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
  emit_findings "$_osv_report" "$TA" --arg tier TIER_A --arg tool osv-scanner "$OSV_FILTER"
}

run_semgrep() {
  if ! any_changed; then
    add_skip semgrep "not triggered (no matching files)"
    return
  fi
  _sg_cfg="$SEMGREP_CONFIG"
  # A non-auto value is a repo-owned ruleset path; if it isn't a readable file,
  # fall back to auto with a note (never fetch/execute an untrusted path).
  if [ "$_sg_cfg" != "auto" ]; then
    if [ ! -f "$_sg_cfg" ]; then
      echo "rc-static-scan: semgrep_config '$_sg_cfg' not a readable file; using auto" >&2
      _sg_cfg="auto"
    fi
  fi
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
  _sg_tmp="$WORKDIR/semgrep_lines"
  : >"$_sg_tmp"
  emit_findings "$_sg_report" "$_sg_tmp" --arg tier TIER_B --arg tool semgrep "$SEMGREP_FILTER"
  if [ "$_sg_fallback" -eq 1 ]; then
    # Full-scan fallback: keep only findings that land in a changed file.
    filter_changed "$_sg_tmp" >>"$TB"
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
  emit_findings "$_hd_report" "$TB" --arg tier TIER_B --arg tool hadolint "$HADOLINT_FILTER"
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
  if ! command -v "$_tool" >/dev/null 2>&1; then
    add_skip "$_tool" "not installed"
    continue
  fi
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
