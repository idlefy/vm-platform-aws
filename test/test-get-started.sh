#!/usr/bin/env bash
# Gate for GET-STARTED.md, the guide an agent follows when someone has just
# cloned this repository.
#
# The guide creates a tenant repository and stops; the tenant's SETUP.md owns
# everything inside it. The one thing that must never regress is an executable
# command above the "Hard limits" heading that would deploy, push, promote or
# prepare — so this test splits the file there and rejects such a command
# inside a fenced code block above the split. Prose mentions ("no `make
# prepare`") are expected and allowed: the test is about the executable form,
# not the words.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GUIDE=GET-STARTED.md
pass=0; fail=0
check() {  # name, exit-status-of-condition
  if [ "$2" = 0 ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi
}

check "guide exists" "$([ -f "$GUIDE" ]; echo $?)"
check "starts with an H1, no frontmatter" "$(head -1 "$GUIDE" 2>/dev/null | grep -q '^# '; echo $?)"
check "has a Hard limits heading" "$(grep -q '^## Hard limits' "$GUIDE" 2>/dev/null; echo $?)"
check "AGENTS.md points at it" "$(grep -q 'GET-STARTED.md' AGENTS.md 2>/dev/null; echo $?)"
check "the old skill directory is gone" "$([ ! -e .claude/skills/get-started ]; echo $?)"

# Fenced code blocks above the heading, concatenated.
above_code=$(awk '
  /^## Hard limits/ { exit }
  /^```/            { infence = !infence; next }
  infence           { print }
' "$GUIDE" 2>/dev/null)
# No file ⇒ no evidence of safety: make every command check fail rather than pass vacuously.
[ -f "$GUIDE" ] || above_code='terraform apply make push make promote make prepare'

for cmd in 'terraform apply' 'make push' 'make promote' 'make prepare'; do
  check "no executable '$cmd' above Hard limits" "$(printf '%s\n' "$above_code" | grep -q -- "$cmd"; [ $? -ne 0 ]; echo $?)"
done

check "hands off to the tenant's SETUP.md" "$(grep -q 'SETUP.md' "$GUIDE" 2>/dev/null; echo $?)"
check "no longer names a tenant-setup skill" "$([ -f "$GUIDE" ] && ! grep -q 'tenant-setup' "$GUIDE"; echo $?)"
check "creates the repo private by default" "$(grep -q -- '--private' "$GUIDE" 2>/dev/null; echo $?)"
check "names the idlefy tag" "$(grep -q 'idlefy = "enabled"' "$GUIDE" 2>/dev/null; echo $?)"

echo; echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
