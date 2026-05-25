#!/usr/bin/env bash
# install.sh — guided installer for second-opinion.
#
# Idempotent. Run it as many times as you like — it just confirms state
# and offers to fix anything that's not set up.
#
# Steps:
#   1. Verify shell + curl
#   2. Symlink the repo into ~/.claude/skills/second-opinion (if you want
#      to invoke it from Claude Code as a skill)
#   3. Add a `second-opinion` wrapper to ~/.local/bin (so it's on PATH)
#   4. Check for at least one provider CLI or API key
#   5. Run auth-check
#
# Bypass interactivity with --yes (assumes yes to every prompt).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSUME_YES=0
[[ "${1:-}" == "--yes" ]] && ASSUME_YES=1

bold()  { printf "\033[1m%s\033[0m\n" "$1"; }
ok()    { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$1"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
ask()   {
  local prompt="$1" default="${2:-y}"
  if [[ "$ASSUME_YES" == "1" ]]; then
    echo "$prompt [auto: $default]"; [[ "$default" == "y" ]] && return 0 || return 1
  fi
  read -r -p "$prompt [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

bold "second-opinion installer"
echo "Repo: $REPO_DIR"
echo

# 1. Shell + curl preconditions
bold "1. Preconditions"
if ! command -v bash >/dev/null 2>&1; then fail "bash not found"; exit 1; fi
ok "bash $(bash --version | head -1 | awk '{print $4}')"
if ! command -v curl >/dev/null 2>&1; then fail "curl not found — install it first"; exit 1; fi
ok "curl present"
echo

# 2. Skill symlink (for Claude Code, OpenCode, etc.)
bold "2. Claude Code skill symlink"
SKILL_LINK="$HOME/.claude/skills/second-opinion"
if [[ -L "$SKILL_LINK" ]]; then
  target="$(readlink "$SKILL_LINK")"
  if [[ "$target" == "$REPO_DIR" ]]; then
    ok "already symlinked: $SKILL_LINK → $REPO_DIR"
  else
    warn "symlink points elsewhere: $SKILL_LINK → $target"
    if ask "Replace symlink to point at this repo?"; then
      rm "$SKILL_LINK"; ln -s "$REPO_DIR" "$SKILL_LINK"; ok "updated"
    fi
  fi
elif [[ -e "$SKILL_LINK" ]]; then
  fail "$SKILL_LINK exists and is NOT a symlink — leaving it alone"
else
  if ask "Create symlink so Claude Code can find the skill?"; then
    mkdir -p "$HOME/.claude/skills"
    ln -s "$REPO_DIR" "$SKILL_LINK"
    ok "created $SKILL_LINK → $REPO_DIR"
  else
    warn "skipped — skill won't be discoverable by Claude Code"
  fi
fi
echo

# 3. PATH wrapper
bold "3. CLI wrapper on PATH"
BIN_DIR="$HOME/.local/bin"
WRAPPER="$BIN_DIR/second-opinion"
if [[ -x "$WRAPPER" ]]; then
  ok "wrapper already present: $WRAPPER"
else
  if ask "Install wrapper at $WRAPPER?"; then
    mkdir -p "$BIN_DIR"
    cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
exec "$REPO_DIR/scripts/dispatch.sh" "\$@"
EOF
    chmod +x "$WRAPPER"
    ok "installed $WRAPPER"
    case ":$PATH:" in
      *":$BIN_DIR:"*) ok "$BIN_DIR already on PATH" ;;
      *) warn "$BIN_DIR not on PATH — add this to your shell rc:"; echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
  else
    warn "skipped — invoke directly with $REPO_DIR/scripts/dispatch.sh"
  fi
fi
echo

# 4. At least one provider configured?
bold "4. Provider availability"
have_one=0
if command -v codex >/dev/null 2>&1; then
  ok "codex CLI present (rides on ChatGPT subscription)"; have_one=1
else
  warn "codex CLI not installed — \`npm install -g @openai/codex\` to enable subscription-routed OpenAI calls"
fi

for var in XAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY; do
  if [[ -n "${!var:-}" ]]; then
    ok "$var set in environment"; have_one=1
  elif [[ -r "$HOME/.openclaw-tgpkb/secrets/${var,,}" ]]; then
    ok "key file present: ~/.openclaw-tgpkb/secrets/${var,,}"; have_one=1
  fi
done

if [[ "$have_one" == "0" ]]; then
  warn "no providers configured yet. Install codex (recommended, no API cost on a ChatGPT sub):"
  echo "    npm install -g @openai/codex"
  echo "  Or drop a key at one of:"
  echo "    ~/.openclaw-tgpkb/secrets/xai_api_key"
  echo "    ~/.openclaw-tgpkb/secrets/gemini_api_key"
  echo "    ~/.openclaw-tgpkb/secrets/openrouter_api_key"
fi
echo

# 5. Auth check
bold "5. Auth check"
if [[ "$have_one" == "1" ]] && ask "Run scripts/auth-check.sh now?"; then
  "$REPO_DIR/scripts/auth-check.sh" || true
else
  warn "skipped — run \`$REPO_DIR/scripts/auth-check.sh\` later to verify"
fi
echo

bold "Done."
echo "Try: second-opinion \"should I use Postgres or DuckDB for this\""
