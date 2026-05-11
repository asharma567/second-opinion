#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-}"
lc="$(echo "$prompt" | tr '[:upper:]' '[:lower:]')"

match() { [[ "$lc" == *"$1"* ]]; }

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
