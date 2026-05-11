---
name: second-opinion
description: Get a second opinion from another LLM (Codex, Grok, Claude, Gemini) — smart-routed by task type, with optional deep-research and fan-out-to-all modes. Use when the user wants a sanity check, an outside critique, a different style ("ask grok", "ask gemini"), a synthesis across providers, or a deep-research dive on a question that benefits from web-grounded multi-step research.
---

# second-opinion

Cross-provider "phone a friend" with smart routing.

## When to use

Trigger when the user says:
- "get a second opinion on …"
- "ask {grok|gemini|codex|chatgpt} what they think" (for a Claude opinion, spawn a subagent from the lead instead — see Note on Claude below)
- "fan out to everyone"
- "deep research on …"
- "what would another model say"
- The user's task fits one of the routing rules below and you'd benefit from another perspective.

Don't use it for: trivial lookups, tasks where the user wants *you* to answer, or any task with sensitive personal data the user hasn't authorized to leave the local session.

## Routing rubric

The router script (`scripts/classify.sh`) picks a provider by keywords. Override with `--provider` when the user names one explicitly.

| Task shape | Provider | Why |
|---|---|---|
| Frontend / UI / design critique | `gemini` → auto-falls-through to OpenRouter (`google/gemini-2.5-pro`) on error/missing key | Strong visual + UX reasoning |
| Humor / romance / vibe-check / casual | `grok` | Looser, more conversational |
| Tool-calling code / agent-orchestration design | `codex` (or **spawn subagent** for Claude-specific) | Codex is strong at structured engineering reasoning; for a true Claude opinion, spawn a subagent — see Note on Claude |
| Engineering design review / architecture | `codex` | OpenAI's o-series via `codex` CLI (rides on ChatGPT sub) |
| Refusal fallback / sensitive prompts that hit ethics gates | `openrouter` | Routes to a low-refusal model (default `mistralai/mistral-large-2411`); override via `OPENROUTER_MODEL` |
| Deep research / multi-source synthesis | fan-out + lead-session synthesis | Lead Claude session synthesizes the raw fan-out output |
| (default, no signal) | `codex` | Safest general-purpose, subscription-routed |

## How to invoke

```bash
# Auto-routed
~/.claude/skills/second-opinion/scripts/dispatch.sh "should I use Postgres or DuckDB for this"

# Explicit provider
~/.claude/skills/second-opinion/scripts/dispatch.sh --provider grok "tell me a joke about kubernetes"

# Deep research (provider's research mode if available)
~/.claude/skills/second-opinion/scripts/dispatch.sh --deep-research "what's the latest on GLP-1 + vestibular migraine"

# Fan out to all configured providers + synthesize
~/.claude/skills/second-opinion/scripts/dispatch.sh --fanout "is this migration plan safe?"

# With attached input
~/.claude/skills/second-opinion/scripts/dispatch.sh --input-file /tmp/diff.txt --mode critique "review"
```

The `/second-opinion` slash command is a thin wrapper over `dispatch.sh`.

## Auth

Required env vars / auth (only the providers you actually use):
- **Codex** — *no env var.* Authenticates via ChatGPT subscription (Mac/Plus/Pro) through `codex` CLI. Install: `npm install -g @openai/codex`. CLI subprocess rides on the sub, no API billing.
- **Claude** — *no adapter.* The lead session IS Claude. To get a Claude second opinion, spawn a subagent (see Note on Claude below).
- `XAI_API_KEY` — Grok (API; xAI hasn't shipped a sub-routed CLI as of May 2026)
- `GEMINI_API_KEY` — Gemini (API today; the `gemini` CLI is installed but auth not yet sub-routed — see Note on Gemini below)
- `OPENROUTER_API_KEY` — OpenRouter (refusal fallback / model marketplace; separately billed at OpenRouter rates)
- `OPENROUTER_MODEL` — optional model override for OpenRouter (default `mistralai/mistral-large-2411`; append `:online` for web-augmented)

## Note on Claude — spawn a subagent, don't call the API

The Claude adapter was dropped because calling Anthropic API from inside Claude Code would double-bill (lead session already authenticates against Claude). When you want a Claude second opinion — e.g., to compare Sonnet vs Opus, get an independent Claude perspective, or test a prompt in isolation — **spawn a subagent from the lead session** with `Agent(subagent_type: "general-purpose", model: "sonnet"|"opus", prompt: "...")`. The subagent gets its own context window, returns a fresh perspective, and reuses the harness auth.

## Note on Gemini — sub-routing pending

The `gemini` CLI v0.27.3+ is installed but auth defaults to API key. To switch to sub-routing (rides on Google AI Pro / Code Assist plan instead of being separately billed):
1. Run `gemini` interactively once and choose Code Assist / Google account auth flow
2. Add `export GOOGLE_GENAI_USE_GCA=1` to your shell rc
3. Once both are done, the adapter can be updated to prefer the CLI subprocess (forward-compat check). Currently uses the `GEMINI_API_KEY` HTTP API path.

Keys auto-load from `~/.openclaw-tgpkb/secrets/<provider>_api_key` if env vars aren't set (see `~/.openclaw-tgpkb/secrets/llm_keys.sh`).

Run `scripts/auth-check.sh` to verify each provider is reachable.

## Files

```
second-opinion/
├── SKILL.md                        # this file
└── scripts/
    ├── dispatch.sh                 # entry point: parses args, routes
    ├── classify.sh                 # keyword router
    ├── fanout.sh                   # parallel call + synthesize
    ├── auth-check.sh               # verify each provider's auth
    └── adapters/
        ├── codex.sh                # OpenAI / Codex CLI (rides on ChatGPT sub)
        ├── grok.sh                 # xAI API (no CLI/sub available as of May 2026)
        ├── gemini.sh               # Google Gemini API (CLI sub-routing TODO — see Note on Gemini)
        └── openrouter.sh           # OpenRouter (refusal fallback / model marketplace)
```

## Output convention

Every adapter prints to stdout in this format so fan-out + synthesis works:

```
=== provider: <name> ===
<response body>
=== end ===
```

Errors go to stderr with non-zero exit.

## TODOs

- Deep-research mode is provider-specific; current adapters approximate it. Wire real APIs when available (Gemini Deep Research, OpenAI Deep Research, xAI Live Search).
- Synthesis prompt in `fanout.sh` is a stub — refine after first real run.
- Classifier is keyword-based; consider upgrading to a small Haiku call if accuracy matters.
