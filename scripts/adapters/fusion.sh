#!/usr/bin/env bash
set -euo pipefail

# OpenRouter Fusion adapter — research-only, opt-in.
# `openrouter/fusion` is a panel+judge meta-model: it fans a query across several
# frontier models, runs live web research, and a judge synthesizes a single answer.
# It is separately billed at OpenRouter rates (panel = several model calls per query),
# so it is NOT in the auto-routing default set. The classifier only selects it when
# --deep-research is set AND the prompt is research-shaped; otherwise reach it via an
# explicit `--provider fusion`.

prompt="${1:-}"
mode="${SECOND_OPINION_MODE:-}"

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "error: OPENROUTER_API_KEY not set" >&2
  exit 4
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq required" >&2
  exit 4
fi

# Fixed to the Fusion meta-model. Override only if OpenRouter renames the slug.
model="${OPENROUTER_FUSION_MODEL:-openrouter/fusion}"

system_preamble="You are Fusion, a multi-model research panel called for a second opinion. Run multi-source research and synthesize a single grounded answer with citations. The user is a senior engineer; be direct, don't over-hedge or moralize."
case "$mode" in
  critique) system_preamble+=" Mode: critique — find flaws, edge cases, risks." ;;
  verify)   system_preamble+=" Mode: verify — confirm or refute claims with cited reasoning." ;;
  explore)  system_preamble+=" Mode: explore — surface alternatives." ;;
esac

# Research reports run longer than single-shot opinions. Default higher but still
# capped to bound paid spend. Override via SECOND_OPINION_MAX_TOKENS.
max_tokens="${SECOND_OPINION_MAX_TOKENS:-4000}"

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

echo "=== provider: fusion (model=$model, research=panel+judge) ==="
response="$(curl -sS -X POST https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -H "HTTP-Referer: https://github.com/ajay-datashop/claude-code-channels" \
  -H "X-Title: second-opinion" \
  -d "$payload")"

if [[ -z "$response" ]]; then
  echo "error: empty response from OpenRouter Fusion" >&2
  exit 5
fi

content="$(echo "$response" | jq -r '
  if .error then "error: " + (.error.message // (.error | tostring))
  else (.choices[0].message.content // "no content")
  end')"
echo "$content"

# Fusion grounds answers in web sources — surface its citations.
citations="$(echo "$response" | jq -r '.choices[0].message.annotations[]?.url_citation.url // empty' 2>/dev/null || true)"
if [[ -n "$citations" ]]; then
  echo
  echo "--- citations ---"
  echo "$citations"
fi

echo "=== end ==="
