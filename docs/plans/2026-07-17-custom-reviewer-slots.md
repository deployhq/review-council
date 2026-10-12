# Custom Reviewer Slots — Spec

**Goal:** Let a user add any model (Kimi, DeepSeek, Qwen, a local Ollama, a corporate gateway) as a **repo-capable** reviewer in the council — configured declaratively, with no plugin PR per model. **The first concrete harness is Alibaba OpenCodeReview (`ocr`)** — an opt-in, finder-only Round-1 seat (§12).

**Status:** Phase 1 (`ocr`) **decided** by the user after spikes #1–#2 on deployhq/review-council#21; **not scheduled**, and the full-roster re-review below is still owed. This document is deliberately a *spec*, not an implementation plan — see [Why there's no task breakdown](#why-theres-no-task-breakdown).

**Architecture in one line:** Review Council owns no agent loop and shouldn't start now — a custom slot **borrows** an existing agentic CLI as a runtime (`ocr` in Phase 1, `codex` in Phase 2) and points it at an arbitrary model via a configured provider. The harness supplies the tool loop and the read-only boundary; we supply the identity, the pinned rules, and the mapping into the council's finding format.

> **Revision history.**
> - **Draft 1** → reviewed by Review Council. 2 critical + 9 important. §5 and §6 were written in response.
> - **Draft 2** → reviewed again. **2 more criticals, both inside §5/§6** — the very sections draft 1's review had produced. Both had the same shape: they correctly identified the reader as the place to *compute* a value, then assumed computing it was *enforcing* it.
> - **Draft 3** → fixed both, and reversed one headline claim: custom slots are **finder-only** (§7).
> - **Draft 4** (this one, unreviewed) → makes **`ocr` v1.12.13 the Phase-1 harness** (new §12): opt-in, finder-only, Round 1, model-configurable, never Tier B. Family now comes from a **fixed prefix map with `unknown` = non-distinct** (§5), replacing draft 3's "else itself" and its three rejection rules. `api_key_env` is admitted with the host kept a council literal (§6). `harness` is now required. Phases renumbered: `codex` → 2, `opencode` → 3, trust layer → 4, N slots → 5. §6's Sink 1 is marked **shipped** (v0.9.3).
> - Both reviews ran with **only one non-Claude family** (`agy` quota exhausted), so each round's criticals rest on a single cross-family verification. The second review found that the first review's own fix was still wrong — which is the strongest available argument for re-reviewing this with a full roster before implementing.

---

## 1. Problem

The reviewer roster is a closed enum of four: `claude`, `codex`, `google`, `perplexity`. Adding a fifth model requires a plugin PR touching four files. Users want to bring their own model — Kimi today, something else next quarter — without waiting on us.

The blocker was never transport. It was that a reviewer must be **repo-capable** to be useful: a model that can't explore the code can only comment on what we paste into its prompt (the Perplexity shape). A repo-capable custom slot contributes findings of genuinely comparable quality to Claude/Codex/Google.

## 2. The core insight: three layers, previously conflated

Every existing slot fuses three distinct concerns, and got away with it because each harness only ever ran one model family:

| layer | question | today's examples |
|---|---|---|
| **harness** | what runs the agent loop, reads files, enforces the sandbox? | `codex`, `agy`, `gemini`, Claude Code's `Agent`; custom: `ocr` (P1), `codex` (P2) |
| **provider** | which API serves the model? | OpenAI, Google, Perplexity Sonar; custom: OpenRouter, Ollama |
| **model** | **who is actually reviewing?** → **family** | `gpt-*`, `gemini-*`; custom: `qwen/*`, `moonshotai/kimi-*` |

`codex` the binary only ran OpenAI models; `agy` only ran Gemini. Harness = provider = family, so one name covered all three.

**That is no longer true.** `codex` accepts an arbitrary OpenAI-compatible provider and an arbitrary model slug; `ocr` takes `--provider` and `--model` per run. The layers have come apart, so a custom slot must name all three **explicitly** — in config *and* at the transport boundary. Every place this design has gone wrong across two reviews was a place where two things got quietly merged: two layers, or **computing a value with enforcing it**.

**Why identity must be the model, not the harness:** `codex`-, `opencode`- and `ocr`-running-Kimi are *the same model*. Two slots would cast two votes for one model and let it corroborate itself — the exact convergence skew `rules/providers.md` forbids for `agy`/`gemini`. **A slot is a model identity; the harness is transport.**

## 3. What we verified empirically

This section is the audit trail, and the most durable thing in this document. Phases 1 and 2 rest on executed evidence, not documentation.

**Verified working — the `codex` harness (Phase 2; ran it, twice):**

```bash
codex exec \
  -c "model_providers.openrouter={ name='OpenRouter', base_url='https://openrouter.ai/api/v1', \
      wire_api='responses', env_key='OPENROUTER_API_KEY' }" \
  -c model_provider="openrouter" \
  --model "moonshotai/kimi-k2.7-code" \
  --sandbox read-only --skip-git-repo-check "<prompt>" </dev/null
```

- **Tool calling works.** Kimi drove Codex's loop and ran real shell commands in the repo, then answered with facts it could not have guessed.
- **`--sandbox read-only` is accepted** through the custom provider, and is kernel-enforced (seatbelt/landlock) — **we write no sandbox code**. **Caveat (draft-2 review):** we verified the flag is *accepted and the run works*; we did **not** verify a write is *denied*. See §9 and Phase 2's canary requirement — the phase's whole safety rationale is "kernel sandbox," so this is the one assumption that must be asserted, not assumed.
- **No OpenAI account is required.** With `CODEX_HOME` pointed at an empty temp dir (no `auth.json`, no `codex login`), the run succeeded and created no auth file. **Codex is a pure agent runtime here** — the dependency is `npm i -g @openai/codex`, no subscription, no OpenAI spend.
- **Cost**: `moonshotai/kimi-k2.7-code` is $0.72/M in, $3.49/M out — a full task ran ~56k tokens ≈ **$0.04**.
- **Model list** (`/api/v1/models`, public): 342 models; all Kimi variants report `tools=true`.

**Verified constraints — docs alone would have misled us:**

- **`wire_api = "chat"` was REMOVED from Codex** (its source carries `CHAT_WIRE_API_REMOVED_ERROR`). Only `responses` works. OpenRouter happens to expose `/api/v1/responses`, which is the **only** reason this design is possible at all.
- **A benign warning always fires**: `warning: Model metadata for <slug> not found…`. It appears against *real* OpenRouter. The run works. It must never be classified as a failure.
- **Codex drains stdin** — the shared timeout wrapper's `</dev/null` is mandatory, not defensive.
- **mikefarah yq resolves hyphenated map keys** — `-` is not lexed as subtraction. See §11.

**Verified — the `ocr` harness (Phase 1).** Sources: spikes #1–#2 on deployhq/review-council#21 (five runs, one diff, 43 changed files); `ocr review --help` on the installed v1.12.13; the run-5 JSON (§12.7); and a read of the ocr source at commit `fabbdb2` — cited below as *verified against ocr v1.12.13 source*.

