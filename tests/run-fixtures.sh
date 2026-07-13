#!/usr/bin/env bash
# ============================================================================
# tests/run-fixtures.sh — Tier-2 FIXTURE ASSERTION HARNESS
# ============================================================================
#
# TIER: 2 — semi-deterministic, LLM-mediated. LOCAL / ON-DEMAND ONLY.
#
# *** NEVER wire this into CI. *** Unlike the Tier-1 bats suites under
# tests/unit/ (fast, deterministic, no LLM calls, safe for every push), this
# script drives the REAL `/review-council:run` skill end-to-end against the
# small fixture repos under tests/fixtures/<name>/repo/. That means it:
#   - spends real reviewer tokens/API cost (Claude + whichever of
#     Codex / Antigravity-Gemini / Perplexity happen to be installed or
#     configured on this machine),
#   - can take minutes per fixture (agy's cold start alone can legitimately
#     take several minutes — see rules/providers.md),
#   - is mildly flaky by construction: wording is genuinely LLM-mediated, so
#     the assertions below check for the STABLE ARTIFACT MARKERS the shared
#     spec commits to — a routing table, a judge ledger, the literal
#     `Suppressions applied: N` line, badges (`[cross-reviewed]` /
#     `[1 reviewer · unverified]` / `[unverified]`), the echoed
#     `key=value` config lines `rc-config.sh` emits, and
#     `stopped at budget: <n>s` — NOT exact finding text, which will vary
#     run to run. See .superpowers/sdd/pr1c-shared-spec.md for the contract
#     these markers come from.
#
# WHAT A "PASS" MEANS — and doesn't: a PASS means the pipeline STAGE ran and
# emitted its documented artifact shape. It is NOT a substitute for a human
# reading the actual report, and it does NOT grade review QUALITY (which
# findings, exact phrasing, whether the judgement was "right"). Several
# checks below are explicitly marked "soft / best-effort" for exactly this
# reason — they inform, but never fail, a fixture's PASS/FAIL verdict.
#
# PREREQUISITE — the INSTALLED plugin vs. this worktree (see the
# `installed-plugin-vs-worktree` project memory): `/review-council:run`
# executes the plugin version installed under
# `~/.claude/plugins/cache/review-council-marketplace/review-council/<ver>/`,
# NOT this checkout. Editing files in this worktree has NO effect on what
# this script exercises until the installed plugin is repointed at (or
# updated from) this worktree — e.g. via `/plugin marketplace` pointed at a
# local path, or by copying/symlinking this worktree over the installed
# plugin dir. This script does not do that for you; it only drives whatever
# plugin is currently installed, so double-check that first or you will
# silently test stale code.
#
# HOW TO RUN:
#   bash tests/run-fixtures.sh                    # all 5 fixtures
#   bash tests/run-fixtures.sh crossfile budget    # a subset, by name
#
#   (No `make test-eval` target exists in this repo yet — if one is added
#   later it should just be a thin alias for the command above.)
#
# REQUIRES: the `claude` CLI on PATH (Claude Code itself — this script uses
# `claude -p` to drive one non-interactive turn per fixture). Override the
# binary with `CLAUDE_BIN=/path/to/claude`.
#
# ALSO REQUIRES (for the `config` fixture only): `yq` (mikefarah v4, the Go
# implementation — NOT the Python kislyuk/yq) on PATH, or `RC_YQ=/path/to/yq`.
# `rc-config.sh` parses `.review-council/config*.yml` with that exact `yq`;
# without it, it gracefully falls back to defaults (per its own documented
# degrade path) and the `config` fixture's `settings.min_reviewers=3` /
# `lens.security.providers=google` / `replaces_dedicated=true` assertions
# cannot hold — that fixture SKIPS (warns, doesn't hard-fail) when `yq` isn't
# detected, mirroring the plugin's own graceful-degradation stance. Other
# useful env overrides:
#   RC_FIXTURE_TIMEOUT        per-fixture wall-clock cap in seconds
#                             (default 900 — generous for an agy cold start
#                             plus a full council + refutation pass).
#   RC_FIXTURE_MAX_BUDGET_USD if set, passed through as `--max-budget-usd`
#                             (a $-cost safety net; unset = no cap).
#   RC_FIXTURE_OUT_DIR        where raw per-fixture output is saved
#                             (default: a fresh mktemp -d).
#
# SAFETY NOTE: this script runs `claude -p` with `--permission-mode
# bypassPermissions` (no per-tool prompts) against the small, inert fixture
# repos in this directory. Do not point it at anything other than these
# fixtures, and do not run it unattended against untrusted input.
#
# This script authors the harness against the shared spec's ARTIFACT
# CONTRACT so it is correct-by-construction ahead of the pipeline landing.
# A full "run to green" requires the pipeline changes from this same PR
# series (refutation pass / judge / severity-first report) to actually be
# live in the INSTALLED plugin — that is a separate local validation step,
# not something authoring this script performs on its own.
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
FIXTURE_TIMEOUT="${RC_FIXTURE_TIMEOUT:-900}"
OUT_DIR="${RC_FIXTURE_OUT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/rc-fixtures.XXXXXX")}"

