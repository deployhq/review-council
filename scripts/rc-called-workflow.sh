#!/usr/bin/env bash
# rc-called-workflow.sh — show reviewers Review Council's own reusable workflow
# when a changed workflow calls it (Step 2 of skills/run/SKILL.md).
#
# A caller workflow (`uses: deployhq/review-council/.github/workflows/
# review-council.yml@<ref>`) delegates permissions, concurrency, inputs and
# secrets to a file in another repo. Reviewers cannot see that file, so they
# flag the caller for things the called workflow already handles, and the
# verifiers cannot refute those findings. This script prints the plugin's own
# copy of that workflow, labelled as reference material, so the orchestrator
# can append it to the shared context every reviewer and verifier gets.
#
# Usage, from the reviewed repo's root:
#   gh pr diff <n> --name-only | "${CLAUDE_PLUGIN_ROOT}/scripts/rc-called-workflow.sh"
# Stdin: changed paths, one per line, repo-relative. No arguments.
#
# Output: nothing when no changed workflow calls Review Council; otherwise ONE
# block (header, one line per calling file, the plugin copy in a code fence).
# Always exits 0: it must never fail the review.
#
# Security: the reviewed repo is untrusted. The file shown is a literal path
# under the plugin root, so a PR cannot choose what is read. Changed paths must
# match `.github/workflows/<name>.y(a)ml` and be regular files (no symlinks).
# Nothing from those files is printed except the validated path and a ref that
# passes a strict charset check. No network.

set -u

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
COPY="$PLUGIN_ROOT/.github/workflows/review-council.yml"
MAX_LINES=50

PATH_RE='^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$'
USES_RE='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'"'"']?deployhq/review-council/\.github/workflows/review-council\.yml@(.*)$'
REF_RE='^[A-Za-z0-9._/-]{1,100}$'

# Print the validated ref of the first matching `uses:` line in file $1, or
# `(unrecognised ref)`. Returns 1 when the file does not call Review Council.
caller_ref() {
  local line rest
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ $USES_RE ]] || continue
    rest="${BASH_REMATCH[2]}"
    rest="${rest%$'\r'}"
    # Drop a trailing comment (` # ...`), trailing blanks, one closing quote.
    if [[ "$rest" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
      rest="${BASH_REMATCH[1]}"
    fi
    rest="${rest%"${rest##*[![:space:]]}"}"
    rest="${rest%[\"\']}"
    if [[ "$rest" =~ $REF_RE ]]; then
      printf '%s\n' "$rest"
    else
      printf '(unrecognised ref)\n'
    fi
    return 0
  done < "$1"
  return 1
}

# The workflows directory itself must not be a symlink out of the repo.
dirs_ok=1
if [ -L .github ] || [ -L .github/workflows ]; then
  dirs_ok=0
fi

callers=""
seen=" "
n=0
while IFS= read -r p || [ -n "$p" ]; do
  n=$((n + 1))
  [ "$n" -le "$MAX_LINES" ] || break
  p="${p%$'\r'}"
  [ "$dirs_ok" -eq 1 ] || continue
  [[ "$p" =~ $PATH_RE ]] || continue
  case "$seen" in *" $p "*) continue ;; esac
  seen="$seen$p "
  [ -f "$p" ] && [ ! -L "$p" ] || continue
  ref="$(caller_ref "$p")" || continue
  callers="$callers- $p pins @$ref"$'\n'
done

[ -n "$callers" ] || exit 0

printf 'CALLED REVIEW COUNCIL WORKFLOW (reference only — not part of this change; do not review it)\n'
printf "These changed workflows call Review Council's reusable workflow:\n"
printf '%s' "$callers"

if [ ! -f "$COPY" ]; then
  printf "Review Council's own workflow is not in this plugin install, so it cannot be shown.\n"
  exit 0
fi

version="$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)" || version=""
[ -n "$version" ] || version="unknown"

# A fence longer than the longest backtick run in the copy (minimum 3).
longest="$(awk '{
  s = $0
  while (match(s, /`+/)) { if (RLENGTH > m) m = RLENGTH; s = substr(s, RSTART + RLENGTH) }
} END { print m + 0 }' "$COPY" 2>/dev/null)" || longest=0
[ -n "$longest" ] || longest=0
flen=$((longest + 1))
[ "$flen" -ge 3 ] || flen=3
fence="$(printf '%*s' "$flen" '' | tr ' ' '`')"

printf "Below is Review Council's own copy of that workflow (plugin version %s). The pinned ref may differ slightly. Use it to check what the called workflow already does (the permissions it needs, its concurrency group, its inputs and secrets) before flagging the caller.\n" "$version"
printf '%syaml\n' "$fence"
cat "$COPY"
# Close the fence on its own line even if the copy lacks a final newline.
[ -z "$(tail -c 1 "$COPY")" ] || printf '\n'
printf '%s\n' "$fence"
exit 0
