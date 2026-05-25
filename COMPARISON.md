# COMPARISON.md — second-opinion vs other LLM-bridge tools

`second-opinion` sits in a crowded category. This document explains where it differs from neighboring tools and when you'd want each.

## The category

A bunch of tools let you "call multiple LLMs from one place." The interesting axes are:

1. **Routing intelligence** — does the tool pick a provider for you, or do you specify every time?
2. **Subscription awareness** — does it ride paid subs (ChatGPT Plus, Google AI Pro) or always go through metered APIs?
3. **Fan-out + synthesis** — can it query multiple providers and combine the results?
4. **Output contract** — is there a stable format for downstream parsing?
5. **Integration target** — designed for human use at a terminal, or for invocation by another agent (Claude Code, OpenCode, Codex)?
6. **Scope** — single-call assistant, autonomous research loop, full agent framework?

## Neighbors

### Simon Willison's `llm` (datasette/llm)

The closest comparable. Mature Python CLI with plugins for many providers, a SQLite log of every call, conversation threads, and embedded model support.

- ✅ Broader provider catalog than us.
- ✅ Stores every prompt + response in a queryable log.
- ✅ Embeddings, templates, JSON schema responses.
- ❌ Always metered API calls — no subscription-CLI passthrough.
- ❌ No fan-out + synthesize pattern.
- ❌ No routing intelligence — you pick the model each call (`-m gpt-4o`).
- ❌ Python install + plugin management.

**When to use `llm`**: you want a permanent searchable log of every LLM call, you don't care about subscription savings, you're happy specifying the model each time, or you need embeddings/templates.

**When to use `second-opinion`**: you want routing decided for you, you want fan-out + synthesis, you want the Codex CLI to ride your ChatGPT subscription instead of double-billing.

### OpenRouter (used directly)

Single API endpoint that fronts ~100 model providers under one billing relationship.

- ✅ One key, many models.
- ✅ Includes models that are otherwise hard to reach (smaller open-weights).
- ❌ Always metered — no subscription routing possible by design (it's a paid intermediary).
- ❌ Pure API surface — no CLI ergonomics, no routing, no synthesis.
- ❌ Refusal posture varies by upstream model; you have to know which to pick for what.

**When to use OpenRouter directly**: you need a specific exotic model and you want pay-per-token.

**When to use `second-opinion`**: you want routing + fan-out + subscription-first behavior. (We fall back to OpenRouter for refusal-fallback cases — it's a backstop, not the front door.)

### `aichat` (sigoden/aichat)

Rust-based multi-model CLI, similar surface to `llm` with chat UX, RAG, and sessions.

- ✅ Faster startup than Python tools.
- ✅ Rich chat UX with sessions and roles.
- ✅ RAG built in.
- ❌ Metered APIs only.
- ❌ Built for interactive human use; less ergonomic for shell-piping or agent invocation.
- ❌ No fan-out + synthesize.

**When to use `aichat`**: interactive multi-turn human use at a terminal with RAG over local docs.

**When to use `second-opinion`**: agent-invocation, fan-out, subscription routing.

### claude-router / claude-flow

Front-ends that route between Claude variants (Haiku/Sonnet/Opus) or between Claude and other providers from inside a Claude-centric workflow.

- ✅ Tight Claude integration.
- ✅ Can route within the Claude family by task complexity.
- ❌ Not designed for cross-provider second opinions — focused on Claude-internal routing.
- ❌ No subscription awareness for non-Claude providers.

**When to use claude-router**: you want to save on Claude API spend by routing simple turns to Haiku and complex turns to Opus.

**When to use `second-opinion`**: you want a non-Claude perspective, not just a different Claude model.

### udit/autoresearch

Different category entirely. Autoresearch is an **autonomous goal-directed iteration framework** — "Modify → Verify → Keep/Discard → Repeat forever" until a measurable metric improves. It's a loop driver, not a model router.

- Different shape: autoresearch is a *loop*, second-opinion is a *single call* (or a single fan-out).
- Different scope: autoresearch has 13 commands, 3-platform support (Claude Code, OpenCode, Codex), 35K-line README, formal protocol files.
- Different mission: autoresearch wants to make you compounding gains autonomously; second-opinion wants to surface a second perspective once.

We borrow autoresearch's **structural template** (this repo's parity with AGENTS.md, CONTRIBUTING.md, COMPARISON.md, CONTEXT.md, tests/, scripts/install.sh exists because autoresearch demonstrated the polish bar). We do not try to replicate its functionality — `second-opinion` is not an iteration framework and shouldn't pretend to be one.

**When to use udit/autoresearch**: you have a measurable metric and want autonomous improvement (code score, eval pass rate, content quality measure).

**When to use `second-opinion`**: you want one provider's take on a question, or a fan-out across providers. If you want an autonomous loop *that calls second-opinion as one step*, fine — they compose.

## The matrix

| Tool                 | Routes for you | Subscription-aware | Fan-out + synthesize | Agent-invocation friendly | Scope             |
|----------------------|----------------|--------------------|----------------------|---------------------------|-------------------|
| Simon Willison `llm` | ❌             | ❌                 | ❌                   | ✅ (stable contract)      | Single call       |
| OpenRouter direct    | ❌             | ❌ (by design)     | ❌                   | ✅ (HTTP)                 | Single call       |
| `aichat`             | partial        | ❌                 | ❌                   | partial                   | Multi-turn chat   |
| claude-router        | within Claude  | ❌                 | ❌                   | ✅                        | Claude internal   |
| udit/autoresearch    | n/a            | n/a                | n/a                  | ✅                        | Autonomous loop   |
| **second-opinion**   | ✅             | ✅                 | ✅                   | ✅                        | Single call + fan |

## What we deliberately don't do

- **Logging.** No SQLite, no JSONL trail. The caller's responsibility (the session that invoked us already has its own log).
- **Sessions / multi-turn.** Every call is fresh. If you want a conversation, the lead agent owns the conversation.
- **Templates / parameter substitution.** Pass a prompt as a string. If you want templating, do it in your caller.
- **Embeddings.** Wrong layer.
- **RAG.** Wrong layer.
- **A web UI.** Hard no. This is a shell skill.

This is the smallest tool that does the routing + subscription + fan-out job well. Anything beyond that scope, we redirect to a tool that's actually built for it.
