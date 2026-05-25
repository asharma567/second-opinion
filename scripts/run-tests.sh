#!/usr/bin/env bash
# run-tests.sh — runs all offline test cases in tests/test_*.sh.
#
# Offline only: no live API calls. Tests cover classification routing,
# argument parsing, and output-contract conformance.
#
# Exit code: 0 if every test passed, 1 if any failed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_DIR/tests"

if [[ ! -d "$TEST_DIR" ]]; then
  echo "no tests/ dir at $TEST_DIR" >&2; exit 1
fi

pass=0
fail=0
failed_names=()

shopt -s nullglob
for t in "$TEST_DIR"/test_*.sh; do
  name="$(basename "$t" .sh)"
  printf "  %-40s " "$name"
  if bash "$t" >/tmp/so_test_$$.out 2>&1; then
    printf "\033[32mPASS\033[0m\n"
    pass=$((pass+1))
  else
    printf "\033[31mFAIL\033[0m\n"
    fail=$((fail+1))
    failed_names+=("$name")
    sed 's/^/      /' /tmp/so_test_$$.out
  fi
  rm -f /tmp/so_test_$$.out
done

echo
echo "Tests: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  echo "Failed:"
  for n in "${failed_names[@]}"; do echo "  - $n"; done
  exit 1
fi
