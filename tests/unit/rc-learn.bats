#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for scripts/rc-learn.sh — the deterministic learnings writer.
#
# Each test targets a per-test temp learnings file (RC_LEARNINGS_FILE) with a
# fixed date stamp (RC_LEARN_DATE) so the appended bytes are reproducible. The
# script writes diagnostics/notes to stderr and (on success) nothing to stdout.
#
# Run: bats tests/unit/rc-learn.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/rc-learn.sh"

# Canonical §3.6 lines the writer must emit verbatim (em-dashes and the
# three-space gap before each parenthetical included).
HDR_TITLE='# Review Council — Learnings   (committed; team-shared; edit freely)'
HDR_CONVENTIONS='## Conventions   (injected once into the Step-2 baseline context package)'
HDR_SUPPRESSIONS='## Suppressions   (known false positives — judge down-weights/skips matches by fingerprint)'

setup() {
  export RC_LEARNINGS_FILE="$BATS_TEST_TMPDIR/learnings.md"
  export RC_LEARN_DATE="2026-07-14"
}

# --- assertion helpers ------------------------------------------------------

# file_has <exact-line>: the target file contains this exact line. `--` guards
# against lines beginning with `-` being read as grep options.
file_has() {
  grep -qxF -- "$1" "$RC_LEARNINGS_FILE" || {
    echo "expected line: $1"
    echo "--- actual file ---"
    cat "$RC_LEARNINGS_FILE"
    return 1
  }
}

# count_conventions / count_suppressions: bullets under each section.
count_conventions() {
  awk '/^## / { c = ($0 ~ /^## Conventions/) } c && /^- / { n++ } END { print n + 0 }' "$RC_LEARNINGS_FILE"
}
count_suppressions() {
  awk '/^## / { s = ($0 ~ /^## Suppressions/) } s && /^- fingerprint:/ { n++ } END { print n + 0 }' "$RC_LEARNINGS_FILE"
}

# --- create-from-absent -----------------------------------------------------

@test "create-from-absent: canonical header + both section headers" {
  [ ! -e "$RC_LEARNINGS_FILE" ]
  # add-suppression leaves Conventions empty, so the skeleton's line positions
  # are preserved intact: title@1, Conventions@3, Suppressions@5.
  run --separate-stderr "$SCRIPT" add-suppression "f::g::h" "reason"
  [ "$status" -eq 0 ]
  [ -f "$RC_LEARNINGS_FILE" ]
  file_has "$HDR_TITLE"
  file_has "$HDR_CONVENTIONS"
  file_has "$HDR_SUPPRESSIONS"
  # canonical skeleton: title, blank, Conventions, blank, Suppressions
  run awk '/^# Review Council/ { t=NR } /^## Conventions/ { c=NR } /^## Suppressions/ { s=NR } END { print t, c, s }' "$RC_LEARNINGS_FILE"
  [ "$output" = "1 3 5" ]
}

@test "create-from-absent: creates parent directories" {
  export RC_LEARNINGS_FILE="$BATS_TEST_TMPDIR/nested/deeper/learnings.md"
  run --separate-stderr "$SCRIPT" add-convention "Some rule"
  [ "$status" -eq 0 ]
  [ -f "$RC_LEARNINGS_FILE" ]
  file_has "$HDR_TITLE"
}

# --- append-convention ------------------------------------------------------

@test "append-convention: bullet lands under Conventions" {
  run --separate-stderr "$SCRIPT" add-convention "Migrations are auto-generated; do not flag missing down-migrations."
  [ "$status" -eq 0 ]
  file_has "- Migrations are auto-generated; do not flag missing down-migrations."
  [ "$(count_conventions)" -eq 1 ]
  [ "$(count_suppressions)" -eq 0 ]
}

@test "append-convention: two distinct conventions both under Conventions" {
  "$SCRIPT" add-convention "First rule"
  "$SCRIPT" add-convention "Second rule"
  file_has "- First rule"
  file_has "- Second rule"
  [ "$(count_conventions)" -eq 2 ]
  # a convention must not leak into the Suppressions section
  [ "$(count_suppressions)" -eq 0 ]
}

# --- append-suppression -----------------------------------------------------

@test "append-suppression: full §3.6 line with fingerprint | reason | added" {
  run --separate-stderr "$SCRIPT" add-suppression "src/adapters/*::*::unchecked-any" "intentional, see ADR-012"
  [ "$status" -eq 0 ]
  file_has "- fingerprint: src/adapters/*::*::unchecked-any | reason: intentional, see ADR-012 | added: 2026-07-14"
  [ "$(count_suppressions)" -eq 1 ]
  [ "$(count_conventions)" -eq 0 ]
}

@test "mixed: convention then suppression keep their sections; order preserved" {
  "$SCRIPT" add-suppression "a::b::c" "reason one"
  "$SCRIPT" add-convention "a rule here"
  "$SCRIPT" add-suppression "d::e::f" "reason two"
  [ "$(count_conventions)" -eq 1 ]
  [ "$(count_suppressions)" -eq 2 ]
  file_has "- a rule here"
  file_has "- fingerprint: a::b::c | reason: reason one | added: 2026-07-14"
  file_has "- fingerprint: d::e::f | reason: reason two | added: 2026-07-14"
  # the convention sits above the Suppressions header
  run awk '/^## Suppressions/ { print NR; exit } /^- a rule here/ { print "conv@" NR }' "$RC_LEARNINGS_FILE"
  [ "${lines[0]}" = "conv@4" ]
}

# --- idempotency ------------------------------------------------------------

