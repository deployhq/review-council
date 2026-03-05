---
name: setup
description: Set up the Review Council plugin — configure Codex and verify prerequisites
allowed-tools: Bash, Read, Write, Edit
---

# Review Council — Setup

Guide the user through setting up the Review Council plugin. Be concise and direct.

## Step 1: Check Prerequisites

Run these checks in parallel:

### Claude Code
Already running. Skip.

### Codex CLI
```bash
which codex 2>/dev/null && codex --version
```

- If **not found**: Tell the user to install and authenticate:
  ```
  npm install -g @openai/codex
  codex login
  ```
  Wait for confirmation, then re-check.

- If **found**: Verify it works (the version check is sufficient).

### GitHub CLI (optional, for PR reviews)
```bash
which gh 2>/dev/null && gh auth status 2>&1 | head -3
```

- If **not found or not authenticated**: Warn that PR reviews won't work without it. Not a blocker for code/plan reviews.

## Step 2: Configure Codex MCP Server

Check if Codex MCP is already configured:
```bash
cat ~/.claude/settings.json 2>/dev/null
```

Look for a `"codex"` entry under `"mcpServers"`.

**If already configured:** "Codex MCP already configured."

**If not configured:** Read the current `~/.claude/settings.json`, merge in the Codex MCP config:

```json
{
  "mcpServers": {
    "codex": {
      "type": "stdio",
      "command": "codex",
      "args": ["-m", "o3", "mcp-server"]
    }
  }
}
```

Use the Edit tool to add this to the existing settings. Do NOT overwrite other settings — merge carefully. If the file doesn't exist, create it with just this content.

**IMPORTANT:** Find the actual path to the `codex` binary using `which codex` and use the full absolute path in the `command` field. This avoids PATH issues when Claude Code spawns the subprocess.

## Step 3: Summary

Print a summary:

```
Review Council setup complete.

Configured reviewers:
  - Claude (native) ........... always available
  - Codex (via MCP) ........... [configured | not configured]

Prerequisites:
  - GitHub CLI (gh) ........... [authenticated | not found (PR reviews disabled)]

Usage:
  /review-council              auto-detect (current PR or staged changes)
  /review-council 42           review PR #42
  /review-council src/foo.ts   review source code
  /review-council docs/plan.md review a plan or document

Restart Claude Code for MCP changes to take effect.
```

## Future Providers

If the user asks about Gemini, Ollama, or other models — tell them these are planned for a future version. The architecture supports adding new reviewers, but only Codex is available today.
