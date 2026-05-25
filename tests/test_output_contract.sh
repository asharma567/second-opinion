#!/usr/bin/env bash
# Offline test: every adapter under scripts/adapters/ must include the
# stdout markers required by the fan-out parser.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTERS_DIR="$REPO_DIR/scripts/adapters"

if [[ ! -d "$ADAPTERS_DIR" ]]; then
  echo "FAIL: adapters dir missing: $ADAPTERS_DIR" >&2; exit 1
fi

shopt -s nullglob
adapters=("$ADAPTERS_DIR"/*.sh)
if [[ "${#adapters[@]}" -eq 0 ]]; then
  echo "FAIL: no adapter scripts found" >&2; exit 1
fi

fail=0
for a in "${adapters[@]}"; do
  name="$(basename "$a" .sh)"
  if ! grep -q "=== provider:" "$a"; then
    echo "  $name: missing '=== provider:' header" >&2; fail=$((fail+1))
  fi
  if ! grep -q "=== end ===" "$a"; then
    echo "  $name: missing '=== end ===' footer" >&2; fail=$((fail+1))
  fi
  if [[ ! -x "$a" ]]; then
    echo "  $name: not executable" >&2; fail=$((fail+1))
  fi
done

if [[ "$fail" -gt 0 ]]; then
  echo "$fail contract violation(s) across ${#adapters[@]} adapter(s)" >&2; exit 1
fi
echo "all ${#adapters[@]} adapters conform to output contract"
