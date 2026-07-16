---
description: Remove Review Council configuration
allowed-tools: Bash, Read, Edit
---

# Review Council — Uninstall

**Scope:** this command clears the plugin's per-repo **configuration footprint** only. Removing the plugin itself (uninstalling `review-council` from Claude Code) is a separate action via your plugin manager / marketplace — this skill does not do it, and there is nothing global to undo: Review Council never registers an MCP server or touches `~/.claude/settings.json`. Its **repository-local runtime/configuration footprint** lives in the **target repo** (the repo being reviewed), under `.review-council/`: `config.yml`, `config.local.yml`, `learnings.md` (only if a learning was ever captured), plus a `.gitignore` line setup added for `config.local.yml`.

1. Check the target repo for `.review-council/config.yml`, `.review-council/config.local.yml`, and `.review-council/learnings.md`. Report which of these actually exist — don't assume all three are present.
2. **`config.local.yml`** — per-machine, gitignored, never committed. If present, offer to delete it; once the user confirms, it's safe to remove outright.
3. **`config.yml`** and **`learnings.md`** are normally **committed, team-shared** files (`config.yml` holds the team's checked-in defaults; `learnings.md` persists confirmed review outcomes for the whole team — see `rules/config.md` → Learnings). Do not delete either by default:
   - Explain what each one is and that removing it affects the whole team, not just this machine.
   - Only delete if the user explicitly confirms after hearing that.
   - If the user declines, or doesn't give a clear yes, leave both in place.
4. If `.gitignore` still has the `.review-council/config.local.yml` line (and its `# Review Council per-machine config (not shared)` comment) that setup added, offer to remove it. Only remove it if the user confirms.
5. Tell the user: "To fully remove the plugin, run: `/plugin uninstall review-council`"
