# Review Council

Multi-agent convergence review for Claude Code. Multiple AI models independently review your PR, code, or plan — then discuss until they converge on a curated list of what actually needs changing.

## Why

Single-model code review has blind spots. Different models catch different things. Review Council runs multiple reviewers in parallel, compares their findings, and produces a single curated report where:

- **Agreed findings** (both reviewers flagged) = high confidence
- **Unique findings** (one reviewer) = worth considering
- **Conflicts** (reviewers disagree) = both perspectives documented

The result: fewer false positives, broader coverage, and a clear priority order.

## Quick Start

```bash
# Install the plugin
/plugin marketplace add deployhq/review-council
/plugin install review-council

# Configure Codex as second reviewer
/review-council:setup

# Review something
/review-council:run              # auto-detect: current PR or staged changes
/review-council:run 42           # review PR #42
/review-council:run src/auth.ts  # review a source file
/review-council:run docs/plan.md # review a plan or document
```

## How It Works

```mermaid
flowchart TD
    A["/review-council:run [target]"] --> B{Detect Target}
    B -->|PR number| C["Fetch PR diff & metadata"]
    B -->|Source path| D["Read source files"]
    B -->|Doc/plan path| E["Read document & references"]
    B -->|No argument| F{Auto-detect}
    F -->|Open PR on branch| C
    F -->|Staged changes| D
    F -->|Unstaged changes| D

    C --> G["Gather Context"]
    D --> G
    E --> G

    G --> H["Round 1: Independent Review"]

    H --> I["Claude Subagent"]
    H --> J["Codex via MCP"]

    I --> K["Synthesize"]
    J --> K

    K --> L{Disagreements?}
    L -->|"Yes"| M["Round 2: Share synthesis, revise"]
    L -->|"No"| N["Final Report"]

    M --> O{Converged?}
    O -->|"Yes"| N
    O -->|"No (max 3 rounds)"| P["Report with dissenting opinions"]

    style A fill:#7c3aed,color:#fff
    style H fill:#2563eb,color:#fff
    style I fill:#6366f1,color:#fff
    style J fill:#059669,color:#fff
    style N fill:#16a34a,color:#fff
    style P fill:#d97706,color:#fff
```

**Auto-detection** means you usually just run `/review-council:run` with no arguments. It checks for an open PR on the current branch, then staged changes, then unstaged changes.

## Reviewers

```mermaid
graph LR
    O["Orchestrator<br/>(Claude Code)"] -->|subagent| C["Claude<br/>Reviewer"]
    O -->|stdio MCP| X["Codex<br/>Reviewer"]
    O -.->|"planned"| G["Gemini<br/>Reviewer"]
    O -.->|"planned"| L["Ollama<br/>Local Models"]

    style O fill:#7c3aed,color:#fff
    style C fill:#6366f1,color:#fff
    style X fill:#059669,color:#fff
    style G fill:#94a3b8,color:#fff,stroke-dasharray: 5 5
    style L fill:#94a3b8,color:#fff,stroke-dasharray: 5 5
```

| Reviewer | Transport | Status |
|----------|-----------|--------|
| **Claude** | Native subagent with dedicated reviewer persona | Available |
| **Codex** (OpenAI) | Codex MCP server (stdio) | Available |
| **Gemini** | Gemini MCP (planned) | Roadmap |
| **Ollama** | Local model MCP (planned) | Roadmap |

Without Codex configured, Review Council runs in **single-reviewer mode** — still useful as a structured review with a dedicated persona, but you lose the cross-model validation.

## Setup

### Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- [Codex CLI](https://github.com/openai/codex) — `npm install -g @openai/codex && codex login`
- [GitHub CLI](https://cli.github.com/) (`gh`) — for PR reviews (optional)

### Install

```bash
/plugin marketplace add deployhq/review-council
/plugin install review-council
/review-council:setup
```

The setup command will:
1. Verify Codex CLI is installed and authenticated
2. Configure the Codex MCP server in `~/.claude/settings.json`
3. Verify GitHub CLI for PR reviews (optional)

Restart Claude Code after setup for MCP changes to take effect.

### Uninstall

```bash
/review-council:uninstall    # Remove MCP configuration
/plugin uninstall review-council
```

## Output Example

```
## Review Council Report

**Target:** PR #42 — "Add rate limiting to API endpoints"
**Type:** PR
**Reviewers:** Claude, Codex
**Rounds:** 2
**Consensus:** Strong

### Critical Issues

1. **[critical] [high]** — `src/middleware/rate-limit.ts:28`
   - Issue: Rate limit counter uses in-memory store — resets on every deploy
   - Why: Users get full quota back on each deployment, defeating the purpose
   - Fix: Use Redis or PostgreSQL for counter storage

### Important Findings

2. **[important] [high]** — `src/middleware/rate-limit.ts:15`
   - Issue: Rate limit key uses IP only — shared IPs (corporate NAT) throttle all users
   - Why: Enterprise customers behind NAT will hit limits quickly
   - Fix: Use authenticated user ID as primary key, fall back to IP for anonymous

3. **[important] [medium]** — `src/routes/api.ts:44`
   - Issue: Rate limit headers (X-RateLimit-Remaining) not included in responses
   - Why: Clients can't implement backoff without knowing their remaining quota
   - Fix: Add standard rate limit headers per RFC 6585

### Suggestions

4. **[suggestion] [medium]** — `docs/api.md`
   - Issue: No documentation of rate limit behavior for API consumers
   - Fix: Add rate limits section to API docs

### What's Done Well
- Clean middleware pattern — easy to adjust limits per route
- Good test coverage for the happy path
```

## Architecture

### Plugin Structure

```
review-council/
├── .claude-plugin/
│   ├── plugin.json          # Plugin metadata
│   └── marketplace.json     # Marketplace listing
├── commands/
│   ├── run.md               # Main command (orchestrator)
│   ├── setup.md             # Setup wizard
│   └── uninstall.md         # Cleanup
├── agents/
│   └── reviewer-claude.md   # Claude reviewer persona
├── rules/
│   ├── orchestration.md     # Convergence logic docs
│   └── delegation-format.md # External model prompt format
├── CLAUDE.md                # Plugin instructions
├── LICENSE                  # MIT
└── README.md                # This file
```

### Convergence Rounds

```mermaid
sequenceDiagram
    participant O as Orchestrator
    participant C as Claude Reviewer
    participant X as Codex Reviewer

    Note over O: Round 1 — Independent
    O->>+C: Context package
    O->>+X: Context package (delegation format)
    C-->>-O: Findings + assessment
    X-->>-O: Findings + assessment

    Note over O: Synthesize — merge, deduplicate, categorize
    O->>O: Agreed / Unique / Conflicting

    alt Conflicts or important unique findings
        Note over O: Round 2 — Informed Revision
        O->>+C: Round 1 synthesis
        O->>+X: Round 1 synthesis (via codex-reply)
        C-->>-O: Revised findings
        X-->>-O: Revised findings
        O->>O: Final convergence
    end

    Note over O: Curated Report
```

### Design Decisions

**Why parallel independent reviews?** If reviewers see each other's output, they anchor on the first response. Independent review ensures genuinely different perspectives, then convergence rounds resolve differences.

**Why a structured delegation format?** Different models have different defaults. The 7-section format (TASK, CONTEXT, EXPECTED OUTCOME, CONSTRAINTS, MUST DO, MUST NOT DO, OUTPUT FORMAT) forces consistent, comparable output regardless of the model.

**Why max 3 rounds?** Research shows rounds 1-2 catch 90%+ of issues. Round 3 has diminishing returns. Beyond 3 rounds, unresolved disagreements are better presented as "dissenting opinions" than debated further.

**Why filter aggressively?** The biggest failure mode of AI code review is noise — too many low-value findings. Review Council filters: confidence scoring from agreement, severity thresholds, and explicit rules against style nitpicks.

## GitHub Actions (Roadmap)

Review Council can be triggered from CI as a reusable GitHub Action workflow — similar to [claude-fix-pr](https://github.com/deployhq/claude-fix-pr).

```mermaid
flowchart LR
    A["PR opened/updated"] --> B["GitHub Action"]
    C["/review-council comment"] --> B
    B --> D["Headless Claude Code"]
    D --> E["Review Council"]
    E --> F["PR Comment<br/>with findings"]
    E --> G{"Critical issues?"}
    G -->|"Yes"| H["Block merge"]
    G -->|"No"| I["Approve"]

    style B fill:#2563eb,color:#fff
    style E fill:#7c3aed,color:#fff
    style H fill:#dc2626,color:#fff
    style I fill:#16a34a,color:#fff
```

This is planned for a future release.

## Adding New Reviewers (Extensibility)

The architecture supports any model accessible via MCP:

```mermaid
graph TB
    subgraph "Orchestrator"
        O["Review Council Command"]
    end

    subgraph "Native"
        C["Claude Subagent"]
    end

    subgraph "MCP Transport Layer"
        direction TB
        S1["stdio MCP"] --> X["Codex CLI"]
        S2["stdio MCP"] --> G["Gemini CLI"]
        S3["stdio MCP"] --> L["Ollama"]
        S4["HTTP MCP"] --> A["Any API"]
    end

    O --> C
    O --> S1
    O -.-> S2
    O -.-> S3
    O -.-> S4

    style O fill:#7c3aed,color:#fff
    style C fill:#6366f1,color:#fff
    style X fill:#059669,color:#fff
    style G fill:#94a3b8,color:#fff
    style L fill:#94a3b8,color:#fff
    style A fill:#94a3b8,color:#fff
```

Adding a new reviewer requires:
- Transport config in the setup command
- Model-specific prompt adjustments (if needed)
- No changes to orchestration logic

The delegation format in `rules/delegation-format.md` ensures consistent, comparable output across all providers.

## Contributing

1. Fork the repo
2. Create a feature branch
3. Test with `/review-council:run` on real PRs/code
4. Submit a PR

## License

MIT - see [LICENSE](LICENSE).
