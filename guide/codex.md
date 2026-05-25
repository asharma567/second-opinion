# Codex provider guide

The Codex adapter routes calls through the `codex` CLI from OpenAI. This is the **default** provider for `second-opinion` and the one that gives you the best price posture.

## Why Codex is the default

The `codex` CLI authenticates against a ChatGPT subscription (Plus, Pro, or Mac app). When you call OpenAI's models through `codex`, the inference rides on that subscription — no per-token API billing.

If you call the OpenAI Chat Completions or Responses API directly, you pay metered rates *on top of* the subscription you already have. That double-billing is the central waste this skill exists to avoid.

So whenever the prompt doesn't match a specialty (visual/UI → Gemini, humor → Grok, refusal-fallback → OpenRouter), the classifier sends it here.

## Install

```bash
npm install -g @openai/codex
```

Verify:

```bash
codex --version
```

You must already be logged into the ChatGPT desktop app or have a Codex session. Open the app once if you haven't.

## Auth state

There is no API key for `codex` in this setup. Auth is implicit through the ChatGPT subscription session. If the session expires, the CLI will prompt you to re-auth interactively.

`scripts/auth-check.sh` confirms `codex` is on PATH; it does not confirm the subscription is currently valid. If you suspect drift, run `codex` interactively once to refresh.

## Common failures

- **`codex: command not found`** — install with the npm command above. If you installed and the binary still isn't on PATH, check `npm bin -g`.
- **Long pause then error** — the subscription session may have expired. Run `codex` interactively to re-auth.
- **Empty response** — `codex` occasionally returns blank under load. The adapter does not retry; the lead session can decide whether to.

## What Codex is good at

- Engineering design review, architecture critique.
- Tool-call and agent-orchestration patterns.
- Long-context structured reasoning.
- Code review with judgment about style and intent (not just lint).

## What Codex is not great at

- Highly current events (use Gemini Deep Research or a `:online` model via OpenRouter).
- Humor or casual register (use Grok).
- Visual / image-rich tasks (use Gemini).

## Cost reminder

Subscription-routed. No API charges per call. If you start seeing OpenAI API invoice line items after using `second-opinion`, something is wrong — open an issue with the offending command line.
