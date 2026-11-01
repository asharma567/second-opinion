#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-}"
mode="${SECOND_OPINION_MODE:-}"
deep="${SECOND_OPINION_DEEP_RESEARCH:-0}"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADAPTERS="$SKILL_DIR/scripts/adapters"

# Dedicated var (not the shared OPENROUTER_MODEL, which openrouter.sh's own
# refusal-fallback role also reads) so a grok outage doesn't silently swap
# in a weaker/different-purpose model for that unrelated role.
grok_or_model="${SECOND_OPINION_GROK_OPENROUTER_MODEL:-x-ai/grok-4.7}"

fall_through_to_openrouter() {
  local reason="$1"
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    echo "[grok] $reason — falling through to OpenRouter (model=$grok_or_model)" >&2
    OPENROUTER_MODEL="$grok_or_model" exec "$ADAPTERS/openrouter.sh" "$prompt"
  fi
  echo "error: $reason and OPENROUTER_API_KEY not set for fallback" >&2
  exit 4
}

# Direct xAI API is disabled by default — route through OpenRouter instead,
# same architecture as the gemini adapter. Reason: OpenRouter's catalog is
# actively maintained (correct current model slugs, verified against xAI's
# own deprecation notices), whereas a locally-pinned "grok-4-latest" string
# sent straight to api.x.ai can silently diverge from what's actually current.
# Set SECOND_OPINION_GROK_DIRECT=1 to call api.x.ai directly instead.
if [[ "${SECOND_OPINION_GROK_DIRECT:-0}" != "1" ]]; then
  fall_through_to_openrouter "direct xAI API disabled by default (routes via OpenRouter)"
fi

if [[ -z "${XAI_API_KEY:-}" ]]; then
  fall_through_to_openrouter "XAI_API_KEY not set"
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq required" >&2
  exit 4
fi

model="${GROK_MODEL:-grok-4-latest}"

system_preamble="You are Grok. Be direct, witty when appropriate, and don't hedge."
case "$mode" in
  critique) system_preamble+=" Mode: critical review — find weaknesses." ;;
  verify)   system_preamble+=" Mode: verify — confirm or refute claims with reasoning." ;;
  explore)  system_preamble+=" Mode: explore — surface alternatives." ;;
esac

# TODO: xAI Live Search / DeepSearch — wire `search_parameters` here
# Docs: https://docs.x.ai/docs/guides/live-search
search_params="null"
if [[ "$deep" == "1" ]]; then
  search_params='{"mode":"on","return_citations":true}'
fi

# Output budget: second-opinion responses don't need more than ~3000 tokens
# (~2000 words). Caps paid output spend. Override via SECOND_OPINION_MAX_TOKENS.
max_tokens="${SECOND_OPINION_MAX_TOKENS:-3000}"

payload="$(jq -n \
  --arg model "$model" \
  --arg sys "$system_preamble" \
  --arg user "$prompt" \
  --argjson search "$search_params" \
  --argjson max_tokens "$max_tokens" \
  '{
    model: $model,
    messages: [
      {role:"system", content:$sys},
      {role:"user", content:$user}
    ],
    max_tokens: $max_tokens,
    search_parameters: $search
  } | if .search_parameters == null then del(.search_parameters) else . end')"

response="$(curl -sS -X POST https://api.x.ai/v1/chat/completions \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$payload")"

if [[ -z "$response" ]]; then
  fall_through_to_openrouter "empty response from xAI"
fi

# xAI error responses put a plain STRING in `.error` (not OpenAI's `.error.message`
# object). Handle both shapes so a server error triggers fallback instead of
# crashing jq (which, under `set -e`, would abort the whole reason loop) or
# silently printing the error text as if it were a real opinion.
api_err="$(echo "$response" | jq -r '(if (.error|type)=="object" then .error.message else .error end) // empty')"
if [[ -n "$api_err" ]]; then
  fall_through_to_openrouter "xAI error: $api_err"
fi

content="$(echo "$response" | jq -r '.choices[0].message.content // empty')"
if [[ -z "$content" ]]; then
  fall_through_to_openrouter "xAI returned no content"
fi

echo "=== provider: grok (model=$model, deep=$deep) ==="
echo "$content"

if [[ "$deep" == "1" ]]; then
  citations="$(echo "$response" | jq -r '.citations[]? // empty')"
  if [[ -n "$citations" ]]; then
    echo
    echo "--- citations ---"
    echo "$citations"
  fi
fi

echo "=== end ==="
