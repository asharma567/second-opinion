#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-}"
mode="${SECOND_OPINION_MODE:-}"
deep="${SECOND_OPINION_DEEP_RESEARCH:-0}"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADAPTERS="$SKILL_DIR/scripts/adapters"

# Fall-through default is the current Gemini flagship (checked against
# OpenRouter's /models catalog — NOT a "-latest" alias string, those showed up
# in the catalog listing but are not actually invokable; verified by testing).
# This adapter's job is to BE gemini, so it should stay max-tier even when
# routed through OpenRouter. Uses its own dedicated var (not the shared
# OPENROUTER_MODEL, which the openrouter.sh refusal-fallback adapter also
# reads for an unrelated purpose — reusing it here would let one override
# silently change the other's model).
# Override via SECOND_OPINION_GEMINI_OPENROUTER_MODEL. Re-check periodically:
# OpenRouter model slugs get superseded (this one replaced gemini-2.5-pro).
gemini_or_model="${SECOND_OPINION_GEMINI_OPENROUTER_MODEL:-google/gemini-4-argon}"

fall_through_to_openrouter() {
  local reason="$1"
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    echo "[gemini] $reason — falling through to OpenRouter (model=$gemini_or_model)" >&2
    OPENROUTER_MODEL="$gemini_or_model" exec "$ADAPTERS/openrouter.sh" "$prompt"
  fi
  echo "error: $reason and OPENROUTER_API_KEY not set for fallback" >&2
  exit 4
}

# Gemini direct API is disabled by default: the Google Cloud billing account tied
# to GEMINI_API_KEY is suspended ("prepayment credits depleted"), so the direct
# call fails on every invocation and only wastes a round-trip before falling
# through. Route the gemini role straight to OpenRouter's current flagship
# (override via SECOND_OPINION_GEMINI_OPENROUTER_MODEL).
# Set SECOND_OPINION_GEMINI_DIRECT=1 to re-enable the direct call once the
# Google Cloud billing dispute is resolved (see PER-18).
if [[ "${SECOND_OPINION_GEMINI_DIRECT:-0}" != "1" ]]; then
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    echo "[gemini] direct API disabled (billing suspended) — routing to OpenRouter (model=$gemini_or_model)" >&2
    OPENROUTER_MODEL="$gemini_or_model" exec "$ADAPTERS/openrouter.sh" "$prompt"
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

model="${GEMINI_MODEL:-gemini-4-argon}"

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

# Output budget: second-opinion responses don't need more than ~3000 tokens
# (~2000 words). Caps paid output spend. Override via SECOND_OPINION_MAX_TOKENS.
# Note: Gemini 2.5 counts thinking tokens against maxOutputTokens, so this also
# bounds hidden reasoning spend.
max_tokens="${SECOND_OPINION_MAX_TOKENS:-3000}"

payload="$(jq -n \
  --arg sys "$system_preamble" \
  --arg user "$prompt" \
  --argjson tools "$tools_json" \
  --argjson max_tokens "$max_tokens" \
  '{
    systemInstruction: { parts: [ { text: $sys } ] },
    contents: [ { role:"user", parts: [ { text: $user } ] } ],
    generationConfig: { maxOutputTokens: $max_tokens },
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
