#!/usr/bin/env bats
#
# skill-anchors.bats — regression guard for the Step 6.6 posting-reliability
# anchors in skills/run/SKILL.md.
#
# These anchors are prose the orchestrator relies on to reliably REACH the
# optional, human-gated review-digest post (Step 6.6) in long/compacted
# sessions. They carry no script logic, so nothing else in the suite covers
# them — a future refactor could silently delete them and every other test
# would still pass. This guard prevents silent DELETION only; it cannot verify
# LLM compliance with the prose.

SKILL="${BATS_TEST_DIRNAME}/../../skills/run/SKILL.md"

@test "skill-anchors: SKILL.md exists" {
  [ -f "$SKILL" ]
}

@test "skill-anchors: Step 0 states the posting commitment as a pending action" {
  grep -qF 'Posting commitment — state it as a pending action HERE.' "$SKILL"
}

@test "skill-anchors: Step 0 requires the non-paraphrasable approval tokens" {
  grep -qF 'using the words **offer** and **wait for your approval**' "$SKILL"
}

@test "skill-anchors: Step 0 announces the running plugin version" {
  grep -qF 'Also state the running plugin version' "$SKILL"
}

@test "skill-anchors: end of Step 6 re-resolves pr_comments.enabled at report time" {
  grep -qF 'Re-resolve `pr_comments.enabled` now' "$SKILL"
}

@test "skill-anchors: the human approval gate is restated self-contained at the hand-off" {
  grep -qF 'Step 6.6 still stops and waits for your explicit approval before anything is posted' "$SKILL"
}

@test "skill-anchors: report Pipeline line can surface the pending post" {
  grep -qF 'post digest (pending)' "$SKILL"
}
