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

# Deep-research mode: enable codex's native live web search (Responses web_search
# tool, exposed via `codex exec --search`) so codex grounds its answer in real
# sources like the other providers, instead of just being nudged via text.
search_flag=()
if [[ "$deep" == "1" ]]; then
  search_flag=(--search)
  full_prompt="[deep-research mode: use live web search; ground claims in sources and cite them]"$'\n\n'"$full_prompt"
fi

# Use --output-last-message to extract just the final assistant message, avoiding
# the CLI banner / workdir info / echoed prompt / transport-error noise that the
# default stdout includes. The session log still goes to stdout (discarded).
msg_file="$(mktemp -t second-opinion-codex.XXXXXX)"
trap 'rm -f "$msg_file"' EXIT

echo "=== provider: codex (deep=$deep) ==="
if codex exec --skip-git-repo-check ${search_flag[@]+"${search_flag[@]}"} --output-last-message "$msg_file" "$full_prompt" >/dev/null 2>&1; then
  cat "$msg_file"
else
  # Fall back to noisy stdout if --output-last-message produced nothing useful
  echo "[codex] --output-last-message empty; falling back to stdout (may include banner)" >&2
  codex exec --skip-git-repo-check ${search_flag[@]+"${search_flag[@]}"} "$full_prompt" 2>&1
fi
echo "=== end ==="
