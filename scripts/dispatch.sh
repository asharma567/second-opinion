#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTERS="$SKILL_DIR/scripts/adapters"

# Load LLM API keys from secrets dir if env vars aren't already set
if [[ -r "$HOME/.openclaw-tgpkb/secrets/llm_keys.sh" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.openclaw-tgpkb/secrets/llm_keys.sh"
fi

provider=""
mode=""
input_file=""
deep_research=0
fanout=0
prompt_parts=()

usage() {
  cat <<'EOF'
Usage: dispatch.sh [options] <prompt>

Options:
  --provider <name>      codex | grok | gemini | openrouter | fusion  (skip auto-routing)
                         (fusion = OpenRouter research panel; research-only, billed)
                         (Claude not listed: spawn a subagent from the lead instead)
  --mode <m>             explore | critique | verify       (passed to adapter)
  --input-file <path>    attach file content to prompt
  --deep-research        enable provider's research mode (where supported)
  --fanout               call all configured providers in parallel
  -h, --help             show this help

Env vars (set the ones for providers you use):
  XAI_API_KEY  GEMINI_API_KEY  OPENROUTER_API_KEY
  (Codex uses ChatGPT subscription via codex CLI — no env var needed)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) provider="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --input-file) input_file="$2"; shift 2 ;;
    --deep-research) deep_research=1; shift ;;
    --fanout) fanout=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do prompt_parts+=("$1"); shift; done ;;
    *) prompt_parts+=("$1"); shift ;;
  esac
done

prompt="${prompt_parts[*]:-}"

if [[ -z "$prompt" && -z "$input_file" ]]; then
  echo "error: prompt or --input-file required" >&2
  usage >&2
  exit 2
fi

if [[ -n "$input_file" ]]; then
  if [[ ! -f "$input_file" ]]; then
    echo "error: input file not found: $input_file" >&2
    exit 2
  fi
  prompt+=$'\n\n--- attached file: '"$input_file"$' ---\n'"$(cat "$input_file")"
fi

export SECOND_OPINION_MODE="$mode"
export SECOND_OPINION_DEEP_RESEARCH="$deep_research"

if [[ "$fanout" == "1" ]]; then
  exec "$SKILL_DIR/scripts/fanout.sh" "$prompt"
fi

if [[ -z "$provider" ]]; then
  provider="$("$SKILL_DIR/scripts/classify.sh" "$prompt")"
  echo "[router] selected provider: $provider" >&2
fi

adapter="$ADAPTERS/${provider}.sh"
if [[ ! -x "$adapter" ]]; then
  echo "error: no adapter for provider '$provider' (looked at $adapter)" >&2
  exit 3
fi

exec "$adapter" "$prompt"
