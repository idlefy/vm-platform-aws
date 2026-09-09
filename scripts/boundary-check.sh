#!/usr/bin/env bash
# Refuse a published module that reaches outside its own directory.
#
# This is boundary hygiene, NOT a build check, and the distinction matters
# because the obvious justification is wrong. Measured: `terraform init` clones
# the WHOLE repository into .terraform/modules/<call> and then uses the
# subdirectory, so a `../` reference under vms/modules/ resolves for every
# consumer exactly as it does here. Nothing breaks. Nobody is paged.
#
# What breaks is the meaning of the pin. A tenant writes
# `//vms/modules/ec2?ref=<sha>` and reviews that directory; if its content
# depends on files above it, the review saw a subset of the artifact — and any
# future vendoring, extraction or reorganisation silently changes behaviour.
#
# So: do not "test the failure mode" by introducing a ../ and expecting an
# error. There isn't one. That is the whole reason this script exists.
#
# Run via `make boundary-check`.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "cannot enter the repository root ($ROOT)"; exit 1; }

TARGET="vms/modules"
[ -d "$TARGET" ] || { echo "no $TARGET — nothing to check"; exit 1; }

# path.module is fine: it names the module's own directory. path.root and
# path.cwd name the CALLER's, which a published module must never assume.
PATTERN='(\.\./|path\.root|path\.cwd)'

found=0
while IFS= read -r f; do
  # Comments are stripped before matching, or the guard fires on the `../`
  # already sitting inside a comment at vms/modules/ec2/user_data.tf:52 — on a
  # clean tree, on day one. The stripper is quote-aware and lives in its own
  # file; `sed -e 's,//.*,,'` reads the `//` in a URL as a comment and truncates
  # a source at `https:`, hiding the very escape this script looks for.
  stripped=$("$ROOT/scripts/strip-hcl-comments.py" "$f")
  if [ $? -ne 0 ]; then
    echo "  ✗ $f: strip-hcl-comments failed"
    echo "refusing: the stripper failed on $f, so this check proved nothing for it."
    exit 1
  fi
  hits=$(printf '%s\n' "$stripped" | grep -E ":.*$PATTERN")
  if [ -n "$hits" ]; then
    found=1
    while IFS= read -r h; do
      echo "  ✗ $f:$h"
    done <<<"$hits"
  fi
done < <(find "$TARGET" -name '*.tf' -type f | sort)

if [ "$found" -ne 0 ]; then
  echo ""
  echo "refusing: a module under $TARGET reaches outside its own directory."
  echo "  Consumers pin '//$TARGET/<name>?ref=<sha>' and review that directory."
  echo "  A reference above it means the pin does not describe the artifact."
  echo "  path.module is allowed; path.root and path.cwd name the caller's tree."
  exit 1
fi

echo "✓ boundary-check: every .tf under $TARGET stays inside its own directory"
