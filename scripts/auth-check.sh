#!/usr/bin/env bash
set -uo pipefail

if [[ -r "$HOME/.openclaw-tgpkb/secrets/llm_keys.sh" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.openclaw-tgpkb/secrets/llm_keys.sh"
fi

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; }
skip() { printf "  \033[33m-\033[0m %s\n" "$1"; }

echo "Auth check: second-opinion adapters"
echo

# Codex (OpenAI) — uses ChatGPT subscription via codex CLI, no API key
echo "Codex (OpenAI / ChatGPT subscription):"
if ! command -v codex >/dev/null 2>&1; then fail "codex CLI not on PATH (npm install -g @openai/codex)"
else ok "codex on PATH ($(codex --version 2>&1 | head -1)) — auth via ChatGPT sub"
fi
echo

# Grok (xAI)
echo "Grok (xAI):"
if [[ -z "${XAI_API_KEY:-}" ]]; then skip "XAI_API_KEY not set"
else
  resp="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST https://api.x.ai/v1/chat/completions \
    -H "Authorization: Bearer $XAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"grok-4-latest","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' || echo 000)"
  if [[ "$resp" == "200" ]]; then ok "XAI_API_KEY reachable (HTTP $resp)"
  else fail "XAI_API_KEY HTTP $resp"
  fi
fi
echo

# Claude — adapter dropped. Spawn a subagent from the lead session instead.

# OpenRouter
echo "OpenRouter:"
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then skip "OPENROUTER_API_KEY not set"
else
  resp="$(curl -sS -o /dev/null -w '%{http_code}' \
    https://openrouter.ai/api/v1/auth/key \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" || echo 000)"
  if [[ "$resp" == "200" ]]; then ok "OPENROUTER_API_KEY reachable (HTTP $resp)"
  else fail "OPENROUTER_API_KEY HTTP $resp"
  fi
fi
echo

# Gemini
echo "Gemini (Google):"
if [[ -z "${GEMINI_API_KEY:-}" ]]; then skip "GEMINI_API_KEY not set"
else
  resp="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"contents":[{"role":"user","parts":[{"text":"ping"}]}]}' || echo 000)"
  if [[ "$resp" == "200" ]]; then ok "GEMINI_API_KEY reachable (HTTP $resp)"
  else fail "GEMINI_API_KEY HTTP $resp"
  fi
fi
echo

echo "Done."