ALL_FIXTURES="crossfile suppression config solo budget"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FIXTURE_RESULTS=()

log() { printf '%s\n' "$*"; }

need_claude() {
  if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    log "ERROR: '$CLAUDE_BIN' (Claude Code CLI) not found on PATH."
    log "Install/verify Claude Code, or set CLAUDE_BIN=/path/to/claude."
    exit 2
  fi
}

# has_mikefarah_yq: mirrors the exact detection `rc-config.sh` uses itself —
# a `yq` binary must be present AND its `--version` output must contain
# "mikefarah" (the Go implementation this project's config parsing depends
# on; the Python kislyuk/yq is treated the same as yq-absent). Respects
# RC_YQ, same as rc-config.sh.
has_mikefarah_yq() {
  local yq_bin="${RC_YQ:-yq}" ver
  command -v "$yq_bin" >/dev/null 2>&1 || return 1
  ver="$("$yq_bin" --version 2>/dev/null)" || return 1
  printf '%s' "$ver" | grep -q 'mikefarah'
}

fixture_header() {
  log ""
  log "=================================================================="
  log "Fixture: $1"
  log "=================================================================="
}

fixture_result() {
  local name="$1" fail="$2"
  if [ "$fail" -eq 0 ]; then
    log "RESULT: PASS  ($name)"
    FIXTURE_RESULTS+=("PASS  $name")
    TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    log "RESULT: FAIL  ($name)"
    FIXTURE_RESULTS+=("FAIL  $name")
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
}

# fixture_skip <name> <reason>: for prerequisite gaps (e.g. missing `yq`)
# that make a fixture's premise untestable — warns, does NOT fail the run.
fixture_skip() {
  local name="$1" reason="$2"
  log "RESULT: SKIP  ($name) — $reason"
  FIXTURE_RESULTS+=("SKIP  $name")
  TOTAL_SKIP=$((TOTAL_SKIP + 1))
}

# invoke_review <fixture-repo-dir> <target-relpath> <out-file>
#
# Runs the installed review-council plugin (via the Claude Code CLI, one
# non-interactive turn) with CWD set to the fixture repo, so
# `.review-council/config.yml` / `config.local.yml` / `learnings.md` (Step 0
# / Step 0.5 of skills/run/SKILL.md) resolve relative to it, exactly like a
# real target repo. Output (stdout+stderr) is captured to <out-file>.
invoke_review() {
  local repo="$1" target="$2" out="$3"
  local to

  to="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"

  local -a extra=()
  if [ -n "${RC_FIXTURE_MAX_BUDGET_USD:-}" ]; then
    extra+=(--max-budget-usd "$RC_FIXTURE_MAX_BUDGET_USD")
  fi

  local -a cmd=(
    "$CLAUDE_BIN" -p "/review-council:run $target"
    --permission-mode bypassPermissions
    --no-session-persistence
    "${extra[@]}"
  )

  if [ -n "$to" ]; then
    ( cd "$repo" && "$to" "$FIXTURE_TIMEOUT" "${cmd[@]}" ) >"$out" 2>&1
  else
    log "  (no timeout/gtimeout on PATH — running unbounded; consider installing coreutils)"
    ( cd "$repo" && "${cmd[@]}" ) >"$out" 2>&1
  fi
}

