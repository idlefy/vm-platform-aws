#!/usr/bin/env bash
# Tests for `make boundary-check`.
#
# The guard protects the meaning of the published path, not the build. A `../`
# reference under vms/modules/ still RESOLVES for consumers — terraform init
# clones the whole repository and then uses the subdirectory — so there is no
# failure to observe and no consumer to complain. What it costs is that
# `//vms/modules/ec2?ref=<sha>` stops describing the artifact's real content.
#
# Every assertion below is therefore about detection, and the last two are about
# not over-detecting: a guard that fires on the comment in ec2/main.tf, or on a
# module's own `path.module`, gets switched off within a week.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() {
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi
}

setup() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/vms/modules/ec2" "$WORK/scripts"
  cp "$ROOT/scripts/boundary-check.sh" "$ROOT/scripts/strip-hcl-comments.py" "$WORK/scripts/"
  printf 'resource "null_resource" "a" {}\n' > "$WORK/vms/modules/ec2/main.tf"
}

teardown() { rm -rf "$WORK"; }

run_guard() { ( cd "$WORK" && ./scripts/boundary-check.sh 2>&1 ); }

echo "== a clean module tree passes =="
setup
OUT=$(run_guard)
check "exit 0" "$?"
check "says what it checked" "$(echo "$OUT" | grep -qi 'vms/modules' && echo 0 || echo 1)"
teardown

echo "== a relative escape is caught, and named =="
setup
printf 'locals { x = file("../../shared/thing.txt") }\n' >> "$WORK/vms/modules/ec2/main.tf"
OUT=$(run_guard)
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names the file" "$(echo "$OUT" | grep -q 'vms/modules/ec2/main.tf' && echo 0 || echo 1)"
check "names the line number" "$(echo "$OUT" | grep -qE 'main\.tf:[0-9]+' && echo 0 || echo 1)"
teardown

echo "== path.root and path.cwd are caught =="
setup
printf 'locals { y = "${path.root}/x" }\n' >> "$WORK/vms/modules/ec2/main.tf"
OUT=$(run_guard); check "path.root caught" "$([ $? -ne 0 ] && echo 0 || echo 1)"
teardown
setup
printf 'locals { z = "${path.cwd}/x" }\n' >> "$WORK/vms/modules/ec2/main.tf"
OUT=$(run_guard); check "path.cwd caught" "$([ $? -ne 0 ] && echo 0 || echo 1)"
teardown

echo "== comments and path.module do not trip it =="
# vms/modules/ec2/user_data.tf:52 already contains a `../` inside a comment,
# measured. A guard that fires on the tree as it stands is one nobody turns on.
setup
printf '# see ../../docs/design for why\n' >> "$WORK/vms/modules/ec2/main.tf"
printf '  #   ../ indented comment\n' >> "$WORK/vms/modules/ec2/main.tf"
OUT=$(run_guard); check "comment is ignored" "$([ $? -eq 0 ] && echo 0 || echo 1)"
teardown
setup
printf 'locals { t = "${path.module}/files/x" }\n' >> "$WORK/vms/modules/ec2/main.tf"
OUT=$(run_guard); check "path.module is allowed" "$([ $? -eq 0 ] && echo 0 || echo 1)"
teardown

echo "== a ../ inside a module URL is caught, not swallowed by the scheme =="
# The regression this file's stripper exists for. `sed -e 's,//.*,,'` reads the
# `//` in https:// as a comment delimiter, truncates the line at `https:`, and
# the escape after the module delimiter is never seen.
setup
printf 'module "x" {\n  source = "git::https://host/repo.git//vms/modules/../shared?ref=abc"\n}\n' >> "$WORK/vms/modules/ec2/main.tf"
OUT=$(run_guard)
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "names the source line" "$(echo "$OUT" | grep -q 'shared?ref=abc' && echo 0 || echo 1)"
teardown

echo "== a ../ inside a block comment does not trip it =="
# A false positive is how a guard gets switched off. HCL has /* */ and the
# stripper carries its state across lines.
setup
printf '/* the module used to live at ../shared\n   and ${path.root} was read here\n*/\n' >> "$WORK/vms/modules/ec2/main.tf"
OUT=$(run_guard); check "block comment ignored" "$([ $? -eq 0 ] && echo 0 || echo 1)"
teardown

echo "== a // comment is still a comment =="
setup
printf '// ../ in a slash comment\n' >> "$WORK/vms/modules/ec2/main.tf"
OUT=$(run_guard); check "slash comment ignored" "$([ $? -eq 0 ] && echo 0 || echo 1)"
teardown

echo "== a failing stripper fails the gate instead of skipping the file =="
# hits=$(stripper | grep) yields empty on a stripper crash, the file is
# silently skipped, and a `make release` gate prints its ✓ having scanned
# nothing — the same shape stage 2 of pin-check had.
setup
printf '#!/bin/sh\nexit 1\n' > "$WORK/scripts/strip-hcl-comments.py"
chmod +x "$WORK/scripts/strip-hcl-comments.py"
OUT=$(run_guard)
check "exit non-zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "says the check proved nothing" "$(echo "$OUT" | grep -qi 'proved nothing' && echo 0 || echo 1)"
check "does not print the success line" "$(echo "$OUT" | grep -q '✓ boundary-check' && echo 1 || echo 0)"
teardown

echo "== it runs against the real tree =="
check "the repository's own modules pass" "$( ( cd "$ROOT" && ./scripts/boundary-check.sh >/dev/null 2>&1 ) && echo 0 || echo 1)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
