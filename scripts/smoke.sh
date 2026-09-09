#!/usr/bin/env bash
# Gate the published module interface against the skeleton that consumes it.
#
# Runs in a throwaway copy with both module sources pointed at the WORKING TREE,
# which is what breaks the ordering circle: the skeleton pins a tag, and a gate
# that resolved a real pin would test the previous release or fail to resolve.
#
# It counts test files and runs before believing an exit code. Measured:
# `terraform test` with zero test files prints "Success! 0 passed, 0 failed."
# and exits 0 — indistinguishable from a pass to anything reading $?. A gate
# that survives its own test file being deleted or renamed is not a gate.
#
# Run via `make smoke`.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIN_RUNS=5

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Trailing /. copies the CONTENTS, dotfiles included. `cp -r src dst` with dst
# existing would nest it as $WORK/tenant-skeleton and every path below would be
# wrong — quietly, because find would then report zero test files and this
# script's own first check would blame the skeleton.
cp -r "$ROOT/tenant-skeleton/." "$WORK/"

# The skeleton does not ship pin-to-worktree.sh: it is a gate tool, and a tenant
# has no reason to hold it. The copy needs it because the script derives its own
# root from its location.
mkdir -p "$WORK/scripts"
cp "$ROOT/scripts/pin-to-worktree.sh" "$WORK/scripts/"

files=$(find "$WORK/vms/tests" -name '*.tftest.hcl' -type f 2>/dev/null | wc -l)
if [ "$files" -eq 0 ]; then
  echo "✗ smoke: no test files under tenant-skeleton/vms/tests/"
  echo "  terraform test would print 'Success! 0 passed' and exit 0 here."
  exit 1
fi

( cd "$WORK" && ./scripts/pin-to-worktree.sh "$ROOT/vms/modules" ) || {
  echo "✗ smoke: could not point the skeleton at the working tree"
  exit 1
}

out=$( cd "$WORK/vms" && terraform init -backend=false -no-color 2>&1 && terraform test -no-color 2>&1 )
status=$?

echo "$out"

if [ "$status" -ne 0 ]; then
  echo "✗ smoke: the skeleton does not pass against this working tree"
  exit 1
fi

passed=$(echo "$out" | sed -n 's/^Success! \([0-9]*\) passed.*/\1/p' | tail -1)
if [ -z "$passed" ] || [ "$passed" -lt "$MIN_RUNS" ]; then
  echo "✗ smoke: expected at least $MIN_RUNS runs, terraform reported '${passed:-none}'"
  echo "  A run that was deleted or renamed out of the file leaves this green"
  echo "  otherwise, which is the one thing a gate must not do."
  exit 1
fi

echo "✓ smoke: the skeleton passes against this working tree ($passed runs)"
