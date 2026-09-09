#!/usr/bin/env bash
# Point both module sources at a local path instead of a published tag.
#
# This exists to break an ordering circle. `make release` must run the skeleton
# smoke test before cutting a tag; the skeleton pins a tag; so a gate that
# resolved a real pin would test the PREVIOUS release, or fail to resolve at
# all. Pointing at the working tree tests what is about to be tagged.
#
# It is never used by a tenant and is not reachable from any Makefile target a
# tenant has. scripts/smoke.sh calls it, in a throwaway copy of the skeleton.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "cannot enter the repository root ($ROOT)"; exit 1; }

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: pin-to-worktree.sh <path to vms/modules>"; exit 1; }
[ -d "$SRC/ec2" ] && [ -d "$SRC/fleet-guards" ] || {
  echo "refusing: $SRC does not hold both ec2/ and fleet-guards/"
  exit 1
}

files=$(scripts/placeholder-check.sh)
pc_rc=$?
[ "$pc_rc" -lt 2 ] || { echo "refusing: could not check for placeholders (rc=$pc_rc)"; exit 1; }
[ "$pc_rc" -eq 0 ] || { echo "refusing: no placeholder under vms/ — already pinned"; exit 1; }

for f in $files; do
  if ! python3 - "$f" "$SRC" <<'PY'
import re, sys
path, src = sys.argv[1], sys.argv[2]
s = open(path).read()
# [a-z0-9-]+, not [a-z-]+. The module directory is `ec2`, and a character
# class without digits skips it while matching `fleet-guards` — leaving one
# source pointed at a real remote with ref=worktree, which fails as
# "invalid ref" and reads like a network problem. Measured.
pattern = r'"git::[^"]*//vms/modules/([a-z0-9-]+)\?ref=__PLATFORM_SHA__" # __PLATFORM_TAG__'
s, n = re.subn(pattern, lambda m: '"%s/%s"' % (src, m.group(1)), s)
if n == 0 and '__PLATFORM_SHA__' in s:
    sys.exit("refusing: %s carries a pin placeholder in a source line this "
             "script does not recognise — rewriting the rest would leave a "
             "half-pinned tree" % path)
s = s.replace('__PLATFORM_TAG__', 'worktree').replace('__PLATFORM_SHA__', 'worktree')
open(path, 'w').write(s)
print('    %s: %d module source(s) redirected' % (path, n))
PY
  then
    echo "refusing: rewrite failed for $f — the tree may be half-pinned; do not use it."
    exit 1
  fi
  echo "  pointed $f at $SRC"
done

echo "✓ modules resolved from the working tree — this tree is not publishable"
