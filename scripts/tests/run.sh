#!/usr/bin/env bash
# Runs every scripts/tests/*.test.sh and fails if any of them fails.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
for t in "$here"/*.test.sh; do
  echo "--- $(basename "$t")"
  if ! bash "$t"; then status=1; fi
done
exit $status
