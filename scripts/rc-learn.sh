#!/usr/bin/env sh
# rc-learn.sh — deterministic writer for the Review Council learnings file.
#
# Appends a single, well-formed entry to `.review-council/learnings.md` under the
# right section, in the exact §3.6 format. The Step-7 capture gate (skills/run/
# SKILL.md) elicits the human-confirmed decision and then calls this helper — the
# helper performs ONLY the file write. No LLM, no net, no interactivity.
#
# The write side of the learning loop: what this script appends, the Step-0.5
# recall later reads (Conventions → Step-2 baseline package; Suppressions → the
# Step-5 judge, matched by the judge's canonical fingerprint).
#
# Usage:
#   rc-learn.sh add-suppression <fingerprint> <reason>
#   rc-learn.sh add-convention  <text>
#
# Env overrides:
#   RC_LEARNINGS_FILE  target file (default: .review-council/learnings.md).
#   RC_LEARN_DATE      the `added:` stamp for suppressions (default: `date +%F`).
#                      Must be YYYY-MM-DD; an invalid override is an error.
#
# Behavior:
#   - Creates the file with the canonical §3.6 header + BOTH section headers if it
#     does not exist (parent dirs created as needed).
#   - add-suppression appends `- fingerprint: <fp> | reason: <reason> | added: <date>`
#     at the end of the Suppressions section.
#   - add-convention appends `- <text>` at the end of the Conventions section.
#   - Idempotent: a suppression whose fingerprint already exists is a no-op; a
#     convention whose normalized (trim + collapse-whitespace + lowercase) text
#     already exists is a no-op. Both print a stderr note and exit 0.
#   - Validates inputs: control-char-free; non-empty fingerprint/reason/text; a
#     suppression fingerprint/reason may not contain `|` (the field delimiter).
#
# Exit: 0 = appended or idempotent no-op; 2 = usage / validation error.

set -eu

# ---------------------------------------------------------------------------
# Inputs & house helpers
# ---------------------------------------------------------------------------

LEARNINGS_FILE="${RC_LEARNINGS_FILE:-.review-council/learnings.md}"

# Canonical §3.6 lines (reproduced verbatim, including the em-dashes and the
# three-space gap before each parenthetical). Section-header matching keys off
# the stable `## Conventions` / `## Suppressions` prefixes, so a hand-edited
# parenthetical does not break appends.
HDR_TITLE='# Review Council — Learnings   (committed; team-shared; edit freely)'
HDR_CONVENTIONS='## Conventions   (injected once into the Step-2 baseline context package)'
HDR_SUPPRESSIONS='## Suppressions   (known false positives — judge down-weights/skips matches by fingerprint)'

usage() {
  cat >&2 <<'EOF'
Usage:
  rc-learn.sh add-suppression <fingerprint> <reason>
  rc-learn.sh add-convention  <text>
EOF
  exit 2
}

# die <message>: one stderr line, exit 2 (usage/validation error).
die() {
  echo "rc-learn: $1" >&2
  exit 2
}

# has_ctrl <val>: true (0) if the value contains a control character (newline,
# CR, tab, …). Security guard — a control char could inject a second markdown
# line / break the `|`-delimited suppression line. Same pattern as rc-config.sh.
has_ctrl() {
  case "$1" in
    *[[:cntrl:]]*) return 0 ;;
    *) return 1 ;;
  esac
}

# trim <val>: strip leading/trailing whitespace; echoes the result.
trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# File creation
# ---------------------------------------------------------------------------

# ensure_file: materialize the canonical §3.6 skeleton if the target is absent.
ensure_file() {
  [ -f "$LEARNINGS_FILE" ] && return 0
  _ef_dir="$(dirname "$LEARNINGS_FILE")"
  [ -d "$_ef_dir" ] || mkdir -p "$_ef_dir"
  {
    printf '%s\n' "$HDR_TITLE"
    printf '\n'
    printf '%s\n' "$HDR_CONVENTIONS"
    printf '\n'
    printf '%s\n' "$HDR_SUPPRESSIONS"
  } >"$LEARNINGS_FILE"
}

# ---------------------------------------------------------------------------
# Section-aware append (awk)
#
# append_bullet <section-prefix> <bullet-line> <canonical-header>: insert the
# bullet as the LAST content line of the section whose header begins with
# <section-prefix> (e.g. `## Suppressions`), preserving the blank-line separator
# before the next section. If the section header is missing entirely (hand-edited
# file), recreate it with <canonical-header> at EOF and append the bullet under it.
# Writes atomically via a sibling temp file.
# ---------------------------------------------------------------------------

