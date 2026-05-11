#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-}"
mode="${SECOND_OPINION_MODE:-}"
deep="${SECOND_OPINION_DEEP_RESEARCH:-0}"

if ! command -v codex >/dev/null 2>&1; then
  echo "error: codex CLI not on PATH (npm install -g @openai/codex)" >&2
  exit 4
fi
# Note: codex CLI authenticates via ChatGPT subscription (Mac/Plus/Pro), not OPENAI_API_KEY.
# Do not check for OPENAI_API_KEY here — it would falsely block users with a sub but no API key.

system_preamble=""
case "$mode" in
  critique) system_preamble="You are a critical reviewer. Identify weaknesses, edge cases, and risks." ;;
  verify)   system_preamble="You are verifying claims. Confirm or refute with reasoning." ;;
  explore)  system_preamble="You are exploring options. Surface alternatives I may not have considered." ;;
esac

full_prompt="$prompt"
if [[ -n "$system_preamble" ]]; then
  full_prompt="$system_preamble"$'\n\n'"$prompt"
fi

# TODO: when OpenAI Deep Research is exposed via codex CLI, wire --deep-research to it
if [[ "$deep" == "1" ]]; then
  full_prompt="[deep-research mode requested — provide thorough multi-source reasoning]"$'\n\n'"$full_prompt"
fi

echo "=== provider: codex ==="
codex exec --skip-git-repo-check "$full_prompt" 2>&1
echo "=== end ==="
