#!/usr/bin/env bash
# Runs every scripts/tests/*.test.sh and bricks/*/tests/*.test.sh (enabled or not) and fails if any of them fails.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
status=0
for t in "$here"/*.test.sh "$root"/bricks/*/tests/*.test.sh; do
  [[ -f "$t" ]] || continue
  echo "--- ${t#"$root"/}"
  if ! bash "$t"; then status=1; fi
done
exit $status