append_bullet() {
  _ab_prefix="$1"
  _ab_bullet="$2"
  _ab_hdr="$3"
  _ab_tmp="$LEARNINGS_FILE.rc-learn.$$"
  # shellcheck disable=SC2064  # expand $_ab_tmp now, into the trap.
  trap "rm -f \"$_ab_tmp\"" EXIT INT TERM
  awk -v want="$_ab_prefix" -v bullet="$_ab_bullet" -v hdr="$_ab_hdr" '
    # A section header line: close out the previous section (inserting the bullet
    # if that was the target and we have not yet), flush any buffered trailing
    # blank lines, then decide whether THIS header is the target.
    /^## / {
      if (intgt && !done) { print bullet; done = 1 }
      for (i = 1; i <= nb; i++) print blk[i]
      nb = 0
      intgt = (index($0, want) == 1) ? 1 : 0
      if (intgt) found = 1
      print
      next
    }
    {
      if (intgt) {
        # Buffer blank lines (they may be the trailing separator); flush them
        # only when a real content line follows, so the bullet lands after the
        # last content line, before the trailing blank(s).
        if ($0 ~ /^[ \t]*$/) { blk[++nb] = $0; next }
        for (i = 1; i <= nb; i++) print blk[i]
        nb = 0
        print
        next
      }
      print
    }
    END {
      if (intgt && !done) { print bullet; done = 1 }
      for (i = 1; i <= nb; i++) print blk[i]
      if (!found) { print ""; print hdr; print bullet }
    }
  ' "$LEARNINGS_FILE" >"$_ab_tmp"
  mv "$_ab_tmp" "$LEARNINGS_FILE"
  trap - EXIT INT TERM
}

# ---------------------------------------------------------------------------
# Idempotency checks (awk, literal comparison — no regex on user data)
# ---------------------------------------------------------------------------

# suppression_exists <fingerprint>: 0 if a Suppressions bullet already carries the
# same fingerprint (exact match after trim), else 1.
suppression_exists() {
  awk -v fp="$1" '
    /^## / { insec = (index($0, "## Suppressions") == 1) ? 1 : 0; next }
    insec && /^- fingerprint:/ {
      line = $0
      sub(/^- fingerprint:[ \t]*/, "", line)
      p = index(line, " | ")
      if (p > 0) line = substr(line, 1, p - 1)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == fp) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$LEARNINGS_FILE"
}

# convention_exists <text>: 0 if a Conventions bullet normalizes (trim + collapse
# whitespace + lowercase) to the same text, else 1. Both sides normalized in awk
# so the comparison is symmetric.
convention_exists() {
  awk -v target="$1" '
    function norm(s) {
      gsub(/[ \t]+/, " ", s)
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return tolower(s)
    }
    BEGIN { t = norm(target) }
    /^## / { insec = (index($0, "## Conventions") == 1) ? 1 : 0; next }
    insec && /^- / {
      line = $0
      sub(/^- /, "", line)
      if (norm(line) == t) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$LEARNINGS_FILE"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_add_suppression() {
  # $1 fingerprint, $2 reason
  _cs_fp="$(trim "$1")"
  _cs_reason="$(trim "$2")"
  [ -n "$_cs_fp" ] || die "add-suppression: fingerprint is empty"
  [ -n "$_cs_reason" ] || die "add-suppression: reason is empty"
  case "$_cs_fp" in *'|'*) die "add-suppression: fingerprint may not contain '|'" ;; esac
  case "$_cs_reason" in *'|'*) die "add-suppression: reason may not contain '|'" ;; esac

  _cs_date="${RC_LEARN_DATE:-$(date +%F)}"
  case "$_cs_date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) die "invalid date '$_cs_date' (want YYYY-MM-DD)" ;;
  esac

  ensure_file
  if suppression_exists "$_cs_fp"; then
    echo "rc-learn: suppression for '$_cs_fp' already present; left unchanged" >&2
    return 0
  fi
  append_bullet "## Suppressions" \
    "- fingerprint: $_cs_fp | reason: $_cs_reason | added: $_cs_date" \
    "$HDR_SUPPRESSIONS"
}

cmd_add_convention() {
  # $1 text
  _cc_text="$(trim "$1")"
  [ -n "$_cc_text" ] || die "add-convention: text is empty"

  ensure_file
  if convention_exists "$_cc_text"; then
    echo "rc-learn: convention already present; left unchanged" >&2
    return 0
  fi
  append_bullet "## Conventions" "- $_cc_text" "$HDR_CONVENTIONS"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

[ "$#" -ge 1 ] || usage
_cmd="$1"
shift

case "$_cmd" in
  add-suppression)
    [ "$#" -eq 2 ] || die "add-suppression needs exactly <fingerprint> <reason>"
    for _arg in "$@"; do
      has_ctrl "$_arg" && die "argument contains a control character"
    done
    cmd_add_suppression "$1" "$2"
    ;;
  add-convention)
    [ "$#" -eq 1 ] || die "add-convention needs exactly <text>"
    has_ctrl "$1" && die "argument contains a control character"
    cmd_add_convention "$1"
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    die "unknown command '$_cmd' (want add-suppression | add-convention)"
    ;;
esac

exit 0
