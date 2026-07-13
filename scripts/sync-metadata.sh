#!/usr/bin/env sh
# sync-metadata.sh — stamps the canonical plugin description into every file
# that duplicates it, so .claude-plugin/plugin.json stays the single source
# of truth for the project's short description.
#
# Workflow: edit plugin.json's `.description`, then run this script.
#
# Targets stamped:
#   - README.md                        <!-- rc:description:start/end --> region
#   - CLAUDE.md                        <!-- rc:description:start/end --> region
#   - skills/run/SKILL.md               frontmatter `description:` line
#   - .claude-plugin/marketplace.json   `.description`
#
# Usage:
#   scripts/sync-metadata.sh            stamp the canonical description everywhere
#   scripts/sync-metadata.sh --check    verify only; writes nothing; exits
#                                        non-zero and lists any file out of sync
#
# Requires jq to read plugin.json's `.description` and to rewrite
# marketplace.json. jq is preinstalled on GitHub Actions runners; if it's
# missing locally this script prints a notice and exits 0 (a no-op) rather
# than failing a workflow that doesn't otherwise need it.

set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
root_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"

plugin_json="$root_dir/.claude-plugin/plugin.json"
marketplace_json="$root_dir/.claude-plugin/marketplace.json"
readme_md="$root_dir/README.md"
claude_md="$root_dir/CLAUDE.md"
run_skill_md="$root_dir/skills/run/SKILL.md"

check_mode=0
case "${1:-}" in
  --check) check_mode=1 ;;
  "") ;;
  *)
    echo "usage: $(basename -- "$0") [--check]" >&2
    exit 2
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "sync-metadata: jq not found; skipping (nothing to sync without it)" >&2
  exit 0
fi

if [ ! -f "$plugin_json" ]; then
  echo "sync-metadata: $plugin_json not found" >&2
  exit 1
fi

desc="$(jq -r '.description' "$plugin_json")"
case "$desc" in
  "" | "null")
    echo "sync-metadata: .description missing/empty in $plugin_json" >&2
    exit 1
    ;;
esac

# out_of_sync accumulates every file this run could NOT confirm/bring in sync:
# a hard error (missing file, missing markers) always lands here in both
# modes; a plain content mismatch lands here only in --check mode (in apply
# mode a content mismatch is fixed in place and recorded in $changed instead).
out_of_sync=""
changed=""

note_diff() {
  # $1 = file
  out_of_sync="$out_of_sync $1"
}

note_changed() {
  # $1 = file
  changed="$changed $1"
}

# sync_markers <file>: stamps $desc between the rc:description marker
# comments. The region is normalized to exactly: start marker / description
# line / end marker, regardless of how many lines currently sit between them
# -- so this is idempotent no matter what was there before.
sync_markers() {
  _sm_file="$1"
  _sm_start='<!-- rc:description:start -->'
  _sm_end='<!-- rc:description:end -->'

  if [ ! -f "$_sm_file" ]; then
    echo "sync-metadata: $_sm_file not found" >&2
    note_diff "$_sm_file"
    return
  fi

  if ! grep -qF "$_sm_start" "$_sm_file" || ! grep -qF "$_sm_end" "$_sm_file"; then
    echo "sync-metadata: $_sm_file missing rc:description markers" >&2
    note_diff "$_sm_file"
    return
  fi

  _sm_current="$(awk -v s="$_sm_start" -v e="$_sm_end" '
    $0 == s { inblock = 1; next }
    $0 == e { inblock = 0 }
    inblock { print }
  ' "$_sm_file")"

  if [ "$_sm_current" = "$desc" ]; then
    return
  fi

  if [ "$check_mode" -eq 1 ]; then
    note_diff "$_sm_file"
    return
  fi

  _sm_tmp="$(mktemp "${TMPDIR:-/tmp}/sync-metadata.XXXXXX")"
  awk -v s="$_sm_start" -v e="$_sm_end" -v d="$desc" '
    $0 == s { print; print d; inblock = 1; next }
    $0 == e { inblock = 0; print; next }
    inblock { next }
    { print }
  ' "$_sm_file" >"$_sm_tmp"
  mv "$_sm_tmp" "$_sm_file"
  note_changed "$_sm_file"
}

# sync_frontmatter <file>: stamps $desc into the `description:` line of the
# YAML frontmatter block (the first `---` ... `---` fence at the top of file).
sync_frontmatter() {
  _sf_file="$1"

  if [ ! -f "$_sf_file" ]; then
    echo "sync-metadata: $_sf_file not found" >&2
    note_diff "$_sf_file"
    return
  fi

  if ! awk 'NR == 1 && $0 == "---" { f = 1 } f && /^description:/ { found = 1 } END { exit !found }' "$_sf_file"; then
    echo "sync-metadata: $_sf_file missing a frontmatter description: line" >&2
    note_diff "$_sf_file"
    return
  fi

  _sf_current="$(awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && /^---$/ { exit }
    infm && /^description:/ { sub(/^description: */, ""); print; exit }
  ' "$_sf_file")"

  if [ "$_sf_current" = "$desc" ]; then
    return
  fi

  if [ "$check_mode" -eq 1 ]; then
    note_diff "$_sf_file"
    return
  fi

  _sf_tmp="$(mktemp "${TMPDIR:-/tmp}/sync-metadata.XXXXXX")"
  awk -v d="$desc" '
    NR == 1 && $0 == "---" { print; infm = 1; next }
    infm && /^---$/ { infm = 0; print; next }
    infm && /^description:/ { print "description: " d; next }
    { print }
  ' "$_sf_file" >"$_sf_tmp"
  mv "$_sf_tmp" "$_sf_file"
  note_changed "$_sf_file"
}

# sync_marketplace_json <file>: stamps $desc into the top-level `.description`.
sync_marketplace_json() {
  _sj_file="$1"

  if [ ! -f "$_sj_file" ]; then
    echo "sync-metadata: $_sj_file not found" >&2
    note_diff "$_sj_file"
    return
  fi

  _sj_current="$(jq -r '.description' "$_sj_file")"

  if [ "$_sj_current" = "$desc" ]; then
    return
  fi

  if [ "$check_mode" -eq 1 ]; then
    note_diff "$_sj_file"
    return
  fi

  _sj_tmp="$(mktemp "${TMPDIR:-/tmp}/sync-metadata.XXXXXX")"
  jq --arg d "$desc" '.description = $d' "$_sj_file" >"$_sj_tmp"
  mv "$_sj_tmp" "$_sj_file"
  note_changed "$_sj_file"
}

sync_markers "$readme_md"
sync_markers "$claude_md"
sync_frontmatter "$run_skill_md"
sync_marketplace_json "$marketplace_json"

if [ -n "$out_of_sync" ]; then
  echo "sync-metadata: out of sync:$out_of_sync" >&2
  exit 1
fi

if [ "$check_mode" -eq 1 ]; then
  echo "sync-metadata --check: all files in sync with $plugin_json .description"
  exit 0
fi

if [ -n "$changed" ]; then
  echo "sync-metadata: updated:$changed"
else
  echo "sync-metadata: already in sync"
fi

exit 0
