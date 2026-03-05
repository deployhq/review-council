# Review Council

Multi-agent convergence review plugin for Claude Code. Multiple AI reviewers independently analyze your PR, code, or plan, then discuss until they converge on a curated list of findings.

## Commands

- `/review-council:run [target]` — Run a convergence review (auto-detects target type)
- `/review-council:setup` — Configure external model providers (Codex, etc.)
- `/review-council:uninstall` — Remove configuration

## How It Works

1. **Detect** — Auto-detects if you're reviewing a PR, source code, or plan/document
2. **Gather** — Collects relevant context (diff, files, related docs)
3. **Review** — Sends identical context to multiple independent reviewers in parallel
4. **Converge** — Merges findings, identifies agreements/disagreements, runs additional rounds if needed
5. **Report** — Outputs a curated, prioritized list with confidence levels based on reviewer agreement

## Reviewers

| Reviewer | Transport | Status |
|----------|-----------|--------|
| Claude | Native subagent | Available |
| Codex | MCP (stdio) | Available (requires setup) |
| Gemini | MCP | Planned |
| Ollama | MCP | Planned |

## Architecture

```
/review-council:run [target]
      |
      v
  Orchestrator (main Claude thread)
      |
      +---> Round 1 (parallel) ------+
      |     - Claude (subagent)      |
      |     - Codex (MCP tool)       |
      |<-----------------------------+
      |
      v
  Merge, deduplicate, categorize
      |
      +---> Round 2 (if conflicts) --+
      |     Share synthesis           |
      |     Each reviewer revises     |
      |<-----------------------------+
      |
      v
  Final curated report
```

## File Structure

```
review-council/
  .claude-plugin/     Plugin metadata
  commands/           Slash commands (/run, /setup, /uninstall)
  agents/             Subagent definitions (Claude reviewer persona)
  rules/              Orchestration logic and delegation format docs
```