---
description: Remove Review Council configuration
allowed-tools: Bash, Read, Edit
---

# Review Council — Uninstall

1. Read `~/.claude/settings.json`
2. Ask the user: "Remove the Codex MCP server configuration added by Review Council? (Other MCP servers will not be affected.)"
3. If yes: Remove only the `"codex"` entry from `mcpServers`. Keep all other settings intact.
4. If no: Skip.
5. Tell the user: "To fully remove the plugin, run: `/plugin uninstall review-council`"
