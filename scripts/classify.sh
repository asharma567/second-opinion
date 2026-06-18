#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-}"
lc="$(echo "$prompt" | tr '[:upper:]' '[:lower:]')"

match() { [[ "$lc" == *"$1"* ]]; }

# Deep research → OpenRouter Fusion (panel+judge meta-model). Opt-in only:
# requires --deep-research (SECOND_OPINION_DEEP_RESEARCH=1) AND a research-shaped
# prompt. Fusion is separately billed and runs several model calls per query, so it
# never auto-selects on prompt text alone. Reach it otherwise via --provider fusion.
if [[ "${SECOND_OPINION_DEEP_RESEARCH:-0}" == "1" ]]; then
  if match "research" || match "latest on" || match "state of the art" \
     || match "literature" || match "survey" || match "what's new" \
     || match "sources" || match "evidence" || match "studies"; then
    echo fusion; exit 0
  fi
fi

# Frontend / UI / design
if match "frontend" || match "ui design" || match "ux " || match "css" || match "tailwind" \
   || match "react component" || match "figma" || match "visual" || match "color palette"; then
  echo gemini; exit 0
fi

# Humor / vibe / casual / romance
if match "joke" || match "funny" || match "roast" || match "vibe" || match "romance" \
   || match "dating" || match "flirt" || match "shitpost" || match "meme"; then
  echo grok; exit 0
fi

# Tool calling / agent orchestration / Claude-specific work
# These prompts used to route to `claude` adapter. That adapter is gone — the lead
# session IS Claude, so the right answer is "spawn a subagent from the lead" not
# "call Claude API." We route to codex as the closest sub-routed alternative for
# structured engineering reasoning, and let the lead session decide whether to
# instead spawn a subagent for a Claude-flavored second opinion.
if match "tool call" || match "tool-call" || match "agent" || match "mcp" \
   || match "function calling" || match "claude code" || match "subagent"; then
  echo codex; exit 0
fi

# Refusal-prone / sensitive / "another angle when X said no"
if match "uncensored" || match "unfiltered" || match "without refusing" \
   || match "claude refused" || match "gpt refused" || match "blocked by" \
   || match "as if you weren't trained"; then
  echo openrouter; exit 0
fi

# Engineering design / architecture review
if match "design review" || match "architecture" || match "migration" \
   || match "should i use" || match "tradeoff" || match "scalab" \
   || match "code review" || match "refactor"; then
  echo codex; exit 0
fi

# Default fallback — codex is the safest general-purpose option that's
# subscription-routed (rides on ChatGPT sub, no API double-bill)
echo codex