@test "idempotent-suppression: same fingerprint is a no-op (reason NOT overwritten)" {
  "$SCRIPT" add-suppression "x::y::z" "original reason"
  run --separate-stderr "$SCRIPT" add-suppression "x::y::z" "a totally different reason"
  [ "$status" -eq 0 ]
  [ "$(count_suppressions)" -eq 1 ]
  # the original entry is preserved verbatim; the second reason is ignored
  file_has "- fingerprint: x::y::z | reason: original reason | added: 2026-07-14"
  run grep -F "a totally different reason" "$RC_LEARNINGS_FILE"
  [ "$status" -ne 0 ]
  # a note explains the no-op
  run --separate-stderr "$SCRIPT" add-suppression "x::y::z" "yet another"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"already present"* ]]
}

@test "idempotent-suppression: different date override does not duplicate" {
  RC_LEARN_DATE="2026-07-14" "$SCRIPT" add-suppression "p::q::r" "reason"
  RC_LEARN_DATE="2030-01-01" "$SCRIPT" add-suppression "p::q::r" "reason"
  [ "$(count_suppressions)" -eq 1 ]
  file_has "- fingerprint: p::q::r | reason: reason | added: 2026-07-14"
}

@test "idempotent-convention: normalized text (whitespace + case) is a no-op" {
  "$SCRIPT" add-convention "Migrations are auto-generated; do not flag missing down-migrations."
  run --separate-stderr "$SCRIPT" add-convention "migrations   ARE auto-generated; do NOT flag missing down-migrations."
  [ "$status" -eq 0 ]
  [ "$(count_conventions)" -eq 1 ]
  # the original casing/spacing is what remains stored
  file_has "- Migrations are auto-generated; do not flag missing down-migrations."
  [[ "$stderr" == *"already present"* ]]
}

@test "idempotent-convention: genuinely different text is appended" {
  "$SCRIPT" add-convention "Rule about migrations"
  "$SCRIPT" add-convention "Rule about logging"
  [ "$(count_conventions)" -eq 2 ]
}

# --- overrides --------------------------------------------------------------

@test "path override: RC_LEARNINGS_FILE targets an arbitrary file" {
  export RC_LEARNINGS_FILE="$BATS_TEST_TMPDIR/custom-name.md"
  run --separate-stderr "$SCRIPT" add-convention "Some rule"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/custom-name.md" ]
  file_has "- Some rule"
}

@test "date override: RC_LEARN_DATE stamps the suppression" {
  RC_LEARN_DATE="2001-02-03" run --separate-stderr "$SCRIPT" add-suppression "f::g::h" "reason"
  [ "$status" -eq 0 ]
  file_has "- fingerprint: f::g::h | reason: reason | added: 2001-02-03"
}

@test "date override: default falls back to date +%F when RC_LEARN_DATE unset" {
  unset RC_LEARN_DATE
  run --separate-stderr "$SCRIPT" add-suppression "i::j::k" "reason"
  [ "$status" -eq 0 ]
  # the appended line carries a YYYY-MM-DD stamp
  run grep -qE '^- fingerprint: i::j::k \| reason: reason \| added: [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$RC_LEARNINGS_FILE"
  [ "$status" -eq 0 ]
}

# --- input validation -------------------------------------------------------

@test "validation: no arguments prints usage, exit 2" {
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage:"* ]]
}

@test "validation: unknown command exits 2" {
  run --separate-stderr "$SCRIPT" frobnicate x
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown command"* ]]
}

@test "validation: add-suppression wrong arg count exits 2" {
  run --separate-stderr "$SCRIPT" add-suppression only-one-arg
  [ "$status" -eq 2 ]
  [ ! -e "$RC_LEARNINGS_FILE" ]
}

@test "validation: add-convention wrong arg count exits 2" {
  run --separate-stderr "$SCRIPT" add-convention one two
  [ "$status" -eq 2 ]
  [ ! -e "$RC_LEARNINGS_FILE" ]
}

@test "validation: empty fingerprint exits 2, no file created" {
  run --separate-stderr "$SCRIPT" add-suppression "   " "reason"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"fingerprint is empty"* ]]
  [ ! -e "$RC_LEARNINGS_FILE" ]
}

@test "validation: empty reason exits 2" {
  run --separate-stderr "$SCRIPT" add-suppression "f::g::h" "   "
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"reason is empty"* ]]
}

@test "validation: empty convention text exits 2" {
  run --separate-stderr "$SCRIPT" add-convention "   "
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"text is empty"* ]]
}

@test "validation: pipe in fingerprint rejected (delimiter safety)" {
  run --separate-stderr "$SCRIPT" add-suppression "a|b" "reason"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"may not contain"* ]]
}

@test "validation: pipe in reason rejected (delimiter safety)" {
  run --separate-stderr "$SCRIPT" add-suppression "f::g::h" "before | after"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"may not contain"* ]]
}

@test "validation: control char (newline) in argument rejected" {
  nl="$(printf 'a\nb')"
  run --separate-stderr "$SCRIPT" add-suppression "f::g::h" "$nl"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"control character"* ]]
  [ ! -e "$RC_LEARNINGS_FILE" ]
}

@test "validation: control char (tab) in convention rejected" {
  tabbed="$(printf 'a\tb')"
  run --separate-stderr "$SCRIPT" add-convention "$tabbed"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"control character"* ]]
}

@test "validation: malformed RC_LEARN_DATE rejected, no write" {
  export RC_LEARN_DATE="2026/07/14"
  run --separate-stderr "$SCRIPT" add-suppression "f::g::h" "reason"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"invalid date"* ]]
  [ ! -e "$RC_LEARNINGS_FILE" ]
}
