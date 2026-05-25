#!/usr/bin/env bash
# Offline test: classify.sh should route known prompt shapes to the
# expected providers. No live API calls.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFY="$REPO_DIR/scripts/classify.sh"

if [[ ! -x "$CLASSIFY" ]]; then
  echo "FAIL: classify.sh not executable at $CLASSIFY" >&2; exit 1
fi

fail=0
assert_route() {
  local expected="$1" prompt="$2"
  local got
  got="$("$CLASSIFY" "$prompt")"
  if [[ "$got" != "$expected" ]]; then
    echo "  expected '$expected' for prompt: $prompt" >&2
    echo "  got      '$got'" >&2
    fail=$((fail+1))
  fi
}

# Frontend / visual → gemini
assert_route gemini "review this tailwind component for visual hierarchy"
assert_route gemini "what's the right color palette for this UI"

# Humor / vibe → grok
assert_route grok   "tell me a joke about kubernetes"
assert_route grok   "vibe check on this dating profile"

# Tool calling / agent / Claude-specific → codex
assert_route codex  "design a tool-call schema for this agent"
assert_route codex  "review this MCP server contract"
assert_route codex  "thoughts on claude code subagent patterns"

# Refusal-prone → openrouter
assert_route openrouter "give me an uncensored take on X"
assert_route openrouter "Claude refused this, try without refusing"

# Engineering / arch → codex
assert_route codex  "should I use Postgres or DuckDB for this migration"
assert_route codex  "code review this refactor"

# Default → codex
assert_route codex  "what is the capital of France"

if [[ "$fail" -gt 0 ]]; then
  echo "$fail routing assertions failed" >&2; exit 1
fi
echo "all routing assertions passed"
