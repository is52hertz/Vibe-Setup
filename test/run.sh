#!/usr/bin/env bash
# Run every suite and report a combined result.
#
#   test/dry-run.sh   drives the CLI and asserts on what it prints
#   test/units.sh     exercises the libraries under lib/ directly
#
# Run: ./test/run.sh   (exit 0 = all pass, 1 = some failed)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SUITES=(
  "dry-run.sh"
  "units.sh"
)

FAILED=0

for suite in "${SUITES[@]}"; do
  printf '\n=== %s ===\n' "${suite}"
  if ! "${SCRIPT_DIR}/${suite}"; then
    FAILED=$((FAILED + 1))
  fi
done

printf '\n'
if [[ "${FAILED}" -eq 0 ]]; then
  printf 'ALL SUITES PASSED\n'
  exit 0
fi
printf '%d SUITE(S) FAILED\n' "${FAILED}"
exit 1
