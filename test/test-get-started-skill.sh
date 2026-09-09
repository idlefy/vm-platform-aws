#!/usr/bin/env bash
# Gate for .claude/skills/get-started/SKILL.md.
#
# The skill creates a tenant repository and stops; tenant-setup owns everything
# inside it. The one thing that must never regress is an executable command
# above the "Hard limits" heading that would deploy, push, promote or prepare —
# so this test splits the file there and rejects such a command inside a fenced
# code block above the split. Prose mentions ("no `make prepare`") are expected
# and allowed: the test is about the executable form, not the words.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SKILL=.claude/skills/get-started/SKILL.md
pass=0; fail=0
check() {  # name, exit-status-of-condition
  if [ "$2" = 0 ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi
}

check "skill file exists" "$([ -f "$SKILL" ]; echo $?)"
check "frontmatter name is get-started" "$(sed -n '1,/^---$/p' "$SKILL" | sed 1d | grep -q '^name: get-started$'; echo $?)"
check "frontmatter has a description" "$(sed -n '2,/^---$/p' "$SKILL" | grep -q '^description: .\{20,\}'; echo $?)"
check "has a Hard limits heading" "$(grep -q '^## Hard limits' "$SKILL"; echo $?)"

# Fenced code blocks above the heading, concatenated.
above_code=$(awk '
  /^## Hard limits/ { exit }
  /^```/            { infence = !infence; next }
  infence           { print }
' "$SKILL" 2>/dev/null)
# No file ⇒ no evidence of safety: make every command check fail rather than pass vacuously.
[ -f "$SKILL" ] || above_code='terraform apply make push make promote make prepare ansible-playbook'

for cmd in 'terraform apply' 'make push' 'make promote' 'make prepare' 'ansible-playbook'; do
  check "no executable '$cmd' above Hard limits" "$(printf '%s\n' "$above_code" | grep -q -- "$cmd"; [ $? -ne 0 ]; echo $?)"
done

check "tells the user tenant-setup owns make prepare" "$(grep -q 'tenant-setup' "$SKILL"; echo $?)"
check "creates the repo private by default" "$(grep -q -- '--private' "$SKILL"; echo $?)"
check "names the idlefy tag" "$(grep -q 'idlefy = "enabled"' "$SKILL"; echo $?)"

echo; echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
