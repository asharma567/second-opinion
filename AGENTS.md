# AGENTS.md — guidance for AI agents using second-opinion

This file is what an AI agent (Claude Code, OpenCode, Codex) should read before invoking `second-opinion`. It supplements `SKILL.md` (which describes *what* the skill does) by describing *when* and *how* to use it correctly inside an autonomous session.

## Mental model

`second-opinion` is a **"phone a friend"** mechanism, not a primary worker. It exists to get a perspective from a *different* model — a different training distribution, a different RLHF posture, a different price/latency tradeoff — when:

1. Your own answer would benefit from independent corroboration.
2. The task shape is *better matched* to another model's strengths (humor → Grok, visual UX → Gemini, tool-heavy engineering → Codex).
3. You want adversarial review of a plan or design.
4. You need a refusal fallback (your own model declined; check whether the refusal was correct).

It is **not** a replacement for doing the work yourself. The lead session is usually the right answerer; `second-opinion` is the sanity check or specialist consult.

## Decision rubric — should I call it?

Call it when **at least one** is true:
- User explicitly named a provider ("ask Grok", "what does Codex say").
- User said "second opinion", "fan out", "deep research", or asked for a sanity check on something you already have an opinion about.
- The task is in a domain where another provider is materially better (see SKILL.md routing table).
- You are unsure and the answer matters (high blast radius decision, irreversible action).
- The user's own answer disagrees with yours and you want a tiebreaker.

Do **not** call it when:
- The task is trivial (definition lookup, syntax fix).
- The user clearly wants *you* to answer (no flag, no "what would X say", just a direct question).
- The prompt contains sensitive PII the user hasn't authorized to leave the session (medical records, credentials, private addresses, etc.).
- You're in a tight loop and the latency cost (5–60s) is not worth the marginal signal.

## Cost + billing posture

Default to subscription-routed CLIs first; API only as fallback. Order:

1. **Codex CLI** (`codex` command) — rides on the user's ChatGPT Mac/Plus/Pro subscription. No metered API billing. Preferred default when no other signal.
2. **Native API** (Grok, Gemini, Claude-via-subagent) — billed per-token.
3. **OpenRouter** — last resort. Separately billed at OpenRouter rates. Used for refusal-fallback and exotic-model needs.

This matters: a single fan-out across all providers can easily cost $0.10–0.40 in API fees if not routed correctly. Prefer single-provider routing unless the user asked for fan-out.

## On Claude as a second opinion

There is no Claude *adapter* in `scripts/adapters/`. Calling the Anthropic API from inside a Claude Code session would double-bill (the session is already authenticated against Claude). Instead, **spawn a subagent**:

```
Agent(subagent_type: "general-purpose", model: "sonnet"|"opus", prompt: "...")
```

The subagent gets its own context window, returns an independent Claude perspective, and reuses the harness authentication. Use this when you want to compare Sonnet vs Opus, get a fresh Claude take on a prompt you've been iterating on, or stress-test a plan in isolation.

## Output contract

Every adapter prints to stdout in this format so fan-out + synthesis tooling works:

```
=== provider: <name> ===
<response body — any length, any format>
=== end ===
```

Errors go to stderr, non-zero exit. Agents calling `second-opinion` and downstream-parsing should:

- Look for `=== provider: ... ===` headers as delimiters.
- Treat anything between header and `=== end ===` as the response body.
- Treat exit code ≠ 0 as a *transport* failure, not a content failure (the model's substantive disagreement is in the body, not the exit code).

## Synthesizing fan-out results

When the user requests `--fanout`, you (the lead agent) are responsible for synthesizing the parallel responses. Common patterns:

- **Consensus**: report where providers agree, flag where they disagree, note any single-provider outliers.
- **Adversarial pairing**: pit one provider's answer against another's critique.
- **Majority + dissent**: take the modal answer, then explicitly surface dissenting views.

Do not just paste the raw fan-out output. The user asked you for a second opinion, not a wall of unmediated text.

## Common failure modes

- **Hallucinated specifics** — Some providers (especially smaller open models via OpenRouter) will confidently fabricate numbers, dates, quotes. Cross-check anything load-bearing before acting on it. There is a documented prior incident: a Mistral-via-OpenRouter call returned fabricated analyst price targets in a finance question. Treat OpenRouter outputs as opinion, not fact.
- **Refusal mismatch** — Codex and Gemini occasionally refuse benign requests that Claude would handle. If you see a refusal where you didn't expect one, retry through OpenRouter (refusal-fallback path) or just answer it yourself.
- **Auth drift** — Subscription CLIs (Codex, Gemini Code Assist) silently fall back to API key if the sub-session expired. The user gets billed unexpectedly. If `scripts/auth-check.sh` shows a non-sub auth path, surface that to the user before running expensive fan-outs.
- **Stale model defaults** — Adapters hard-code current model names (e.g., `mistralai/mistral-large-2411`). When a new model ships, the adapter doesn't auto-upgrade. Inspect adapter scripts if the user expects a specific model version.

## What to log after a call

For non-trivial calls (deep research, fan-out, anything the user might want to revisit), capture:
- Provider(s) called
- Approximate cost (if known) or "sub-routed"
- Whether you used the response verbatim, modified it, or discarded it
- Any caveats (refusal, hallucination flag, timeout)

This belongs in your own session memory or task log, not in this repo.
