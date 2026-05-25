# Fan-out + synthesize guide

`--fanout` is the differentiated mode. It queries every configured provider in parallel and prints all responses to stdout, separated by the output-contract markers. The lead session (whatever called `second-opinion`) is responsible for synthesizing them into a single answer.

## When to fan out

Use fan-out when:

- The decision is high-stakes (irreversible, expensive, or visible to others) and you want adversarial review across models.
- You suspect one provider is hallucinating and want to detect it via cross-provider disagreement.
- The question sits in a domain where different model families have different blind spots: current events, niche technical accuracy, ethics judgments, contested empirical claims.
- You're writing something that will be cited or shipped and want a second/third/fourth read.

Do **not** fan out for:

- Trivial questions. The signal-to-cost ratio is bad.
- Anything where you already trust the answer. Fan-out costs ~3-4× a single call.
- Sensitive data you haven't authorized to leave the session. Fan-out sends the prompt to every configured provider.

## Cost posture

A single fan-out can cost $0.10–0.40 in API fees if multiple providers are routed through metered endpoints. Codex (subscription) is free per-call. Grok / Gemini / OpenRouter are metered.

Rule of thumb: if you're going to fan out often, make sure Codex is your default and the others are configured only when you specifically need them.

## How synthesis should work

The fan-out raw output looks like:

```
=== provider: codex ===
<codex's response>
=== end ===
=== provider: grok ===
<grok's response>
=== end ===
=== provider: gemini ===
<gemini's response>
=== end ===
```

Do not paste this raw to the user. Synthesize:

1. **Find the consensus.** What do all (or most) providers agree on? Lead with that.
2. **Flag the disagreements.** If one provider says "X is safe" and another says "X is risky," surface that explicitly with attribution.
3. **Watch for hallucination tells.** If only one provider cites a specific number, date, or quote and the others don't, treat that number as suspect.
4. **Note any refusals.** If a provider refused, mention it — sometimes the refusal itself is the data point.
5. **Give a single recommendation.** The user asked for an answer, not a literature review.

## Common failure modes

- **Stragglers.** Fan-out waits for all providers. If one is slow (Gemini Deep Research, OpenRouter routing to a slow model), the whole call is slow. There's no per-provider timeout right now.
- **Partial failure.** If one provider's adapter exits non-zero, the others still run. Their output is still in stdout. Check exit codes after fan-out finishes.
- **Order non-determinism.** Providers print in whatever order they finish. Don't rely on positional ordering.

## Anti-pattern: fan-out as a default

If you find yourself using `--fanout` on every call, you're paying 3-4× for low marginal signal. Pick one provider for most calls; reserve fan-out for the decisions that actually warrant it.
