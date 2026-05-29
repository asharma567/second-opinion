#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-}"
mode="${SECOND_OPINION_MODE:-}"
deep="${SECOND_OPINION_DEEP_RESEARCH:-0}"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADAPTERS="$SKILL_DIR/scripts/adapters"

fall_through_to_openrouter() {
  local reason="$1"
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    echo "[gemini] $reason — falling through to OpenRouter (model=${OPENROUTER_MODEL:-google/gemini-2.5-pro})" >&2
    OPENROUTER_MODEL="${OPENROUTER_MODEL:-google/gemini-2.5-pro}" \
      exec "$ADAPTERS/openrouter.sh" "$prompt"
  fi
  echo "error: $reason and OPENROUTER_API_KEY not set for fallback" >&2
  exit 4
}

# Gemini direct API is disabled by default: the Google Cloud billing account tied
# to GEMINI_API_KEY is suspended ("prepayment credits depleted"), so the direct
# call fails on every invocation and only wastes a round-trip before falling
# through. Route the gemini role straight to OpenRouter's google/gemini-2.5-pro.
# Set SECOND_OPINION_GEMINI_DIRECT=1 to re-enable the direct call once the
# Google Cloud billing dispute is resolved (see PER-18).
if [[ "${SECOND_OPINION_GEMINI_DIRECT:-0}" != "1" ]]; then
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    echo "[gemini] direct API disabled (billing suspended) — routing to OpenRouter (model=${OPENROUTER_MODEL:-google/gemini-2.5-pro})" >&2
    OPENROUTER_MODEL="${OPENROUTER_MODEL:-google/gemini-2.5-pro}" \
      exec "$ADAPTERS/openrouter.sh" "$prompt"
  fi
  echo "error: gemini direct API disabled and OPENROUTER_API_KEY not set for routing" >&2
  exit 4
fi

if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  fall_through_to_openrouter "GEMINI_API_KEY not set"
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq required" >&2
  exit 4
fi

model="${GEMINI_MODEL:-gemini-2.5-pro}"

system_preamble="You are Gemini, called as a second-opinion peer with strong visual + design + multimodal reasoning."
case "$mode" in
  critique) system_preamble+=" Mode: critique — find flaws and risks." ;;
  verify)   system_preamble+=" Mode: verify — confirm or refute with reasoning." ;;
  explore)  system_preamble+=" Mode: explore — surface alternatives." ;;
esac

# TODO: real Gemini Deep Research uses a research-agent endpoint not yet GA via API.
# As a stand-in, enable Google Search grounding for deep mode.
tools_json="null"
if [[ "$deep" == "1" ]]; then
  tools_json='[{"google_search":{}}]'
fi

payload="$(jq -n \
  --arg sys "$system_preamble" \
  --arg user "$prompt" \
  --argjson tools "$tools_json" \
  '{
    systemInstruction: { parts: [ { text: $sys } ] },
    contents: [ { role:"user", parts: [ { text: $user } ] } ],
    tools: $tools
  } | if .tools == null then del(.tools) else . end')"

response="$(curl -sS -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$payload")"

if [[ -z "$response" ]]; then
  fall_through_to_openrouter "empty response from Gemini"
fi

err_msg="$(echo "$response" | jq -r '.error.message // empty')"
if [[ -n "$err_msg" ]]; then
  fall_through_to_openrouter "Gemini error: $err_msg"
fi

content="$(echo "$response" | jq -r '(.candidates[0].content.parts // []) | map(.text // "") | join("\n\n")')"
if [[ -z "$content" ]]; then
  fall_through_to_openrouter "Gemini returned no content"
fi

echo "=== provider: gemini (model=$model, deep=$deep) ==="
echo "$content"
echo "=== end ==="
