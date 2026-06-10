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

# Deep-research mode: try codex's config-based web search. codex 0.129.0 dropped
# the old `exec --search` flag (web search is now config-driven via
# `-c tools.web_search=true`). If the running CLI rejects/ignores the flag, degrade
# to a plain call rather than failing the whole reason loop — author_a failing
# aborts the entire round, so a broken flag must never be fatal.
search_flag=()
if [[ "$deep" == "1" ]]; then
  search_flag=(-c tools.web_search=true)
  full_prompt="[deep-research mode: ground claims in real polls/studies/data; cite sources you are confident about, and do not fabricate citations]"$'\n\n'"$full_prompt"
fi

# Use --output-last-message to extract just the final assistant message, avoiding
# the CLI banner / workdir info / echoed prompt / transport-error noise that the
# default stdout includes. The session log still goes to stdout (discarded).
msg_file="$(mktemp -t second-opinion-codex.XXXXXX)"
trap 'rm -f "$msg_file"' EXIT

run_codex() {
  # $1=1 → include web-search flag; $1=0 → plain. Writes final msg to $msg_file.
  if [[ "$1" == "1" && ${#search_flag[@]} -gt 0 ]]; then
    codex exec --skip-git-repo-check "${search_flag[@]}" --output-last-message "$msg_file" "$full_prompt" >/dev/null 2>&1
  else
    codex exec --skip-git-repo-check --output-last-message "$msg_file" "$full_prompt" >/dev/null 2>&1
  fi
}

echo "=== provider: codex (deep=$deep) ==="
ok=0
if [[ "$deep" == "1" ]]; then
  if run_codex 1 && [[ -s "$msg_file" ]]; then
    ok=1
  else
    echo "[codex] web-search flag rejected or empty output; retrying without web search" >&2
  fi
fi
if [[ "$ok" == "0" ]] && run_codex 0 && [[ -s "$msg_file" ]]; then
  ok=1
fi
if [[ "$ok" == "1" ]]; then
  cat "$msg_file"
else
  # Last resort: noisy stdout (plain, no flags) so we still surface something.
  echo "[codex] --output-last-message empty; falling back to stdout (may include banner)" >&2
  codex exec --skip-git-repo-check "$full_prompt" 2>&1
fi
echo "=== end ==="
