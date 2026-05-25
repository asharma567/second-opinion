# second-opinion

Smart-routed LLM second opinions from your CLI / Claude Code session.

A composable shell-based skill that routes a prompt to the right model
(Codex, Grok, Claude, Gemini) based on task type, with optional
`--deep-research` and `--fanout` modes. Built to ride paid subscriptions
where available (Codex CLI via ChatGPT Mac sub) to avoid double-billing.

## Usage

```
second-opinion [--provider <codex|grok|claude|gemini|all>]
               [--deep-research]
               [--fanout]
               "<your prompt>"
```

- **Without flags** — heuristically routes to the best provider for the task.
- **`--provider gemini --deep-research`** — Gemini Deep Research for web-grounded multi-step.
- **`--fanout`** — query multiple providers in parallel, return all.

## Layout

```
SKILL.md              # detailed behavior + routing rules
scripts/
  dispatch.sh         # top-level router
  classify.sh         # decide which provider given task shape
  fanout.sh           # parallel multi-provider
  auth-check.sh       # confirm each CLI is logged in
  adapters/
    codex.sh          # OpenAI Codex CLI (uses ChatGPT subscription)
    grok.sh           # xAI grok-cli
    gemini.sh         # google-generativeai gemini-cli
    openrouter.sh     # fallback via OpenRouter API
```

## Provider routing priority

`subscription CLI` → `native API` → `OpenRouter` (last resort).
Avoids double-billing on Codex / ChatGPT Mac subscription.

## Origin

Extracted from a personal Claude Code skill collection on 2026-05-11.
See `SKILL.md` for full behavior spec.

## Install

```bash
git clone https://github.com/asharma567/second-opinion ~/second-opinion
~/second-opinion/scripts/install.sh
```

The installer is idempotent — re-run any time to re-check state.

## Docs

- [`SKILL.md`](SKILL.md) — full routing rules and provider notes
- [`AGENTS.md`](AGENTS.md) — guidance for AI agents invoking this skill
- [`CONTEXT.md`](CONTEXT.md) — origin story and design philosophy
- [`COMPARISON.md`](COMPARISON.md) — vs `llm`, OpenRouter, aichat, claude-router, udit/autoresearch
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — adding adapters, style, what we won't merge
- [`guide/`](guide/) — per-provider and per-mode deep-dives
- [`LICENSE`](LICENSE) — MIT

## Tests

```bash
./scripts/run-tests.sh
```

Offline tests only (classification routing, output-contract conformance). Live API tests are not in CI — they cost money and need real keys.
