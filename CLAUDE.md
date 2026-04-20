# Review Council

Multi-agent convergence review plugin for Claude Code. Multiple AI reviewers independently analyze your PR, code, or plan, then discuss until they converge on a curated list of findings.

## Commands

- `/review-council:run [target]` — Run a convergence review (auto-detects target type and available providers)
- `/review-council:setup` — Show provider status and prerequisites
- `/review-council:uninstall` — Remove configuration

## How It Works

1. **Detect providers** — Auto-detects which reviewers are available (CLI first, MCP fallback)
2. **Detect target** — Auto-detects if you're reviewing a PR, source code, or plan/document
3. **Gather** — Collects relevant context (diff, files, related docs)
4. **Review** — Sends identical context to all available reviewers in parallel
5. **Converge** — Merges findings, identifies agreements/disagreements, runs additional rounds if needed
6. **Report** — Outputs a curated, prioritized list with confidence levels based on reviewer agreement

## Reviewers

| Reviewer | Transport | Detection |
|----------|-----------|-----------|
| Claude | Native subagent | Always available |
| Codex | CLI (`codex exec`) / MCP fallback | `which codex` or MCP tool |
| Gemini | CLI (`gemini`) / MCP fallback | `which gemini` or MCP tool |
| Perplexity | Sonar API (`curl`) | `PERPLEXITY_API_KEY` env var |

Minimum 2 reviewers needed for convergence mode. With only Claude, runs in single-reviewer mode.

## Architecture

```
/review-council:run [target]
      |
      v
  Provider Detection (auto)
      |
      v
  Orchestrator (main Claude thread)
      |
      +---> Round 1 (parallel) ------+
      |     - Claude (subagent)      |
      |     - Codex (CLI/MCP)        |
      |     - Gemini (CLI/MCP)       |
      |     - Perplexity (API)       |
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
  .claude-plugin/     Plugin metadata (plugin.json is the single source of truth for version)
  skills/             Slash commands (run, setup, uninstall)
  agents/             Subagent definitions (Claude reviewer persona)
  rules/              Orchestration logic, delegation format, provider registry
```

## Versioning

Bump the `version` field in `.claude-plugin/plugin.json` whenever you ship a bug fix or new feature (semver: patch for fixes, minor for features, major for breaking changes). `marketplace.json` inherits from `plugin.json` via strict-mode merge — do not duplicate the version there. Pair the bump with a `chore: bump version to X.Y.Z` commit after the change.