# check <label> <out-file> <ere-pattern> <hard|soft>
#
# hard: failure to match fails the fixture. soft: failure to match only
# prints a warning (content-level assertions can't be pinned with certainty
# against LLM-mediated wording — see the header note above).
check() {
  local label="$1" out="$2" pat="$3" kind="$4"
  if grep -Eqi -- "$pat" "$out"; then
    log "  [ok]   ($kind) $label"
    return 0
  fi
  if [ "$kind" = hard ]; then
    log "  [FAIL] (hard) $label"
    log "         pattern: $pat"
    return 1
  fi
  log "  [warn] (soft) $label — not found (best-effort; wording is LLM-mediated)"
  log "         pattern: $pat"
  return 0
}

# section_has <out-file> <heading-ere> <content-ere>
#
# Best-effort "is <content> mentioned near a <heading> section" check: grabs
# the 40 lines following the first line matching <heading> and greps
# <content> within them. This is a heuristic, not a real markdown-section
# parser — good enough for soft/best-effort assertions, not for hard ones.
section_has() {
  local out="$1" heading="$2" content="$3"
  grep -A 40 -Ei -- "$heading" "$out" 2>/dev/null | grep -Eqi -- "$content"
}

# ----------------------------------------------------------------------------
# Fixture: crossfile
# ----------------------------------------------------------------------------
run_fixture_crossfile() {
  local name=crossfile repo out fail=0
  repo="$FIXTURES_DIR/$name/repo"
  out="$OUT_DIR/$name.out"
  fixture_header "$name"
  invoke_review "$repo" "src/pricing.py" "$out"

  check "Refutation routing table printed (Step 4)" "$out" \
    'Refutation routing' hard || fail=1
  check "judge ledger printed (fingerprint/verdict row shape)" "$out" \
    '(fingerprint.*verdict|verdict.*fingerprint)' hard || fail=1

  if section_has "$out" 'critical' '(discount_pct|pricing\.py)'; then
    log "  [warn] (soft) decoy discount_pct/pricing.py appears to SURVIVE into Critical — expected REFUTED + dropped"
  else
    log "  [ok]   (soft) decoy discount_pct/pricing.py not present in the Critical section"
  fi
  if section_has "$out" 'critical' '(checkout\.py|render_receipt|PricingResult|calculate_total)'; then
    log "  [ok]   (soft) real cross-file break (checkout.py/render_receipt) found in Critical"
  else
    log "  [warn] (soft) real cross-file break NOT found in Critical — expected it to land there"
  fi

  fixture_result "$name" "$fail"
}

# ----------------------------------------------------------------------------
# Fixture: suppression
# ----------------------------------------------------------------------------
run_fixture_suppression() {
  local name=suppression repo out fail=0
  repo="$FIXTURES_DIR/$name/repo"
  out="$OUT_DIR/$name.out"
  fixture_header "$name"
  invoke_review "$repo" "src/adapters/legacy_adapter.py" "$out"

  check "Suppressions applied: 1" "$out" \
    'Suppressions applied:[[:space:]]*1' hard || fail=1

  if section_has "$out" '(critical|important|suggestion)' '(legacy_adapter|normalize_payload|unchecked-any)'; then
    log "  [warn] (soft) suppressed finding appears to SURVIVE into the report body"
  else
    log "  [ok]   (soft) suppressed finding not found surviving into the report body"
  fi

  fixture_result "$name" "$fail"
}

