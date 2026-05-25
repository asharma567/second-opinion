#!/usr/bin/env bash
# Parity score: count missing structural items vs udit/autoresearch model.
# Each item must exist AND meet a minimum content threshold (so empty
# touch files don't game the score).
set -u
cd "$(dirname "$0")/.."

missing=0
check_file_min() {
  local path="$1" min_bytes="$2"
  if [ ! -f "$path" ]; then
    echo "  ✗ $path (missing)"; missing=$((missing+1))
  else
    sz=$(wc -c < "$path" | tr -d ' ')
    if [ "$sz" -lt "$min_bytes" ]; then
      echo "  ✗ $path (only $sz bytes; need >=$min_bytes)"; missing=$((missing+1))
    else
      echo "  ✓ $path ($sz bytes)"
    fi
  fi
}
check_dir_has_files() {
  local path="$1" min_files="$2"
  if [ ! -d "$path" ]; then
    echo "  ✗ $path/ (missing)"; missing=$((missing+1))
  else
    nfiles=$(find "$path" -type f | wc -l | tr -d ' ')
    if [ "$nfiles" -lt "$min_files" ]; then
      echo "  ✗ $path/ (only $nfiles files; need >=$min_files)"; missing=$((missing+1))
    else
      echo "  ✓ $path/ ($nfiles files)"
    fi
  fi
}

echo "=== Parity check vs udit/autoresearch model ==="
check_file_min LICENSE 500
check_file_min AGENTS.md 1500
check_file_min CONTRIBUTING.md 800
check_file_min COMPARISON.md 1500
check_file_min CONTEXT.md 800
check_file_min scripts/install.sh 400
check_file_min scripts/run-tests.sh 200
check_dir_has_files tests 2
check_dir_has_files guide 2

echo
echo "SCORE=$missing"
