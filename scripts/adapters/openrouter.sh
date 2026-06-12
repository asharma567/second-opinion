#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-}"
mode="${SECOND_OPINION_MODE:-}"
deep="${SECOND_OPINION_DEEP_RESEARCH:-0}"

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "error: OPENROUTER_API_KEY not set" >&2
  exit 4
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq required" >&2
  exit 4
fi

# Default to a strong model with permissive content policy.
# Override via OPENROUTER_MODEL env var. See https://openrouter.ai/models for choices.
# Common picks:
#   mistralai/mistral-large-2411            — strong, low refusal
#   meta-llama/llama-3.3-70b-instruct       — open weights, low refusal
#   nousresearch/hermes-3-llama-3.1-405b    — uncensored variant
#   anthropic/claude-3.7-sonnet             — Claude (still subject to AUP)
#   openai/gpt-4o                           — GPT-4o (still subject to AUP)
model="${OPENROUTER_MODEL:-mistralai/mistral-large-2411}"

system_preamble="You are a peer LLM called via OpenRouter for a second opinion. Be direct and useful. The user is a senior engineer; don't over-hedge or moralize."
case "$mode" in
  critique) system_preamble+=" Mode: critique — find flaws, edge cases, risks." ;;
  verify)   system_preamble+=" Mode: verify — confirm or refute claims with reasoning." ;;
  explore)  system_preamble+=" Mode: explore — surface alternatives." ;;
esac

# TODO: OpenRouter supports `:online` model suffix for web-augmented responses.
# Wire deep-research to that instead of (or alongside) longer reasoning.
if [[ "$deep" == "1" ]]; then
  case "$model" in
    *":online") ;;
    *) model="${model}:online" ;;
  esac
fi

# Output budget: second-opinion responses don't need more than ~3000 tokens
# (~2000 words). Caps paid output spend. Override via SECOND_OPINION_MAX_TOKENS.
max_tokens="${SECOND_OPINION_MAX_TOKENS:-3000}"

payload="$(jq -n \
  --arg model "$model" \
  --arg sys "$system_preamble" \
  --arg user "$prompt" \
  --argjson max_tokens "$max_tokens" \
  '{
    model: $model,
    messages: [
      {role:"system", content:$sys},
      {role:"user", content:$user}
    ],
    max_tokens: $max_tokens
  }')"

echo "=== provider: openrouter (model=$model, deep=$deep) ==="
response="$(curl -sS -X POST https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -H "HTTP-Referer: https://github.com/ajay-datashop/claude-code-channels" \
  -H "X-Title: second-opinion" \
  -d "$payload")"

if [[ -z "$response" ]]; then
  echo "error: empty response from OpenRouter" >&2
  exit 5
fi

content="$(echo "$response" | jq -r '
  if .error then "error: " + (.error.message // (.error | tostring))
  else (.choices[0].message.content // "no content")
  end')"
echo "$content"

# Surface citations if :online mode produced any
citations="$(echo "$response" | jq -r '.choices[0].message.annotations[]?.url_citation.url // empty' 2>/dev/null || true)"
if [[ -n "$citations" ]]; then
  echo
  echo "--- citations ---"
  echo "$citations"
fi

echo "=== end ==="