# ----------------------------------------------------------------------------
# Fixture: config
# ----------------------------------------------------------------------------
run_fixture_config() {
  local name=config repo out fail=0
  repo="$FIXTURES_DIR/$name/repo"
  out="$OUT_DIR/$name.out"
  fixture_header "$name"

  if ! has_mikefarah_yq; then
    log "  [warn] mikefarah yq v4 not found on PATH (or RC_YQ) — rc-config.sh"
    log "         gracefully falls back to defaults without it, so this"
    log "         fixture's config.yml/config.local.yml assertions cannot"
    log "         hold. Install yq (https://github.com/mikefarah/yq) or set"
    log "         RC_YQ=/path/to/yq. SKIPPING rather than hard-failing."
    fixture_skip "$name" "yq (mikefarah v4) not found"
    return
  fi

  invoke_review "$repo" "src/example.py" "$out"

  check "settings.verify=true (config.local wins over config.yml)" "$out" \
    'settings\.verify=true' hard || fail=1
  check "settings.min_reviewers=3 (from config.yml, not the default 2)" "$out" \
    'settings\.min_reviewers=3' hard || fail=1
  check "lens.security.providers=google (the pin)" "$out" \
    'lens\.security\.providers=google' hard || fail=1
  check "lens.security.replaces_dedicated=true (pin flips the flag)" "$out" \
    'lens\.security\.replaces_dedicated=true' hard || fail=1

  fixture_result "$name" "$fail"
}

# ----------------------------------------------------------------------------
# Fixture: solo
# ----------------------------------------------------------------------------
run_fixture_solo() {
  local name=solo repo out fail=0
  repo="$FIXTURES_DIR/$name/repo"
  out="$OUT_DIR/$name.out"
  fixture_header "$name"
  invoke_review "$repo" "src/example.py" "$out"

  check "single-reviewer mode announced" "$out" \
    'single-reviewer mode' hard || fail=1
  check "an unverified tag is present ([unverified] / [single-reviewer . unverified] / [1 reviewer . unverified])" "$out" \
    '(\[unverified\]|\[single-reviewer[^]]*unverified\]|\[1 reviewer[^]]*unverified\])' hard || fail=1

  if section_has "$out" 'Refutation routing' '.'; then
    log "  [warn] (soft) a refutation routing table appears present — refutation may not have been fully SKIPPED"
  else
    log "  [ok]   (soft) no refutation routing table found — consistent with refutation being skipped entirely"
  fi

  fixture_result "$name" "$fail"
}

# ----------------------------------------------------------------------------
# Fixture: budget
# ----------------------------------------------------------------------------
run_fixture_budget() {
  local name=budget repo out fail=0
  repo="$FIXTURES_DIR/$name/repo"
  out="$OUT_DIR/$name.out"
  fixture_header "$name"
  invoke_review "$repo" "src/example.py" "$out"

  check "stopped at budget: <n>s marker present" "$out" \
    'stopped at budget:[[:space:]]*[0-9]+s' hard || fail=1
  check "final report still produced (graceful degrade, not an abort)" "$out" \
    'review council report' hard || fail=1

  if section_has "$out" '(finding|critical|important|suggestion)' '\[unverified\]'; then
    log "  [ok]   (soft) [unverified] tag present on findings"
  else
    log "  [warn] (soft) [unverified] tag not found — expected under a budget degrade"
  fi

  fixture_result "$name" "$fail"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  need_claude

  local requested="$*"
  if [ -z "$requested" ]; then
    requested="$ALL_FIXTURES"
  fi

  log "review-council Tier-2 fixture harness — LOCAL/on-demand only, NEVER CI."
  log "Raw per-fixture output will be saved under: $OUT_DIR"

  for f in $requested; do
    case "$f" in
      crossfile)   run_fixture_crossfile ;;
      suppression) run_fixture_suppression ;;
      config)      run_fixture_config ;;
      solo)        run_fixture_solo ;;
      budget)      run_fixture_budget ;;
      *)
        log "Unknown fixture: '$f' (known fixtures: $ALL_FIXTURES)"
        exit 2
        ;;
    esac
  done

  log ""
  log "=================================================================="
  log "SUMMARY"
  log "=================================================================="
  for r in "${FIXTURE_RESULTS[@]}"; do
    log "  $r"
  done
  log ""
  log "Hard-check results: $TOTAL_PASS fixture(s) PASS, $TOTAL_FAIL fixture(s) FAIL, $TOTAL_SKIP fixture(s) SKIP."
  log "Raw output saved under: $OUT_DIR"

  [ "$TOTAL_FAIL" -eq 0 ]
}

main "$@"
