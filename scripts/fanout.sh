#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTERS="$SKILL_DIR/scripts/adapters"

if [[ -r "$HOME/.openclaw-tgpkb/secrets/llm_keys.sh" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.openclaw-tgpkb/secrets/llm_keys.sh"
fi

prompt="${1:-}"

if [[ -z "$prompt" ]]; then
  echo "error: prompt required" >&2
  exit 2
fi

tmpdir="$(mktemp -d -t second-opinion-fanout.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

providers=()
# Codex via CLI subprocess (rides on ChatGPT subscription, not API key)
command -v codex >/dev/null 2>&1 && providers+=(codex)
[[ -n "${XAI_API_KEY:-}"        ]] && providers+=(grok)
[[ -n "${GEMINI_API_KEY:-}"     ]] && providers+=(gemini)
[[ -n "${OPENROUTER_API_KEY:-}" ]] && providers+=(openrouter)
# Note: Claude adapter dropped — to get a Claude second opinion, spawn a subagent
# from the lead session instead (uses harness auth, no API double-bill).

if [[ ${#providers[@]} -eq 0 ]]; then
  echo "error: no providers configured (set at least one *_API_KEY)" >&2
  exit 4
fi

echo "[fanout] calling: ${providers[*]}" >&2

# Budget instruction: fan-out responses get synthesized by the lead session, so
# N providers x long answers = N x token burn. Keep each response tight.
budgeted_prompt="$prompt"$'\n\n'"[Response budget: at most 400 words. Be dense and concrete — no filler, no restating the question.]"

pids=()
for p in "${providers[@]}"; do
  ( "$ADAPTERS/${p}.sh" "$budgeted_prompt" >"$tmpdir/$p.out" 2>"$tmpdir/$p.err"; echo $? >"$tmpdir/$p.rc" ) &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done

# Collect each provider's output
combined="$tmpdir/combined.txt"
: > "$combined"
for p in "${providers[@]}"; do
  rc="$(cat "$tmpdir/$p.rc" 2>/dev/null || echo 99)"
  if [[ "$rc" == "0" ]]; then
    # Cap what flows back into the lead session's context: 8000 bytes per
    # provider is plenty for a 400-word budgeted answer + envelope/citations.
    out_bytes="$(wc -c < "$tmpdir/$p.out" | tr -d ' ')"
    head -c 8000 "$tmpdir/$p.out" >> "$combined"
    if [[ "$out_bytes" -gt 8000 ]]; then
      {
        echo
        echo "[fanout] $p output truncated ($out_bytes -> 8000 bytes)"
        echo "=== end ==="
      } >> "$combined"
    fi
    echo >> "$combined"
  else
    {
      echo "=== provider: $p (FAILED rc=$rc) ==="
      cat "$tmpdir/$p.err"
      echo "=== end ==="
      echo
    } >> "$combined"
  fi
done

echo "=== fanout: raw responses ==="
cat "$combined"
echo
echo "(synthesis: have the lead Claude session synthesize the raw responses above —"
echo " no need to round-trip through an API adapter when the lead is already Claude.)"
