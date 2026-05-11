#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-}"
mode="${SECOND_OPINION_MODE:-}"
deep="${SECOND_OPINION_DEEP_RESEARCH:-0}"

if [[ -z "${XAI_API_KEY:-}" ]]; then
  echo "error: XAI_API_KEY not set" >&2
  exit 4
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

payload="$(jq -n \
  --arg model "$model" \
  --arg sys "$system_preamble" \
  --arg user "$prompt" \
  --argjson search "$search_params" \
  '{
    model: $model,
    messages: [
      {role:"system", content:$sys},
      {role:"user", content:$user}
    ],
    search_parameters: $search
  } | if .search_parameters == null then del(.search_parameters) else . end')"

echo "=== provider: grok (model=$model, deep=$deep) ==="
response="$(curl -sS -X POST https://api.x.ai/v1/chat/completions \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$payload")"

if [[ -z "$response" ]]; then
  echo "error: empty response from xAI" >&2
  exit 5
fi

content="$(echo "$response" | jq -r '.choices[0].message.content // .error.message // "no content"')"
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
