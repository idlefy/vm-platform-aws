#!/usr/bin/env bash
# The skeleton ships copies of several scripts. This proves the copies have not
# drifted from the originals.
#
# It exists because they had. tenant-skeleton/scripts/resolve-pin.sh was copied
# in before a fix landed in scripts/resolve-pin.sh, and nothing noticed: both
# files are valid, both pass their own syntax check, and every test exercises
# only the upstream copy. A tenant generated from that skeleton would have got a
# resolver that leaves a half-pinned tree on a failed write — the exact defect
# the fix removed, delivered to the only people who cannot see the fix.
#
# The comparison is byte-identity, not "identical apart from comments". An
# earlier draft allowed comments to differ, because three copies pointed at
# the runbook upstream and at the agent guide in a tenant — and it immediately
# missed a fourth difference that sat in a `say` line rather than a comment. The
# pointers were reworded to be true in both trees instead, which removes the
# exemption and the class of bug it hides. If a copy ever needs a genuine
# difference it has stopped being a copy: give it its own name and drop it from
# SHIPPED.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

SHIPPED="resolve-pin.sh pin-check.sh preflight.sh add-region.sh placeholder-check.sh policy-publish.sh ami-build.sh"

check() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi
}

echo "== every shipped script is byte-identical to its original =="
for f in $SHIPPED; do
  a="$ROOT/scripts/$f"
  b="$ROOT/tenant-skeleton/scripts/$f"
  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    check "$f exists in both trees" "1"
    continue
  fi
  check "$f exists in both trees" "0"
  if diff -q "$a" "$b" >/dev/null; then
    check "$f has not drifted" "0"
  else
    check "$f has not drifted" "1"
    diff -u "$a" "$b" | head -20 | sed 's/^/      /'
  fi
done

echo "== agent guides: one AGENTS.md per tree, guides as plain root files =="
for tree in "$ROOT" "$ROOT/tenant-skeleton"; do
  rel=${tree#"$ROOT"}; rel=${rel#/}; rel=${rel:-.}
  check "$rel/AGENTS.md exists" "$([ -f "$tree/AGENTS.md" ]; echo $?)"
  check "$rel has no CLAUDE.md (it would shadow AGENTS.md)" "$([ ! -e "$tree/CLAUDE.md" ]; echo $?)"
  check "$rel has no .claude/skills" "$([ ! -e "$tree/.claude/skills" ]; echo $?)"
done
check "tenant-skeleton/SETUP.md exists" "$([ -f "$ROOT/tenant-skeleton/SETUP.md" ]; echo $?)"
check "the skeleton's AGENTS.md points at SETUP.md" \
  "$(grep -q 'SETUP.md' "$ROOT/tenant-skeleton/AGENTS.md" 2>/dev/null; echo $?)"
# Live files must not point at the old names. The design records and old
# changelog entries describe the tree as it was, and keep their wording.
stale=$(cd "$ROOT" && git grep -n -e 'CLAUDE\.md' -e '\.claude/skills' -e 'tenant-setup' -e 'get-started skill' -- \
  ':!docs/design/' ':!docs/changelog.md' ':!test/test-skeleton-sync.sh' ':!test/test-get-started.sh' 2>/dev/null)
check "no live file names CLAUDE.md, .claude/skills or the old skill names" "$([ -z "$stale" ]; echo $?)"
[ -z "$stale" ] || printf '%s\n' "$stale" | sed 's/^/      /'

echo "== the guard itself notices a drift =="
# Without this, a comparison that always succeeded would make every check above
# pass while proving nothing.
TMP=$(mktemp -d)
printf 'extra line\n' | cat "$ROOT/scripts/pin-check.sh" - > "$TMP/b"
check "an injected line is detected" \
  "$(diff -q "$ROOT/scripts/pin-check.sh" "$TMP/b" >/dev/null 2>&1 && echo 1 || echo 0)"
check "an unmodified copy is not" \
  "$(diff -q "$ROOT/scripts/pin-check.sh" "$ROOT/scripts/pin-check.sh" >/dev/null 2>&1 && echo 0 || echo 1)"
rm -rf "$TMP"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
