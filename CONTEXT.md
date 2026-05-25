# CONTEXT.md — why second-opinion exists

## Origin

This started as a `~/.claude/skills/second-opinion/` directory inside a personal Claude Code skill collection. The trigger was a specific frustration: I'd be in the middle of an Opus-driven session, hit a design question I wanted a non-Claude perspective on, and have to break the flow to manually paste into chat.openai.com, google.com/bard, or grok.com — each with its own auth, its own copy-paste dance, and its own habit of double-billing me on subscriptions I was already paying for.

The skill collapsed that into one shell call:

```
~/.claude/skills/second-opinion/scripts/dispatch.sh "should I use Postgres or DuckDB here"
```

The dispatcher picks a provider based on task shape, runs the call through the right CLI or API, returns the response in a stable format the lead session can parse. Extracted into its own repo on 2026-05-11.

## Design philosophy

### 1. Subscription routing is the unique value

Everyone has multi-provider routers now. The thing that's actually scarce is *not paying twice for the same compute*. If you have ChatGPT Plus, the Codex CLI uses your subscription for inference. If we route to the OpenAI API instead, you pay the API charge and the sub charge. Same model, two bills.

So the prime directive is: **subscription CLI → native API → OpenRouter**, in that order. The router prefers the path that doesn't double-bill, even if it's marginally slower or less convenient.

This is not the dominant pattern in this category. Most multi-provider tools (`llm`, OpenRouter direct, aichat) are API-only by design. They optimize for breadth of model catalog or richness of features. They do not optimize for "you've already paid for this; don't pay again."

### 2. Shell is the substrate

The skill is bash + curl + provider CLIs. No Python runtime, no Node, no SDKs to install. This is a deliberate constraint:

- Bash is universal on the systems this runs on (Mac, Linux servers, droplets).
- Adapters are short enough to fully read before trusting (~40-80 lines each).
- No dependency hell. No "pip install conflict with system Python." No "the SDK version changed and broke our adapter."
- Easy to invoke from any other shell context — Claude Code sessions, cron jobs, makefiles, GitHub Actions.

The cost: no rich features. No conversation history, no embeddings, no JSON-schema validation. We don't try to be a full agent framework; we try to be a routing layer.

### 3. The output contract is a load-bearing wall

Every adapter prints:

```
=== provider: <name> ===
<body>
=== end ===
```

This is the contract that lets fan-out work. The dispatcher can run N providers in parallel, concat their outputs, and the parser can demarcate them by these sentinel lines. Any downstream agent — Claude Code, OpenCode, a shell pipeline — can rely on these markers to split responses.

If a contributor proposes "let's make the output prettier with colors and headers," the answer is no. The contract is for machines, not eyeballs.

### 4. Built for agent invocation, not human terminal use

There's a category of tools designed for a human sitting at a terminal having a conversation with an LLM. `aichat`, `gpt-cli`, even `llm` to some extent. Those tools optimize for interactive UX: history, REPL, sessions, completions.

`second-opinion` is built for the **other** case: an autonomous agent (Claude Code) wants a second perspective mid-task. That agent doesn't need a chat REPL, doesn't have a session to maintain, doesn't care about colored output. It needs a one-shot call with a stable contract.

This shapes everything:
- Adapters are short and machine-readable.
- No interactive prompts.
- Stable exit codes.
- Stable stdout format.
- Errors are unambiguous (stderr + exit nonzero).

### 5. The fan-out + synthesize pattern is the differentiated mode

Anyone can route to one provider. The mode that earns this skill's keep is `--fanout`: query 3-4 providers in parallel, then have the lead session synthesize the responses.

This is most useful when:
- You're making a high-stakes decision and want adversarial review.
- The question is in a domain where different model families have different blind spots (current events, technical accuracy, ethics judgments).
- You want to detect when one provider is hallucinating by checking if the others agree.

The synthesis itself happens in the lead session, not in this skill. We just gather the raw responses; the agent that asked turns them into a single answer.

### 6. Minimal scope, no creep

Things this skill will not become:
- A logging system. (Use your shell history, or pipe to a file.)
- A conversation manager. (Use the lead session's context.)
- An agent framework. (Use Claude Code or OpenCode.)
- A model evaluator. (Use a real eval harness.)
- An autoresearch loop. (Use udit/autoresearch.)

Every time a feature request comes in, the test is: "does this make routing + subscription-awareness + fan-out better, or is it scope creep?" Most things turn out to be the latter.

## What this skill earns

In exchange for the constraints above, the user gets:
- One call to get any of 4+ provider responses with smart routing.
- Subscription-first billing posture (no surprise double-charges).
- Fan-out + synthesize for high-stakes questions.
- A stable output format that downstream agents can parse.
- A tool small enough to fully read before trusting.

That's the whole thing. Anything else, look at a different tool.