- **It is a harness, not a model.** One configured model runs every stage (file grouping, one sub-agent per group, 1–3 review rounds, line re-anchoring, an LLM fact-check). Pointed at Claude or GPT it adds no family.
- **Per-run provider and model:** `--provider <configured-name>` and `--model <slug>` override the config for one run (`--help`). But there is **no `--config` flag and no `OCR_CONFIG`/`OCR_HOME`** — every config path derives from `$HOME` (source). So per-run config means a **temp `HOME`** holding a council-written `.opencodereview/config.json`, with **no `api_key` in it**: the key is read from the provider's env fallback, e.g. `OPENROUTER_API_KEY` (`resolver.go:443-453`).
- **Host-agent env leaks in.** With no complete config, ocr silently picks up `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_MODEL` — which a Claude Code session sets. They must be unset for the run (source).
- **OpenRouter data policy is enforceable through ocr.** Spike #1 sent `provider: {data_collection: "deny"}` via `providers.openrouter.extra_body`, and proved it is applied: a control with an impossible `only` filter returned 404.
- **Rules are layered, not replaced.** `--rule <file>` is a layer **on top of** the reviewed repo's `.opencodereview/rule.json`. Rule text is first-match (`--rule` → repo → global → built-in), and the first layer with any `include`/`exclude` is used whole. A council file with a dummy exclude therefore displaces the repo file entirely; `ocr rules check` then reports `Source: Custom (--rule)` (source, and tested). Test files are excluded by default and come back only via an `include` in the rule file.
- **Budgets:** `--timeout` is in **minutes** (default 15) and is multiplied by the number of rounds (`--effort` low 1, medium 2, high 3). On the deadline it publishes partial results and marks the rest `failed(timeout)`; `--max-tokens-budget` does the same with `failed(budget)`. The per-request limit is separate: `OCR_LLM_TIMEOUT`, in **seconds** (default 300) — 6 of 23 files hit it in spike #1.
- **Exit codes are not a success signal.** 0 for complete, partial *or skipped*; 1 on error or when nothing was covered (source). Gate on the parsed JSON.
- **JSON shape** (`--format json`): top level `status`, `summary` (incl. `budget_exceeded`), `comments[]`, `warnings[]` (`type`, `file`, `message`), `session_id`, `manifest`, `retry_report`; run 5 also carried `llm`, `groups`, `tool_calls`. A comment has `path`, `start_line`, `end_line`, `severity`, `category`, `content`, `existing_code`, `suggestion_code`. The manifest is `ocr.run-manifest/v1`; its `coverage` holds `selected`, `completed`, `reused`, `failed` and `waived` lists of `{item_id, path, classification, reason}`, with `classification` ∈ `provider | timeout | cancelled | configuration | input | budget | panic | unknown`; `execution` records the `provider`, `model`, `ocr_version` and `rule_config_sha256` that actually ran.
- **Files excluded before review are not in the review JSON.** Their reasons appear only in `--preview --format json`, which makes no LLM call (source).
- **Run 5 forces three mapper cases** (§12.5): `severity` is **absent** — not `null` — on 8 of 9 comments; `start_line` is `0` (file-level) on 5 of 9; and one comment's `path` is `dockerignore` while the manifest lists `.dockerignore`. No `suggestion_code` and no failed items were observed.
- **Tools observed:** `file_read`, `code_search`, `file_read_diff`, `code_comment` — no write or shell tool. Observed across runs, **not proven exhaustive**; `--tools <json>` can replace the embedded set.
- **State and network:** sessions are persisted under `$HOME` (`session_id` is a counter; `ocr session` lists them). Every run does an npm update check unless `OCR_NO_UPDATE=1`. Telemetry is off by default (source).
- **Precision and speed** (spike #1 step 2, spike #2): of `ocr`'s 6 distinct concerns on Qwen3.8-Max, 2 were false positives — including its only security claim — and 1 was a real, new bug (4 of 8 comments false). Recall was poor: run 1 matched one council Important and missed another in a file it did review. Full coverage of 23 files took 51 min on a local MoE; OpenRouter Qwen reached 5/23 in 16–26 min.
- **Release cadence:** a release every 1–3 days. Pin the version and the manifest `schema_version`.

**Verified about the CURRENT codebase (draft-2 review; these reshaped §5–§7):**

- **`reviewer.google.model` reached an unquoted shell assignment until v0.9.3.** `printf 'reviewers:\n  google:\n    model: "gemini-3 ; id"\n'` → the reader emitted `reviewer.google.model=gemini-3 ; id` verbatim, exit 0, no note. **Fixed by `bc763af` (v0.9.3, PR #15)**: the `modelslug` kind §6 specified now guards every `reviewers.*.model`. Re-verified 2026-10-12: the reader prints `invalid value 'gemini-3 ; id'; using default` and emits `reviewer.google.model=`.
- **No code compares reviewer families.** `grep -rn family scripts/*.sh` returns two hits, both inside comments. Every family decision in the pipeline is **an LLM reading prose**. This is why reader-side derivation is necessary but *not sufficient* — see §5.
- **`perplexity/*` and `openrouter/*` slugs exist on OpenRouter today.** Verified against the live model list: 5 `perplexity/*` (e.g. `sonar-pro`, `sonar-reasoning-pro`, `sonar-deep-research`) and several `openrouter/*` meta-namespace slugs (`openrouter/fusion`, `openrouter/pareto-code`, `openrouter/free`). `:free` variants exist too (e.g. `tencent/hy3:free`); `:online` was **not** observed in that sample. See §5 and §6.

**NOT verified — documentation only.** This is why opencode is gated behind a spike:

- `opencode run` non-interactive; `--model provider/model`; `OPENCODE_CONFIG` pointing at an out-of-project config; `{"permission": {"edit": "deny", "bash": "deny"}}` leaving read/grep/glob usable. **opencode is not installed here — none of it has been executed.**
- **OpenRouter `:variant` semantics** (`:free` retention terms, `:online` search hop). Asserted in §6 from documentation; the refutation pass could not confirm them from the repo. Treat as unverified.

**NOT verified — `ocr`, still open after the source read:**

- **The full `severity` vocabulary.** Only `high` and absent were observed in JSON; spike prose also used *medium* and *low*. Pin it from source before writing the mapper.
- **How `rule_config_sha256` is computed** (raw `--rule` bytes or the resolved rule set) — this decides how §12.2's post-run hash check gets its expected value.
- **The `terminal_state` / `status` values** beyond `complete` and the shape of a real `failed[]` item: run 5 had none, so the bats fixture's failed entry is synthetic (§12.7).
- **That the tool set is read-only.** Four tools observed, none of them writes; whether the embedded set has any other tool, and whether a pinned `--tools` file is honoured, are both unverified (§12.2).
- **What a temp `HOME` breaks.** It also hides `~/.gitconfig` (`safe.directory`, `includeIf`, credential helpers); a local diff should not need any of them — confirm on a real run.
- **What an HTTP 402 looks like** — most likely `failed[]` items with `classification: provider`; confirm with a zero-credit key.

## 4. Config schema

```yaml
reviewers:
  custom:
    qwen:                                    # slot name — user-chosen
      enabled:  true                         # default true
      harness:  ocr                          # REQUIRED. P1: ocr | P2+: + codex | P3+: + opencode
      provider: openrouter                   # ocr: openrouter | ollama · codex (P2): openrouter
      model:    qwen/qwen3.8-max-0902        # default EMPTY → slot OFF. No default model, ever. Determines family.
      api_key_env: OPENROUTER_API_KEY        # optional: the NAME of the key's env var, never the key
```

Three layer keys, nothing implied; `api_key_env` is plumbing, not a layer. Each axis extends independently: a new harness is one enum value, a new provider is one enum value, a new model is just a string.

**Opt-in, off by default — structurally.** No slot exists until a user names a `harness` *and* a `model`; nothing is shipped pre-configured, and no default model is baked in (§12.8 records the spike evidence, non-normatively). `harness` has no default because draft 3's default (`codex`) is no longer Phase 1, and a default that changed between phases would migrate configs.

**The schema is final from Phase 1** — later phases only widen the enums and lift the slot cap. No config ever migrates.

| key | default | validation |
|---|---|---|
| `enabled` | `true` | bool |
| `harness` | *(none — required)* | enum; empty or invalid → note + slot skipped |
| `provider` | `openrouter` | enum, **per harness** (`ocr`: `openrouter`, `ollama`); invalid → note + slot skipped |
| `model` | *(empty)* | **`modelslug` kind** (§6); non-empty → slot on; family from §5's map |
| `api_key_env` | per provider: `OPENROUTER_API_KEY`; none for `ollama` | **`envname` kind** (§6); ignored for `ollama` |
| `family` | *(computed)* | the slot's family from §5's map, **already canonical**, `unknown` included — the only family value emitted |

**There is exactly one family key, and it is already canonical.** Draft 2 emitted both a raw `family` and a `family_canonical`, which inverted the safe default: the attractive name was the one that must never be used for routing, while every consumer sentence in `skills/run/SKILL.md` says *"family"*. An LLM consumer had only prose stopping it from grabbing the wrong key — for a guard whose failure silently deletes findings (§5). Emitting one already-canonical `family` makes the footgun structurally unreachable and leaves every existing consumer sentence correct unmodified. **No raw vendor prefix is emitted**: reports attribute a slot by its model slug (`kimi (moonshotai/kimi-k2.7-code)`), which is strictly more informative to a human than a bare vendor.

**Three charset guards, three different sinks** — see §6 for why each exists and when it must run:

| value | rule | why |
|---|---|---|
| slot **name** | `^[A-Za-z0-9_-]{1,32}$` | reaches a **yq expression** and the emitted key namespace |
| model **slug** | `^[A-Za-z0-9~@][A-Za-z0-9._:~@/-]{0,127}$` | reaches a **shell command position** — the existing `valid_modelslug` |
| key env **name** | `^[A-Za-z_][A-Za-z0-9_]{0,127}$` | reaches an **indirect expansion** and an **env assignment** — the existing `valid_envname` |

The slug rule is anchored (no leading `-`) and bounded, and already admits bare Ollama tags such as `qwen3.6:35b-a3b-coding-nvfp4`. Excluding `.` from slot names is intentional: it keeps `reviewer.custom.<name>.<key>` at a fixed four dot-segments. Excluding `,` from all three is what makes the comma-joined list unambiguous. **There is no URL key** — endpoints are council literals (§6).

**Emission shape.** Emitted **only when at least one valid slot survives** — with no config, not one byte of this appears:

```
reviewer.custom_slots=qwen,kimi-local
reviewer.custom.qwen.enabled=true
reviewer.custom.qwen.harness=ocr
reviewer.custom.qwen.provider=openrouter
reviewer.custom.qwen.model=qwen/qwen3.8-max-0902
reviewer.custom.qwen.api_key_env=OPENROUTER_API_KEY
reviewer.custom.qwen.family=Qwen
```

The list sentinel is `reviewer.custom_slots`, **outside** the per-slot namespace. Draft 2 used `reviewer.custom.names`, which a slot legitimately named `names` would shadow (`reviewer.custom.names=names` beside `reviewer.custom.names.model=…`) — and config-invariance rests on that one key's absence. Consumers treat an **absent** `reviewer.custom_slots` as "no custom slots."

## 5. Identity & family derivation

Family is **computed, never trusted** — pure string manipulation, so it belongs in the deterministic, testable config reader.

**But computing is not enforcing, and this is the thing draft 2 got wrong.** There is **no string-equality comparison of families anywhere in the code** — `grep -rn family scripts/*.sh` finds only comments. Every family decision is **an LLM reading prose** in `skills/run/SKILL.md`. So reader-side derivation is **necessary but not sufficient**: it computes a correct value that nothing *obliges* the consumer to use. Phase 1 must therefore ship **derivation *plus* an explicit prose obligation at every comparison site**, or the derivation is decoration.

**The canonical namespace is a pinned literal set** — the map's whole output set, nothing else:

- **native** — `Claude`, `OpenAI`, `Google`. **`OpenAI` is the native Codex seat's family**: the pipeline's verifier list (`skills/run/SKILL.md` → 4.2) calls it `Codex`, and Phase 1's touch list makes `Codex = OpenAI` explicit there, or an LLM consumer is left to guess.
- **distinct** — `Qwen`, `Moonshot`, `Zhipu`, `DeepSeek`.
- **`unknown`** — everything else.

Note `Claude-fresh`, which appears in the verifier-routing rule, is a **verifier-spawn label, not a family**; reconciling that wording is part of Phase 1's touch list, because an implementer currently cannot tell whether the target set is `{Claude, …}` or `{Claude-fresh, …}`.

**Derivation — a fixed prefix map, first match wins:**

```
strip ALL leading "~"                       ~~moonshotai/kimi-latest → moonshotai/kimi-latest
lowercase the whole slug
match a prefix, at a boundary               the prefix must be followed by end-of-string,
                                            "/", "-", ".", ":" or a digit
  qwen             → Qwen                   (covers OpenRouter qwen/* and bare Ollama qwen3.6:…)
  moonshotai/kimi  → Moonshot
  z-ai/glm         → Zhipu
  deepseek         → DeepSeek
  anthropic/claude → Claude
  openai/gpt       → OpenAI
  google/gemini    → Google
no match                                    → unknown
```

A slot is **distinct** iff its family is in the distinct set. `Claude`, `OpenAI`, `Google` and `unknown` are all **non-distinct**: `unknown` is treated as the same family as *every* native seat, which is the conservative reading. What each outcome means in the council is §7's [Distinct vs non-distinct](#distinct-vs-non-distinct).

| model | `family` | distinct? | note |
|---|---|---|---|
| `qwen/qwen3.8-max-0902` | `Qwen` | yes | spike #1–#2 model (OpenRouter) |
| `qwen3.6:35b-a3b-coding-nvfp4` | `Qwen` | yes | bare Ollama tag (spike run 5) |
| `moonshotai/kimi-k2.7-code` | `Moonshot` | yes | the untested next candidate |
| `~moonshotai/kimi-latest` | `Moonshot` | yes | `~` = OpenRouter latest-alias |
| `z-ai/glm-5` | `Zhipu` | yes | |
| `deepseek/deepseek-v4`, `deepseek-r1:32b` | `DeepSeek` | yes | vendor-prefixed or bare |
| `anthropic/claude-opus-latest` | **`Claude`** | no | collides with native Claude |
| `openai/gpt-5.6` | **`OpenAI`** | no | collides with the Codex seat |
| `google/gemini-3` | **`Google`** | no | collides with the Google seat |
| `x-ai/grok-4`, `perplexity/sonar-reasoning` | `unknown` | no | not on the map — runs, earns no cross-family credit |
| `openrouter/fusion`, `@preset/my-thing` | `unknown` | no | meta-router / preset: family underivable |
| `qwenfake/x` | `unknown` | no | `qwen` not at a boundary |

**Runtime cross-check.** The reader derives the family from the *configured* slug; §12.5's mapper derives it again from `manifest.execution.model`, the model ocr reports it *actually* ran, and uses that. If the two disagree, the slot's family for the run is `unknown` and the report says so. This is the "enforce, don't just compute" check: a silently-wrong per-run config (§12.2) cannot launder one model's findings under another family's name.

**Why canonicalization is mandatory.** The pipeline's family decisions are prose comparisons against `Claude` / `Codex` / `Google`. A raw vendor slug means nothing there, so the outcome is **nondeterministic** — an LLM *might* resolve `anthropic` → Claude on its own, which is worse for testing than a reliable failure. Without a canonical value, a slot configured `anthropic/claude-opus-latest`:

1. **Can silently delete findings.** If the "a model does not verify its own finding" guard doesn't fire, Claude refutes its own finding and the judge drops on REFUTED — including findings from the dedicated Security reviewer. *(Phase 1 closes this a second way too — see §7's finder-only rule.)*
2. **Fabricates corroboration.** Native Claude + the `anthropic/*` slot present as two families, firing the `+1 tier` promotion on manufactured diversity. **This one is not closed by finder-only** — a slot can fabricate corroboration purely as a finding *origin* — so correct canonicalization is load-bearing regardless. Draft 4 closes it by rule rather than by label: a non-distinct slot's findings **never count toward corroboration** (§7), so a wrong label can at worst cost credit, never manufacture it.

**Underivable means `unknown`, not rejected.** Draft 3 rejected `@preset/*`, `openrouter/*` and bare names because **their family is underivable from the string** — a preset pins an arbitrary model server-side; a meta-router dispatches per request and frequently lands on Claude or GPT. Guessing a family for these is exactly the harm above. Draft 4 keeps the reason and changes the outcome: they map to `unknown`, which is **non-distinct**, so they can run as finders but can never be cleared as a distinct family. Same safety, and the user can still run any model.

**Bare Ollama tags are prefix-matched.** This resolves draft 3's Phase-3 open decision for vendorless slugs. An Ollama tag is a name on the user's own machine; a reviewed repo can name one in config but cannot create one, so a mislabelled tag (`ollama cp <claude-proxy> qwen-x`) is self-inflicted, not an attack.

**Caveat worth revisiting:** the map is a judgment call about vendor identity, not a derivable fact. It lives in **one function** (the reader and §12.5's mapper both call it), with a table-driven bats test, and is reviewed when providers change. **The map is the one plugin PR the goal still needs:** any model *runs* without an entry; only cross-family credit needs one. Add a test asserting the map's value set equals the canonical set above, so the known-vendor cases are checkable and only genuinely novel vendors need human review.

## 6. Security model

**The live sink draft 3 found is closed (v0.9.3). The `ocr` harness adds new config→command paths — model, provider, key-env name — and each goes through an existing reader guard before it can reach one.**

Draft 2 claimed Phase 1 introduced "exactly one new data path… and closes it at the reader." That was false in two directions, and the exhaustiveness claim was the dangerous part — an implementer trusting the audit would scope the guard to custom slots and ship a security section asserting a class was closed while an older, identical door stood open.

**Sink 1 — the model slug reaches a shell command position.** The reader's generic string validation rejects **only control characters**; spaces, `;`, `|`, backticks and `$(...)` all pass. The orchestrator then interpolates a model value **unquoted** into a Bash line it composes. This was live until v0.9.3 via `reviewer.google.model`:

```
$ printf 'reviewers:\n  google:\n    model: "gemini-3 ; id"\n' > .review-council/config.yml
$ ./scripts/rc-config.sh .review-council | grep google.model
reviewer.google.model=gemini-3 ; id          ← verbatim, exit 0, no note   (before bc763af)
reviewer.google.model=                       ← with a stderr note          (v0.9.3+, re-verified 2026-10-12)
```

Note this fires in the **orchestrator's own session, outside any sandbox** — not inside codex's seatbelt. And **double-quoting would not save it**: `$(...)` expands inside double quotes. Only the reader-side guard is a real defense, which makes the plugin's own maxim — *never rely on an LLM to quote correctly* — more right than draft 2 realised.

**Fix — shipped independently in v0.9.3 (`bc763af`, PR #15):** a **`modelslug` kind** in the reader's validator (`valid_modelslug`), applied to **every** `reviewers.*.model` through one tested guard. Phase 1 applies the same kind to custom slots. `^[A-Za-z0-9~@][A-Za-z0-9._:~@/-]{0,127}$` admits `gemini-3-pro`, `sonar`, `moonshotai/kimi-k2.7-code`, `~moonshotai/kimi-latest`, `openai/gpt-4o:free` and the Ollama tag `qwen3.6:35b-a3b-coding-nvfp4` alike, with no behavioural loss. It must run **before** family derivation. Single-quoting the orchestrator's template is defence-in-depth on top, not the guard. **`provider`** is an enum and reaches `ocr --provider` and the council-written config file only as one of its literal values.

**What actually stops argv injection** is worth stating precisely, because draft 2 credited the wrong mechanism: the charset **excludes `=`**, which blocks clap's attached short-flag form (`-cKEY=VALUE`) — and `-c` is codex's config-override flag, the only single token that could redefine `model_providers` and thus the endpoint. The anchor (no leading `-`) removes any dependence on clap's hyphen handling at all — and equally on `ocr`'s Go flag parser: whatever it would do with a value starting `-` (a would-be `--rule=…` that re-points the rule file), the anchor means it never sees one. *Draft 2 claimed `--model` "consumes its value positionally"; that description of clap is wrong and the refutation pass could not verify it from the repo. Do not restore it, and do not relax `=` out of the charset.*

**Sink 2 — the slot name reaches a yq expression.** The reader must build `.reviewers.custom.<name>.model` by interpolating an untrusted YAML map key. mikefarah yq is an **expression evaluator** with `load()` and `env()`, not an inert path lookup, so an unvalidated name is an expression-injection primitive. The reader already interpolates path fragments into yq expressions — safe today only because every such fragment is a hardcoded literal. **Slot names would be the first user-supplied value in that position.**

**Ordering is the whole guard here:** names are discovered *by* running `yq keys`, so validation must sit **between enumeration and any re-interpolation**. Enumerate → validate each name against `^[A-Za-z0-9_-]{1,32}$` → only then build a yq path or an emitted key. A name that fails is dropped with a note.

**Sink 3 — the key env-var name reaches an indirect expansion and an env assignment.** `api_key_env` names the variable that holds the key; the dispatch script reads it by indirect expansion and exports its value under the name `ocr` reads (`OPENROUTER_API_KEY`, §12.2). It is validated with the existing **`envname` kind** at the reader and **re-checked before use** in the dispatch script — the same defence in depth `rc-post.sh` applies to `pr_comments.bot_token_env`. The value never appears in config, in argv, or in the council-written `config.json`.

**What holds structurally:**

- **The endpoint is a council literal, per provider.** OpenRouter → `https://openrouter.ai/api/v1`; Ollama → `http://localhost:11434`. Config cannot choose the *host*, and **Phase 1 has no URL key**. A future URL key is charset-validated *and* blocked from repo config until the trust layer (Phase 4): a URL and a key name from the same untrusted source make a complete exfiltration primitive.
- **The key env var *name* may come from config; the value never does.** Draft 3 held that a config-named env var is a secret-exfiltration primitive. That is true only if config can also choose the host. With the host a council literal, a hostile `api_key_env: AWS_SECRET_ACCESS_KEY` can at worst send *another* secret to the configured provider — never to the attacker. That is the exposure `pr_comments.bot_token_env` already accepts for GitHub. **Residual, flagged:** it is still disclosure to a third party; see §12.9 for narrowing the name.
- **The argv is built without `eval`.**
- **The OpenRouter data policy is council code.** `provider: {data_collection: "deny"}` is **hard-coded** and sent on every OpenRouter call (via `providers.openrouter.extra_body` in the council-written config, §12.2). It is never read from repo config or from the user's `~/.opencodereview/config.json`, which nobody reviews — the same precedent as deployhq's `Ai::Client`. It controls training, not where the code goes, and a provider's data record is largely self-declared.
- **The reviewed repo cannot steer `ocr`'s prompts.** Its `.opencodereview/rule.json` is displaced by a council-owned `--rule` file, checked before and after the run (§12.2). Inputs that remain (source): the repo's root `.gitignore`, and any file the model opens with its tools — the same untrusted-content exposure every reviewer has. `.md`/`.txt` files referenced by the repo's rules are moot once its rules are displaced.
- **No dependency on, or mutation of, the user's `~/.opencodereview/`.** Each run gets a throwaway `HOME` (§12.2); its sessions die with it.
- **Read-only is enforced by the harness, at different layers.** `codex`: kernel sandbox — but see §9: Phase 2 must *assert* this, not assume it. `ocr`: **agent layer** — its tool set has no write or shell tool — observed, not proven; Phase 1 asserts it with a canary and a per-run tool tripwire (§12.2).

**What the fixed endpoint does NOT control — the `:variant` suffix.** The allowlist deliberately admits `:`, and an OpenRouter slug's variant is a **routing and data-policy directive**, not just identity. `:free` routes to free endpoints whose retention/training terms differ from paid ones; `:online` reportedly activates a web-search plugin, sending review-derived content to a **fourth party** absent from `CLAUDE.md`'s egress disclosure. So the precise claim is: *config cannot choose the host; it can still choose the variant, and the variant selects the serving endpoint and its terms.* **Decide the variant policy in Phase 1, while there are zero callers** — either reject `:` suffixes not on a known-benign allowlist, or reject `:online` specifically. **Scope it to `provider: openrouter`:** for Ollama, `:` is the tag separator (`qwen3.6:35b-a3b`), not a routing directive. *(Marked unverified: the refutation pass could not confirm variant semantics from the repo. Verify against OpenRouter's docs before acting.)*

**The threat model.** A repo-committed `config.yml` is **untrusted input** — the reader loads it from the *reviewed repo's* CWD. `config.local.yml` being gitignored is a **convention, not a boundary**: a repo can simply commit one. **There is no out-of-repo config layer today.** That fact drives §7's finder-only rule and Phase 4's block. It also means a reviewed repo can switch on an `ocr` slot — but it runs only on a key the *user* exported, and it can only add `[unverified]`-or-refutable findings.

**Egress** grows in scope: review context reaches the configured provider and the model's host. For `qwen/qwen3.8-max-0902` on OpenRouter that is **one host, Alibaba**; for Ollama it is **none** (localhost). `CLAUDE.md`'s disclosure must be extended to name custom slots and the `ocr` provider path — and the variant hop, if the variant policy admits one.

## 7. Council semantics

A custom slot is repo-capable, so its **findings** are of comparable quality to Claude/Codex/Google — not the tool-less Perplexity shape. **What else it does depends on the harness.**

| | `codex` slot (Phase 2) | `ocr` seat (Phase 1, §12) |
|---|---|---|
| `min_reviewers` / council mode | counts | **never counts**, and never lifts solo-Claude mode on its own |
| lens | Correctness & concurrency + one specialist overlay | **none** — ocr runs its own prompts; it consumes no overlay |
| finding origin | yes | yes |
| its findings | refutable by other families | distinct family: refutable · non-distinct: `[unverified]` |
| verifier | never (below) | never (below) |

**Why the `codex` slot gets a lens:** the lens-assignment rules enumerate the frontier reviewers as a **closed list**; that set must become data-driven or the slot is configured, dispatched, and silently never given a lens. Custom slots iterate **after** Claude, Codex, Google, keeping existing lens maps byte-identical when none is configured.

**Why the `ocr` seat gets neither:** a lens needs the `## LENS` block, and ocr's only prompt channels are `--rule` and `--background` — the first is pinned neutral (§12.2), the second is not used. Not counting toward `min_reviewers` follows from finder-only and fail-soft: a seat that cannot verify cannot supply the cross-family check council mode exists for, and a seat that may time out at minute 40 must not be what keeps a run above the threshold. The lens map shows it as `<slot> (<model> via ocr) — no lens`.

### Custom slots are FINDER-ONLY until the trust layer (Phase 4)

**A custom slot is not eligible as a refutation verifier.** This reversed draft 2, and it was the most consequential change in draft 3.

The reasoning is forced by the spec's own threat model. Repo-committed config is untrusted; **all** config is repo-sourced today (there is no out-of-repo layer); and the judge **drops a finding on REFUTED**. Granting verifier authority to a config-named model therefore hands an adversary both halves of the primitive: they choose the verifier's model *and* author the diff text it reads. A hostile repo could seat a weak or injectable model and steer it toward REFUTED verdicts against the dedicated Security reviewer's findings, which then vanish from the report. The mitigation draft 2 relied on — *"only positive counter-evidence drops a finding"* — is prose to an LLM, not a mechanism.

**Nothing config can do today has this power.** `settings.verify: false` explicitly *keeps* findings as `[unverified]`; disabling a reviewer only reduces coverage. Phase 1 would have been the first config key able to make a finding disappear.

**The asymmetry is the point:** a custom slot can **add** findings (low harm — the judge curates, the cap applies, other families can refute them) but cannot **delete** them (high harm — silent and irreversible).

**Honest cost.** This removes one of the feature's original selling points: a custom slot does **not** strengthen the refutation pass by adding a verifier family. Extensibility — any model, no plugin PR — survives intact, and repo-capability still makes its findings far better than a tool-less slot's. **Lifting this restriction requires the out-of-repo trust layer** (`~/.review-council/config.yml` or env-only): a slot enabled from a source the reviewed repo cannot write may safely verify. That is the natural companion to Phase 4's `base_url` work.

### Distinct vs non-distinct

Decided by the user for draft 4, and deterministic from §5's map:

- **Distinct family** (`Qwen`, `Moonshot`, `Zhipu`, `DeepSeek`) → the seat's findings enter Step 4 like any single-family finding and are refuted by a *different* repo-capable family, e.g. Claude-fresh. When the only non-Claude seat is a distinct `ocr` seat, Step 4 runs **for the seat's findings only**; the native findings stay `[1 reviewer · unverified]` as in solo-Claude mode today.
- **Non-distinct** (`Claude`, `OpenAI`, `Google`, `unknown`) → **allowed** — the user explicitly wants to run, say, a Claude model through ocr — but the seat's findings skip Step 4 and stay `[unverified]` (or `[1 reviewer · unverified]` in solo-Claude runs). They **never count as cross-family corroboration**: a fingerprint raised by native Claude and a `Claude`-family or `unknown` seat is a same-family pile-up and is not promoted. `unknown` gets this rule against **every** native family, because it might be any of them.

Either way a seat's finding is never *deleted* by being non-distinct: absence of refutation is `[unverified]`, never REFUTED.

### Availability

A custom slot is **available** iff **all** of:

```
enabled = true
  ∧ harness is set and valid for this phase
  ∧ model is non-empty and passes the modelslug guard   (family may be unknown)
  ∧ the harness binary resolves          (same contract Codex/Google use)
  ∧ the provider's key env var is set and non-empty   (OpenRouter: the var api_key_env names; Ollama: none)
  ∧ ocr only: jq resolves, and the target is a diff     (PR, branch range, commit, working tree)
```

A plan or document target has no diff for ocr to review: the seat is skipped with a note. This mirrors the established Perplexity precedent (available iff its key is set). Two paths that must not be conflated: an **absent** key is a detection-time skip with a note; an **invalid** key is a runtime failure attributed **to the slot**. Each slot is probed independently — **native Codex's auth state must never decide a custom slot's availability, and a custom slot's provider failure must never decide native Codex's.** They share a binary, not an identity.

### The one-slot cap (Phases 1–4)

**At most ONE custom slot participates**, and the cap applies to the **available** set, *after* the availability filter — never to the raw configured list. (Taking the first *configured* name would pick a disabled or uninstallable slot, drop it at the availability check, and leave zero custom reviewers while a good one never ran.)

**The winner is the first available slot in config document order** (which `yq keys` preserves), so it is predictable from reading the config top-down and reproducible across runs. Slots skipped by the cap are reported explicitly, never silently.

### Consumers of `family`

Phase 1 must update **every** site that reasons about families — not just routing:

- **Verifier routing** — the family list (with `Codex = OpenAI`), the rule that a verifier's family must differ from the finding's origin, and the rule that a non-distinct seat's findings are not routed at all.
- **The judge** — the origin-family **union**, and the **`≥2 different families` +1-tier promotion**. §5's *second* harm (fabricated corroboration) lands here, and finder-only does **not** close it — the non-distinct rule does, but only if the judge applies it. Omitting the judge ships a half-implemented rationale whose failure is silent and produces a *stronger-looking* report.
- **Detection** — the `min_reviewers` count and the solo-Claude test (`skills/run/SKILL.md` → "only Claude-family reviewers"), which must both ignore an `ocr` seat.

## 8. Design decisions

| decision | rationale |
|---|---|
| Borrow a harness; write no agent loop | The plugin has never owned one. Writing one means a tool loop **plus a sandbox** — security-critical, untenable in POSIX sh, and would force a new runtime. |
| Slot = model identity, not harness | Family drives corroboration. Two harnesses running one model is one vote. |
| Family computed from the slug | Removes a whole class of user error and of fake diversity. |
| **Exactly one family key, already canonical** | Draft 2's `family` + `family_canonical` made the attractive name the unsafe one, defended only by prose to an LLM. One canonical key makes the footgun unreachable and leaves existing consumer prose correct. |
| **Derivation *and* prose obligation** | No code compares families — every decision is an LLM reading prose. Computing a value the consumer isn't obliged to use is decoration. |
| **`modelslug` guard on every `reviewers.*.model`** | The sink was live on `google.model`. A custom-only guard would have closed the new door and left the old one open. **Shipped in v0.9.3.** |
| **Finder-only until the trust layer** | Untrusted repo config must not gain finding-**delete** authority. Adding findings is low-harm; deleting them is silent and irreversible. |
| Charset-guard at the reader, before use | The reader is deterministic and testable; an LLM quoting a prose template is neither. Ordering is part of the guard, not a detail. |
| `harness` crosses the transport boundary explicitly | Keying dispatch on the provider alone re-conflates two of the three layers §2 separates, and would force a breaking change in Phase 2. |
| Slot name `custom.<name>`, not `openrouter` | `openrouter` names the *provider* layer — the same category error one level up. |
| Empty `model` default → slot off, **no key emitted** | Preserves config-invariance literally. |
| **`ocr` first (P1), `codex` next (P2)** | The user's call after spikes #1–#2: `ocr` was run end to end on a real diff, with five model setups. `codex` stays empirically proven (§3) and becomes the second harness. |
| **`ocr` is a Round-1 seat, not a Step 2.5 / Tier B source** | Step 2.5 runs serially *before* Round 1, and `ocr` takes tens of minutes; its output is LLM claims that need refutation, not tool facts. |
| **Family from a fixed prefix map; `unknown` = non-distinct** | Deterministic and testable. A wrong or missing entry can only *withhold* cross-family credit, never manufacture it. |
| **Non-distinct seats allowed, but `[unverified]`** | The user wants to run any model through ocr, Claude and GPT included. Running is harmless; counting it as a second family is not. |
| **No default model** | Spike evidence is three models deep and mixed (§12.8). A baked-in default would be a recommendation the evidence doesn't support. |
| **`api_key_env` from config; host from code** | A config-named key is safe only while the host is a council literal (§6). The two never come from the same untrusted source. |
| **`data_collection: "deny"` hard-coded** | A data policy read from config is a policy the reviewed repo chooses. |
| **Coverage manifest always printed** | Partial coverage is the normal case at the default budget (§12.3). A seat that silently reviewed 5 of 23 files reads as a clean bill of health on the other 18. |
| **Gate on parsed JSON, never on exit code** | `ocr` exits 0 on partial and skipped runs (§3). |
| opencode deferred behind a spike | Unverified, and enforces read-only at the **agent** layer vs codex's **kernel** layer. A silent fallback would make the slot's real safety depend on which tool won, invisibly. **`ocr` is agent-layer too**, and is accepted on different terms: its tool set has *no* write or shell tool (rather than a deny switch on one), and Phase 1 asserts that with a canary and a per-run tripwire. |

## 9. Risks

- **`ocr`'s read-only boundary is its tool list, and that list is configurable.** Four read-only tools were observed; nobody has proven the embedded set has no other, and `--tools <json>` can replace it. A release that adds a write or shell tool would silently change the seat's safety. **Phase 1 asserts it**: a write canary per release, and a per-run tripwire on `tool_calls.by_tool` (§12.2) — which detects after the fact, so it is a tripwire, not a sandbox.
- **`ocr` is the long pole.** It takes tens of minutes against a 600 s default budget. If its timeout ignored the budget, refutation would be skipped for *every* finding, not just the seat's. §12.3 sizes it to leave a reserve, so at the default budget **expect partial coverage**.
- **`ocr` precision is low.** 4 of 8 comments were false in spike #1, including its only security claim; the local MoE produced about 1 partly-valid comment in 9. The seat adds judge-curation load, which is why it is finder-only and never originates a Critical (§12.5).
- **`ocr` moves fast.** A release every 1–3 days. Pin a tested version range and the manifest `schema_version`; treat anything else as a degrade, not a guess.
- **`ocr` doesn't dedupe across files.** Spike #1 repeated one concern once per config file (×3). The judge's fingerprint keys on the path, so these stay three findings; the report's suggestion cap absorbs them.
- **The sandbox is Phase 2's whole safety rationale, and nothing checks it.** §8 justifies the codex harness with "kernel sandbox," but §3 verified only that the flag is *accepted* — not that a write is *denied*. An argv test pins what we **pass**, not what the sandbox **enforces**; it stays green if a future codex accepts `--sandbox read-only` and ignores it for custom providers. The spec supplies its own base rate for that drift: `wire_api="chat"` vanished out from under the docs. **Phase 2 must assert denial at runtime** (see its gates), and the re-pin item below must cover the **sandbox surface**, not just the argv.
- **Codex's custom-provider surface could change.** Re-pin from `--help`; update the argv test in lockstep.
- **Model-metadata fallback**: Codex warns it "can degrade performance." Unquantified; benign in testing.
- **Hard dependency on `codex`** (Phase 2). Mitigated: a free binary needing no OpenAI account (§3). Phase 3 removes even that.
- **Weak/hostile custom model.** Finder-only (§7) removes the delete primitive. Residual: a weak model adds noise the judge must curate, and could fabricate cross-family corroboration as an origin — which is why §5's canonicalization and the non-distinct rule stay load-bearing.
- **Context-window mismatch.** No negotiation exists anywhere in the pipeline. A small-context model may silently truncate the diff and review a fragment confidently. (`ocr` groups files and caps prompts with `--max-tokens`, which narrows this for its seat.) Deferred to Phase 5.

## 10. Out of scope

Generic user-supplied `base_url` (needs the Phase 4 trust layer); an in-plugin agent loop; MCP transport for custom slots; per-slot lens pinning; context-window negotiation; `ocr` as a Step 2.5 / Tier B source (§8).

**To evaluate, not designed — `ocr` delegate mode.** `ocr delegate preview` / `ocr delegate rule` return the files to review and the resolved rules, and the *host* agent does the review with its own model, with no API key. That adds **no new model family**, so it is no council seat. It may still be a cheap, deterministic **coverage helper** for the existing seats (which files a diff selects, and which rule applies). Evaluate separately.

## 11. Reviewed-and-rejected

Findings raised and **REFUTED**, recorded so they aren't re-raised:

- **"Hyphenated slot names break the yq path."** Claimed `-` would lex as mikefarah yq's subtract operator, silently dropping the slot. **Refuted by direct execution** on yq v4.53.3: the lookup returns the value and `keys` enumerates `qwen-local` correctly. Both reviewers who raised it were Claude-family; Codex settled it by running the command. A regression test should pin the behaviour.

## 12. The `ocr` harness (Phase 1)

Alibaba OpenCodeReview — the `ocr` CLI (Go, Apache-2.0), **pinned at v1.12.13** — is the first concrete harness. It is a **finder-only Round-1 seat**: opt-in and off by default (§4), running in parallel with the other seats, with a user-chosen model. Evidence for every claim here is in §3 and on #21.

### 12.1 Where it sits

```
Step 2.5  static scan     unchanged — ocr is NOT a Tier B source (§8)
Step 3    Round 1  ──┬──  Claude · Security · Codex · Google · Perplexity
                     └──  ocr seat → mapper (§12.5) → §3.1 findings + FAMILY + COVERAGE lines
Step 3.5  join barrier    waits for the seat; never retries it, never asks the user about it
Step 4    refutation      distinct family: its findings are routed · non-distinct: skipped → [unverified]
Step 5    judge           a non-distinct seat never counts toward corroboration
Step 6    report          roster + lens map ("no lens") + the coverage line (§12.6)
```

`ocr` reviews a git range it computes itself, so it does **not** receive the shared baseline package; it reads the repo through its own tools. That is a real deviation from "identical context for every reviewer", and the coverage line is how it stays visible.

### 12.2 Invocation

Everything below rests on §3 — *verified against ocr v1.12.13 source*, `--help`, or the spike runs — unless marked. One run, in the dispatch script, POSIX `sh`, no `eval`:

**1. Isolate.** Create a temp dir `$T` and use it as `HOME` — ocr has no `--config` flag and no `OCR_CONFIG`/`OCR_HOME`. Write into it:

- `$T/.opencodereview/config.json` — **council-owned**: the provider stanza with its council-literal endpoint, the configured model, and for OpenRouter `providers.openrouter.extra_body = {"provider":{"data_collection":"deny"}}`. **No `api_key`**: ocr reads the key from the provider's env fallback (`OPENROUTER_API_KEY`, `resolver.go:443-453`).
- a council-owned rule file `$R`, byte-for-byte: `{"rules":[{"path":"**","rule":"","merge_system_rule":true}],"exclude":["__none__"]}`. The dummy `exclude` is **required**: the first rule layer with any include/exclude is used whole, which is what displaces the repo's `.opencodereview/rule.json`.

The user's own `~/.opencodereview/` is never read or written. Sessions land in `$T` and are deleted with it.

**2. Pre-flight — no LLM call.** Under the same environment as the run:

- `ocr rules check --rule "$R" <a changed path>` must report `Source: Custom (--rule)` — pass `--rule` explicitly; a bare check reads the repo's layer. Anything else → SKIPPED (`rules not pinned`).
- `ocr review --preview --format json --rule "$R" --from "$base" --to "$head"` → the list of changed files ocr will **exclude** and why. Exclusions do not appear in the review JSON, so this is the only source for §12.6's exclusion count.

**3. Run**, under `run_capped` (which closes stdin):

```sh
(
  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL   # else a Claude Code host's vars leak in
  HOME=$T OCR_NO_UPDATE=1 OCR_LLM_TIMEOUT=$per_request_s
  OPENROUTER_API_KEY=$key        # value of the var api_key_env names; envname re-checked first; OpenRouter only
  export HOME OCR_NO_UPDATE OCR_LLM_TIMEOUT OPENROUTER_API_KEY
  run_capped "$hard_cap_s" "$T/run.log" \
    ocr review --repo "$root" --from "$base" --to "$head" \
      --format json --audience agent -o "$T/out.json" \
      --rule "$R" --provider "$provider" --model "$model" \
      --effort low --timeout "$deadline_min"
)
```

`$base`/`$head` come from the council's own target resolution in **local git, never from config** — the same invariant as the PR-digest target. `--effort low` (one round) is pinned in Phase 1 so §12.3's sizing is exact. JSON goes to `-o`, because `run_capped` merges stdout and stderr into its log.

**4. Post-run checks — enforce, don't just compute:**

| check | on failure |
|---|---|
| JSON parses; `manifest.schema_version` is `ocr.run-manifest/v1`; `execution.ocr_version` in the tested range | SKIPPED (`invalid output`) |
| `execution.provider` / `execution.model` equal the configured values | keep findings, family → `unknown`, note (§5) |
| `execution.rule_config_sha256` equals the value pinned at implementation (*how ocr computes it is unverified, §3*) | **discard** the seat's findings, loud note: its prompts may have been steered |
| `tool_calls.by_tool` keys ⊆ `{file_read, code_search, file_read_diff, code_comment}` | **discard**, loud note. A tripwire — it detects after the fact; it is not a sandbox |

Then `rm -rf "$T"`.

### 12.3 Budget, timeouts and degradation

- **The deadline comes from `run_budget_seconds`**, not `reviewer_timeout_seconds` — the one CLI that does this, because it is the expected long pole. `--timeout` is in **minutes** and is multiplied by rounds, so with `--effort low`: `deadline_min = max(1, floor((run_budget_seconds − reserve) / 60))`. The reserve keeps refutation and the judge inside the budget; ⅓ of `run_budget_seconds` is the proposal (§12.9). At the 600 s default that is **6 minutes — expect partial coverage**. A user who wants full coverage raises `run_budget_seconds`; the coverage line tells them when to.
- **The HARD cap must exceed ocr's own deadline**: `hard_cap_s = deadline_min × 60 + grace`, grace ≥ 60 s. On its deadline ocr publishes partial JSON; a wrapper kill leaves **no JSON** and loses every completed file.
- **Per request:** `OCR_LLM_TIMEOUT = min(600, deadline_min × 60)` seconds. Spike #1 lost 6 of 23 files to the 300 s default.
- The seat's measured `ELAPSED` feeds the long-pole budget check like any CLI's.

**Gate on the parsed JSON, never on the exit code** — exit 0 also means *partial* and *skipped*. Every failure degrades the seat to a note; none blocks the review, triggers Step 3.5's retry or ask-the-user flow, or touches another seat. A SKIPPED line is attributed to the slot — `SKIPPED: qwen (ocr) unavailable — ocr: <reason>` — never to Codex.

| condition | how it shows | outcome |
|---|---|---|
| `ocr` or `jq` missing; key var unset; plan/document target | detection | skipped with a note; roster and lens map otherwise byte-identical |
| rules not pinned | pre-flight | SKIPPED |
| wrapper kill | no `out.json` | SKIPPED (`timeout`) |
| invalid JSON, wrong schema, untested version | post-run check | SKIPPED (`invalid output`) |
| error, or nothing covered | `status` / exit 1 | SKIPPED, with ocr's `message` |
| deadline or token budget hit | `failed[]` · `timeout` / `budget` | **partial** — keep comments, print coverage |
| HTTP 402 / provider error | `failed[]` · `provider` *(expected — §3)* | partial; SKIPPED if nothing completed |
| model or rule or tool mismatch | post-run checks | per the table in §12.2 |

### 12.4 Council semantics, in one place

From §7: never a verifier; never counts toward `min_reviewers` and never lifts solo-Claude mode; no lens and no overlay consumed; a distinct family's findings go to refutation, a non-distinct family's stay `[unverified]` and never corroborate. The family that decides this is the **post-run** one (§5's runtime cross-check), which the mapper prints as `FAMILY: <family> distinct=<true|false>` — the orchestrator routes on that line.

### 12.5 Output mapping → §3.1

A deterministic mapper — jq only, no `eval`, no LLM — turns `out.json` into what every reviewer returns: §3.1 findings (`rules/delegation-format.md` → OUTPUT FORMAT), plus the `FAMILY` and `COVERAGE` lines. Like tool-origin findings (`rules/static-analysis.md` → Normalize → §3.1), the synthesized prose fields are **fixed templates**, never LLM-authored; `ocr`'s own text is carried as quoted data.

| §3.1 field | from an `ocr` comment |
|---|---|
| `severity` | `critical`, `high` → **`important`**; `medium`, `low`, `null`, **absent**, anything else → `suggestion`. **Never `critical`**: a finder measured at ~50 % precision does not originate a Critical alone. A cross-family UPHELD can still promote it one tier. |
| `confidence` | `low` — ocr reports none; refutation and the judge recalibrate |
| `location` | `<path>:<start_line>`; `start_line` 0 → `<path>:0` (file-level) |
| `symbol` | `file-level` when `start_line` is 0, else `N/A` |
| `concern` | `ocr:<category>`, lowercased, reduced to `[a-z0-9-]` — e.g. `ocr:maintainability` |
| `issue` | the first sentence of `content`, ≤ 200 chars |
| `why_it_matters` | the rest of `content`, verbatim, quoted as data |
| `recommendation` | `suggestion_code`, fenced, when present; else `No fix proposed by ocr — see issue.` |
| `how_to_verify` | `Open <path> lines <start_line>–<end_line> and check the claim in issue against the code.` + `existing_code`, fenced, truncated |
| `source` | the slot name; the report labels it `<slot> (<model> via ocr)` |

Rules:

- **A comment's `path` must exactly match a `coverage.selected[].path`**, or the comment is dropped and counted. No fuzzy repair: run 5's `dockerignore` (for `.dockerignore`) is dropped, not guessed.
- **`content`, `existing_code` and `suggestion_code` are untrusted text** — model output after reading an untrusted repo. They are emitted as data only: control characters stripped (newline and tab kept), and each fenced with a fence longer than any backtick run inside it. They never reach a command line.
- `groups` and `retry_report` are ignored; `warnings[]` contributes a count to the coverage line.

### 12.6 Coverage in the report

**Always printed when the seat ran** — partial, complete, or zero findings — next to the roster:

```
ocr · qwen (qwen/qwen3.8-max-0902): reviewed 14/23 selected files · 9 failed: provider (9)
      · 20 of 43 changed files excluded before review · 1 comment dropped (path not reviewed) · 0 warnings
```

`reviewed` is `completed + reused` over `selected`; `failed` is grouped by `classification`; the exclusion count comes from the pre-flight `--preview` (§12.2), because the review JSON does not carry it. A SKIPPED seat prints its reason instead. When Step 6.6 posts a digest, the line goes with it. **A file the seat did not review is not a file the council calls clean** — the line exists so nobody reads it that way.

### 12.7 Fixture — a sanitized excerpt of spike run 5

Run 5 (`qwen3.6:35b-a3b-coding-nvfp4`, local Ollama, 51 min) is the basis for the bats fixture. **Excerpt only**: paths genericized, `content` shortened, `existing_code` redacted, `run_id`, repository identity and item hashes dropped. 4 of 9 comments kept — one per mapper case.

```json
{
  "status": "complete",
  "llm": { "provider": "ollama", "model": "qwen3.6:35b-a3b-coding-nvfp4" },
  "summary": { "files_reviewed": 23, "comments": 9, "elapsed": "51m34s" },
  "comments": [
    { "path": "docker/entrypoint.sh", "start_line": 369, "end_line": 377,
      "severity": "high", "category": "other",
      "content": "When the domain is set, the endpoint is built as … <shortened>",
      "existing_code": "<redacted>" },
    { "path": "docker/service/run", "start_line": 27, "end_line": 28,
      "category": "maintainability",
      "content": "The `||` + unconditional `exec` pattern … <shortened>",
      "existing_code": "<redacted>" },
    { "path": "Makefile", "start_line": 0, "end_line": 0,
      "category": "other", "content": "… <shortened>", "existing_code": "<redacted>" },
    { "path": "dockerignore", "start_line": 0, "end_line": 0,
      "category": "maintainability", "content": "… <shortened>", "existing_code": "<redacted>" }
  ],
  "manifest": {
    "schema_version": "ocr.run-manifest/v1",
    "terminal_state": "complete",
    "execution": { "ocr_version": "v1.12.13", "provider": "ollama",
                   "model": "qwen3.6:35b-a3b-coding-nvfp4", "rule_config_sha256": "<sha256>" },
    "coverage": {
      "selected":  [ { "path": ".dockerignore" }, { "path": "Makefile" }, "… 23 items" ],
      "completed": [ "… 23 items" ],
      "failed": [], "reused": [], "waived": []
    }
  },
  "tool_calls": { "by_tool": { "code_comment": 8, "code_search": 11, "file_read": 58, "file_read_diff": 1 } }
}
```

Expected mapping: `high` → `important`; the absent severities → `suggestion`; both `start_line: 0` comments → `<path>:0`, `symbol: file-level`; `dockerignore` → dropped and counted; coverage `23/23`. Run 5 failed nothing, so the fixture set adds a **synthetic** partial variant — `failed[]` items with `classification` `provider` and `timeout` and a `reason` — **marked synthetic in the file**, until a real failing run replaces it. The raw run-5 JSON is not committed.

### 12.8 Model choice — non-normative

**No default is baked in; the user picks the model.** What the spikes on #21 found, all on one 43-file diff:

- **Qwen3.8-Max via OpenRouter** — the best precision, and the only model to find a new real bug (a `UnicodeDecodeError` crash-loop). Slow: one host (Alibaba, which honours `deny`) at about 30 tok/s. Coverage 5/23, 5/23, then 14/23 after 2 h 43 min when the key's spend limit cut it off; about $9.70 for the three runs.
- **`qwen3.6:35b-a3b` MoE on local Ollama** (M5 Pro, 48 GB) — fast and free, and the code never leaves the machine: 23/23 in 51 min. Weak: about 1 partly-valid comment in 9. The dense `qwen3.8:27b` was stopped at a 4–6 h ETA.
- **Kimi K2.7-code via OpenRouter** — the **untested next candidate**: more hosts, about $4 a run estimated, and a distinct family (`Moonshot`).

No configuration met spike #1's go bar — full coverage in under ~10 min for under ~$2, with at least one verified new finding. The user decided to ship the seat opt-in and model-configurable anyway, on the grounds that model quality matters most and speed and cost depend on where the model runs.

### 12.9 Open questions

1. **`rule_config_sha256`** — raw `--rule` bytes or the resolved rule set? This decides the expected value in §12.2's check.
2. **The full `severity` vocabulary**, so §12.5's table has no "anything else" doing real work.
3. **Budget knobs:** the reserve fraction (⅓ proposed); `--effort` pinned `low` or configurable; and whether to cap cost with `--max-tokens-budget` (hard-coded, configurable, or not at all).
4. **Narrow `api_key_env`** to names ending `_API_KEY`? It would shrink §6's residual disclosure at no cost to real configs.
5. **Tests are excluded by default.** Spike #1 lost a council finding to this. Add an `include` to the council rule file, at the cost of time?
6. **The temp `HOME` hides `~/.gitconfig`.** Confirm on a real run that nothing a local diff needs lives there.
7. **A distinct seat in a solo-Claude run** gets partial refutation (§7). Confirm reviewers want that, rather than all-or-nothing.
8. **Upstream feature requests** — each would remove a workaround above: `--config` or `OCR_HOME`; `OCR_LLM_EXTRA_BODY`; `--no-project-rules`; pre-review exclusions in the review manifest; an include/keep-tests flag; `--session-dir` or `--no-session`.

---

# Delivery phases

Each phase ships working software on its own. Phases 1 and 2 rest on executed evidence; the rest name their gates explicitly. Phase 1 still carries the open questions in §12.9.

## Phase 1 — The `ocr` harness

**Delivers:** one user-configured model, run through `ocr`, as an opt-in, **finder-only Round-1 seat** — no lens, not counted toward `min_reviewers`, its findings refutable when its family is distinct and `[unverified]` when it is not, and its coverage always in the report.

**Why it's first:** the user's decision after spikes #1–#2 on #21. It is the only harness run end to end on a real diff with real models, and its isolation, rule pinning and output shape are verified against source (§3). It needs no sandbox code and no OpenAI dependency, and it reaches Ollama today.

**Scope:** the final config schema (§4) — `harness: ocr`, `provider: openrouter | ollama`, `api_key_env`; the slug→family map and its runtime cross-check (§5); the shipped `modelslug` guard applied to custom slots, plus the slot-name and env-name guards (§6); the `:variant` policy for OpenRouter slugs (§6 — decide it here, while there are zero callers); per-run isolation, pre-flight, run and post-run checks (§12.2); budget sizing and the degrade table (§12.3); the JSON → §3.1 mapper (§12.5); the coverage line (§12.6); explicit slot identity at the transport boundary on **both** success and failure paths.

**Touches:** the config reader (parse, validate, derive family); the provider-dispatch script or a new `scripts/rc-ocr.sh` (isolation, invocation, mapper — the implementer's call); the orchestrator skill (detection — the seat ignored by `min_reviewers` and the solo-Claude test; roster; lens map "no lens"; Round-1 dispatch; no Step 3.5 retry; Step 4 routing on the `FAMILY` line; the judge's corroboration rule; the coverage line in the report and the Step 6.6 digest; `Codex = OpenAI` and the `Claude-fresh` wording); the docs below; a version bump.

**Tests** — bats under `tests/unit/`, in the existing style: behaviour, never assertions on source text.

- **Slug → family map:** table-driven over every row of §5's table, including the boundary case (`qwenfake/x` → `unknown`), `~` stripping, case folding and bare Ollama tags; plus an assertion that the map's value set equals the canonical set, and that the distinct/non-distinct split is exactly §5's.
- **JSON → §3.1 mapper**, on the sanitized run-5 fixture and its synthetic partial variant (§12.7): `high`, absent, `null` and an unknown severity string; `start_line` 0; the dropped `dockerignore` path; the coverage line for complete and partial runs; a `content` carrying a backtick fence and a control character; and the post-run checks — model mismatch → `unknown`, rule-hash mismatch or an unexpected tool → discard, invalid JSON / wrong `schema_version` / missing output file → `SKIPPED`, a non-zero exit with valid JSON → still parsed.
- **Config reader** (`rc-config.bats`): `harness: ocr` accepted, an empty `harness` skipped with a note; the provider enum per harness; `model: "qwen ; id"` rejected; `api_key_env` rejected for `FOO;id`, `1ABC` and `$(id)`, and defaulted per provider; the slot-name guard's ordering; config invariance — no `custom:` block, not one byte emitted.
- **One real end-to-end run** as a Tier-2 artifact fixture — local and on demand, never CI.

**Done when — all nine:**

1. The seat appears in the roster as `<slot> (<model> via ocr)` and in the printed lens map as "no lens". With nothing configured, roster and lens map are byte-identical to today.
2. It runs in Round 1, in parallel; Step 2.5's duration is unchanged.
3. The coverage line is printed for a complete run, a partial run (deadline hit), and a zero-finding run.
4. It is never offered as a verifier and never counted toward `min_reviewers`; a Claude-only roster plus the seat is still reported as solo-Claude for the native findings.
5. With a distinct model, its findings are routed to refutation. With a slot configured `anthropic/*` — and separately with an unmapped slug — its findings stay `[unverified]`, and a finding raised by both native Claude and the seat is **not** promoted.
6. Every degrade row in §12.3 is exercised once — including a missing binary, a wrapper kill, invalid JSON and a zero-credit key (HTTP 402) — and the review completes each time, with one note attributed to the slot.
7. A reviewed repo carrying a hostile `.opencodereview/rule.json` (an `exclude: ["**"]`, and rule text telling the model to report nothing) changes nothing: the pre-flight shows `Source: Custom (--rule)`, and coverage matches the same diff without the file.
8. **Write canary:** a changed file instructs the model to write a file into the repo; no file appears, and `tool_calls.by_tool` shows only the four read-only tools. Re-run on every `ocr` version bump.
9. **Isolation:** an OpenRouter run carries `data_collection: deny` — proven with spike #1's impossible-`only` control (404) — and the user's `~/.opencodereview/` is byte-identical before and after a run.

**Docs and version checklist — for the implementation PR, not this spec:**

- `CLAUDE.md` — the data-egress note (the `ocr` seat sends review context to OpenRouter and the model's host; Ollama sends none); the Reviewers table; the Round-1 line in How It Works and the Architecture diagram; Security Invariants for `api_key_env`, the hard-coded `deny`, rule pinning and the temp `HOME`.
- `README.md` — custom slots: a config example, opt-in, egress, the coverage line, and §12.8's evidence, non-normatively.
- `rules/config.md` — the `reviewers.custom.*` keys, their guards and defaults.
- `rules/providers.md` — the `ocr` harness: detection, isolation, invocation, and its `SKIPPED` reasons.
- `rules/orchestration.md` — the non-distinct rule in the judge and budget prose; `rules/delegation-format.md` — a note that the seat's §3.1 output is mapper-built.
- `skills/setup/SKILL.md` — print `ocr` and `jq` availability and the install command (`npm i -g @alibaba-group/open-code-review`); print-only, never install.
- `.claude-plugin/plugin.json` — a **minor** bump (a feature), as a `chore: bump version to X.Y.0` commit. If the pitch changes, edit `description` there and run `scripts/sync-metadata.sh`.

**Deliberately deferred:** more than one custom slot; verifier authority (needs the trust layer); delegate mode (§10).

## Phase 2 — OpenRouter via the codex harness

**Delivers:** one user-configured model running through `codex` as a repo-capable **finder** in the council — lens-assigned, counted toward the roster, its findings refutable by other families.

**Why it's next:** every transport element is proven (§3). It needs no new runtime and no sandbox code, and its read-only boundary is the kernel's rather than a tool list.

**Scope:** inherits Phase 1's schema, family map, guards and variant policy, and adds `harness: codex`: the frozen `codex`+OpenRouter argv (its `env_key` taken from `api_key_env`); lens assignment for custom slots (§7); explicit slot identity at the transport boundary on **both** success and failure paths — a mislabelled failure makes the orchestrator think the *real* Codex slot is down, which can drop it below `min_reviewers` and silently disable the whole refutation pass.

**Touches:** the provider-dispatch script (identity + argv profile); the orchestrator skill (detection, roster, **lens assignment**, dispatch, `min_reviewers` counting for a `codex` slot); provider/config/README/setup docs; a version bump.

**Done when — all seven:**

1. The slot appears in the roster under its model label, never "Codex".
2. It appears in the **printed lens map** with an overlay.
3. It demonstrably **reads files** (tool calls visible in its output).
4. It is **not** offered as a refutation verifier — its findings are refutable *by* others; it refutes nothing (§7).
5. With a slot configured `anthropic/*`, a finding raised by both native Claude and the custom slot is **not** promoted, and is reported as a same-family pile-up. *(Pins §5's second harm, which finder-only does not close.)*
6. With the provider key deliberately broken, the slot fails **as its own slot** and the real Codex slot still participates. With the key **absent**, the slot never enters the roster at all.
7. **Sandbox canary:** the slot is prompted to write a file inside the repo and **the file does not appear**. Ideally a per-run precondition, so a codex upgrade that silently drops the sandbox fails the slot rather than quietly promoting it.

**Deliberately deferred:** more than one custom slot; verifier authority (needs the out-of-repo trust layer).

## Phase 3 — The `opencode` harness

**Delivers:** removes the `codex` dependency; a third runtime option.

**Gate — a spike, before any code.** Everything known about opencode is documentation; the `wire_api="chat"` trap is why this gate exists. The spike must prove: non-interactive `run` with no TTY; `--model openrouter/…` resolving with only the API key set and no interactive auth; `OPENCODE_CONFIG` honoured with **nothing written into the repo**; and `edit`/`bash` denial actually enforced — **prove the denial by trying to write**. Also record whether it drains stdin, and its failure taxonomy.

**Stop condition:** if permissions can't be enforced without repo writes, or read-only can't be proven, **stop and report** rather than shipping a weaker-sandboxed fallback.

**Known design work:** slug translation (opencode wants the provider *in* the slug; codex takes a bare slug plus provider config). If a harness *fallback* is wired within one slot, **the report must name the harness that actually ran** — codex enforces read-only at the kernel, opencode and ocr at the agent layer, and the slot's real safety must not depend invisibly on which won.

## Phase 4 — Trust layer, then more providers

**The trust layer comes first, because two things now depend on it:** verifier authority for custom slots (§7), and any user-supplied `base_url`. An out-of-repo `~/.review-council/config.yml` (a new config layer — the reader loads only in-repo files today), env-only enablement, or a confirm gate. A slot enabled from a source the reviewed repo cannot write may safely verify.

**Then Ollama for the `codex` harness** (`ocr` reaches it from Phase 1) — its endpoint is a fixed `localhost:11434`, so it adds **no egress vector**.

**Gate — a spike:** does Ollama serve the Responses wire protocol at all? If it only speaks chat-completions, codex cannot reach it and this phase's design changes.

**Resolved in draft 4:** Ollama slugs have no vendor prefix (`qwen2.5-coder`). Draft 3 rejected them and left "explicit `family:` key or heuristic" open; §5's fixed prefix map now covers them, and an unmapped tag is `unknown` — non-distinct, never a guess.

**Blocked until the trust layer lands:** generic user-supplied `base_url`. **Do not ship without one.**

## Phase 5 — N custom slots

**Delivers:** lifts the one-slot cap. The reader already emits N; this phase fixes the **council semantics**.

**Open decisions, each needing a call:**
- **Lens-pool allocation** — six specialist overlays exist; Claude + Codex + Google + N customs can exceed them. Cap the roster, allow reuse, or add overlays? (`ocr` seats consume none.)
- **Family collisions among customs** — two customs on one vendor is one family. Correct canonicalization handles the promotion logic; the report should say so.
- **Budget and routing at N** — `run_budget_seconds` against N reviewers, several of which may be long-pole `ocr` seats; `min_reviewers` counting.
- **Context-window guard** — a small-context model silently truncates the diff and reviews a fragment confidently. OpenRouter's model list reports context length; consider warning when the package is likely to overflow.

---

## Why there's no task breakdown

The first draft carried a full TDD implementation plan — exact insertion points, code, test bodies, line numbers. **It was invalidated within a day, before anyone implemented a line of it.** A single unrelated PR moved a function by 108 lines and grew the dispatch script from 633 to 800 lines; the plan's cited positions, excerpts, and test-count arithmetic all went stale.

A plan that decays faster than it gets executed is worse than none: it reads as authoritative while quietly lying. Since this work isn't scheduled, the durable content is the **what** and the **why**. The **where** and **how** belong to whoever implements it, written against the code as it exists that day.

**When it is scheduled**, generate the task breakdown then, from this spec plus the then-current code.

## Notes for whoever picks this up

- **§3 is the contract with reality.** Re-verify the frozen argv before building on it — `wire_api="chat"` was removed once already, and the same could happen to the custom-provider surface. **`ocr` decays faster still** — a release every 1–3 days: re-verify its flags, its `$HOME`-only config lookup, its rule layering, its env fallbacks and its JSON shape against the version you pin. The `google.model` sink has since been fixed (v0.9.3); §6 records it as shipped.
- **§5, §6 and §7 exist because of review findings, not first-draft insight** — and §5/§6 were rewritten *twice*. Both times the error had the same shape: **computing a value is not enforcing it.** The reader can derive a canonical family; only prose obliges the orchestrator to use it. The reader can validate a slug; only its placement before the sink makes that a guard. Treat that pattern as the thing most likely to be wrong again.
- **The `modelslug` guard shipped on its own** (v0.9.3, `bc763af`), as this note recommended. The `envname` guard for `api_key_env` is the same pattern, and already exists for `pr_comments.bot_token_env`.
- **Draft 4 applies that lesson on purpose.** `ocr` reports the provider, model, rule hash and tools it actually used; §12.2 checks each one against what the council asked for, rather than trusting that the flags took effect.
- **The plugin's own conventions are the real spec** for the mechanical parts: POSIX `sh` (`dash -n` clean), config as declarative data that is parsed and never executed, config-invariance (absent config = byte-identical behaviour), least privilege, report-only, and tests written against the existing fixtures rather than invented ones.
- **Both reviews of this spec had only one non-Claude family** (`agy` quota exhausted). The second review found that the first review's own fix was still wrong — twice over, in the same two sections. That is the strongest available argument for re-reviewing with a full roster **before** implementing, not after.
