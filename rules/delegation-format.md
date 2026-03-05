# Delegation Format

When delegating to external models (Codex, Gemini, Ollama, etc.), use this structured format to ensure consistent, comparable output regardless of the model's defaults.

## Template

```
## TASK
[What to review and in what capacity]

## CONTEXT
[Full context: diff, file contents, plan text, etc.]

## EXPECTED OUTCOME
[What the output should look like]

## CONSTRAINTS
[Focus areas, what to ignore, limits]

## MUST DO
- Provide specific line/section references
- Explain WHY each finding matters
- Suggest a concrete fix for each finding
- Rate severity (critical/important/suggestion) and confidence (high/medium/low)

## MUST NOT DO
- Flag style/formatting nitpicks
- Flag pre-existing issues not in the diff
- Provide vague feedback without actionable recommendations
- Exceed 10 findings (focus on the most important)

## OUTPUT FORMAT
Structured markdown with: Findings (severity, confidence, location, issue, recommendation), What's Good, Overall Assessment.
```

## Why This Format

Different models have different defaults for verbosity, structure, and focus. This format:
- Forces structured output that can be programmatically compared
- Sets clear boundaries on scope and quantity
- Ensures every finding is actionable (not just "this looks wrong")
- Makes deduplication possible across reviewers

## Adding New Providers

When adding a new model provider, the delegation format stays the same. Only the transport changes:
- **Codex**: `mcp__codex__codex` tool (stdio MCP)
- **Gemini**: Future — likely `mcp__gemini__gemini` or HTTP MCP
- **Ollama**: Future — likely stdio MCP wrapping `ollama run`
