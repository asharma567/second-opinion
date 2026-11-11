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

# Model selection. The adapter pins its own model instead of inheriting
# ~/.codex/config.toml, because the interactive/desktop Codex may be set to a
# model the CLI's ChatGPT-account entitlement rejects (e.g. 2026-11-11:
# config had gpt-6.1-sol → codex-cli 0.154.0 returned 400 model_not_found and
# every :reason round died at Author-A).
#   SECOND_OPINION_CODEX_MODEL           primary model (default below)
#                                        set to "inherit" to use config.toml's model
#   SECOND_OPINION_CODEX_FALLBACK_MODEL  tried once if the primary is rejected
#                                        with model_not_found ("" disables)
# Re-check periodically: `codex exec --skip-git-repo-check -m <slug> "say OK"`.
codex_model="${SECOND_OPINION_CODEX_MODEL:-gpt-6-astra}"
codex_fallback_model="${SECOND_OPINION_CODEX_FALLBACK_MODEL-gpt-5.6-sol}"

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
# to a plain call rather than failing the whole reason loop.
search_flag=()
if [[ "$deep" == "1" ]]; then
  search_flag=(-c tools.web_search=true)
  full_prompt="[deep-research mode: ground claims in real polls/studies/data; cite sources you are confident about, and do not fabricate citations]"$'\n\n'"$full_prompt"
fi

# Use --output-last-message to extract just the final assistant message, avoiding
# the CLI banner / workdir info / echoed prompt / transport-error noise that the
# default stdout includes. The session log goes to $log_file for diagnostics.
msg_file="$(mktemp -t second-opinion-codex.XXXXXX)"
log_file="$(mktemp -t second-opinion-codex-log.XXXXXX)"
trap 'rm -f "$msg_file" "$log_file"' EXIT

run_codex() {
  # run_codex <model|inherit> <use_search 0|1>. Writes final msg to $msg_file,
  # full session output to $log_file. Returns 0 only if a non-empty answer exists.
  local model="$1" use_search="$2"
  local args=(exec --skip-git-repo-check)
  [[ -n "$model" && "$model" != "inherit" ]] && args+=(-m "$model")
  [[ "$use_search" == "1" && ${#search_flag[@]} -gt 0 ]] && args+=("${search_flag[@]}")
  : > "$msg_file"
  codex "${args[@]}" --output-last-message "$msg_file" "$full_prompt" </dev/null >"$log_file" 2>&1 || true
  [[ -s "$msg_file" ]]
}

model_rejected() {
  grep -qE 'model_not_found|model is not supported' "$log_file"
}

used_model="$codex_model"
ok=0
if [[ "$deep" == "1" ]]; then
  if run_codex "$used_model" 1; then
    ok=1
  elif ! model_rejected; then
    echo "[codex] web-search flag rejected or empty output; retrying without web search" >&2
  fi
fi
if [[ "$ok" == "0" ]] && run_codex "$used_model" 0; then
  ok=1
fi
if [[ "$ok" == "0" ]] && model_rejected && [[ -n "$codex_fallback_model" && "$codex_fallback_model" != "$used_model" ]]; then
  echo "[codex] model '$used_model' rejected (model_not_found); retrying with fallback '$codex_fallback_model'" >&2
  used_model="$codex_fallback_model"
  run_codex "$used_model" "$deep" && ok=1
  if [[ "$ok" == "0" && "$deep" == "1" ]] && ! model_rejected; then
    run_codex "$used_model" 0 && ok=1
  fi
fi

if [[ "$ok" != "1" ]]; then
  # Never pass the banner/error log through as if it were an answer: callers
  # (reason.sh, fanout.sh) treat stdout as the model's opinion.
  if model_rejected; then
    echo "error: codex rejected model '$used_model' (model_not_found) for this ChatGPT account." >&2
    echo "  set SECOND_OPINION_CODEX_MODEL to an accepted slug (test: codex exec --skip-git-repo-check -m <slug> \"say OK\")" >&2
  else
    echo "error: codex returned no answer (model=$used_model)" >&2
  fi
  echo "--- codex error lines ---" >&2
  err_lines="$(grep -E '^ERROR: |"error"|error:' "$log_file" | grep -viE 'rmcp|oauth|mcp' | awk '!seen[$0]++' | tail -3 || true)"
  if [[ -n "$err_lines" ]]; then echo "$err_lines" >&2; else tail -5 "$log_file" >&2 || true; fi
  exit 6
fi

echo "=== provider: codex (model=$used_model, deep=$deep) ==="
cat "$msg_file"
echo
echo "=== end ==="
