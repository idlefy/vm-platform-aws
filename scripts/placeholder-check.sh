#!/usr/bin/env bash
# The one spelling of "does this tree still carry placeholders?".
#
# Two surfaces, because two different things are unresolved at two different
# points in setup and only one of them is rewritable by a script:
#
#   --pins   (default)  vms/            __PLATFORM_TAG__ / __PLATFORM_SHA__
#   --config            cinc/policyfiles/*.rb   REPLACE_ME
#   --all               both
#
# --pins is the default and its output is a REWRITE LIST: resolve-pin.sh and
# pin-to-worktree.sh sed every file it names. Never widen the default — a
# policyfile in that list would be handed to a substitution that cannot fix it.
#
# --config exists because the policyfile's REPLACE_ME values are not all caught
# downstream. base::alloy refuses an empty or REPLACE_ME loki url/username at
# converge, but base::traefik interpolates acme_email and domain_root unguarded:
# a tenant that leaves them converges green, registers REPLACE_ME with Let's
# Encrypt and composes a Host rule of <vm>.ec2.<region>.REPLACE_ME that no
# certificate is ever issued for.
#
# Exit contract — three states, and the third is the point:
#   0  placeholders found; the file list is on stdout
#   1  none found — this tree is resolved
#   2  could not check (the directory a mode needs is absent, or grep failed)
# Callers MUST treat >=2 as a loud failure, never as "resolved".
#
# grep -r with --exclude-dir, NOT `git grep` and NOT a bare `grep -r vms/`:
#   - a bare -r reads vms/.terraform/modules/, which after `terraform init`
#     holds this whole repository, unresolved skeleton included — measured to
#     warn on every correctly pinned tenant;
#   - `git grep` searches tracked files only, so it misses untracked
#     placeholders in the copy/scaffold window and exits 128 outside a repo —
#     and the test fixtures and smoke's throwaway copy are not git repos.

set -uo pipefail

MODE=pins
case "${1:-}" in
  ""|--pins) ;;
  --config)  MODE=config ;;
  --all)     MODE=all ;;
  *) echo "placeholder-check: unknown option '$1' (--pins | --config | --all)" >&2
     exit 2 ;;
esac

cd "$(dirname "$0")/.." \
  || { echo "placeholder-check: cannot enter the repository root" >&2; exit 2; }

found=""
seen_any=0

if [ "$MODE" = pins ] || [ "$MODE" = all ]; then
  [ -d vms ] || { echo "placeholder-check: no vms/ directory here" >&2; exit 2; }
  files=$(grep -rl --exclude-dir=.terraform '__PLATFORM_\(TAG\|SHA\)__' vms/ 2>/dev/null)
  rc=$?
  case "$rc" in
    0) found="$found$files"$'\n'; seen_any=1 ;;
    1) ;;
    *) echo "placeholder-check: grep failed (rc=$rc) — cannot tell pinned from not" >&2
       exit 2 ;;
  esac
fi

if [ "$MODE" = config ] || [ "$MODE" = all ]; then
  # A glob, not `grep -r cinc/`: a tenant may hold more than one policyfile, and
  # nothing else under cinc/ is a template the operator is expected to fill in.
  [ -d cinc/policyfiles ] \
    || { echo "placeholder-check: no cinc/policyfiles/ directory here" >&2; exit 2; }
  set -- cinc/policyfiles/*.rb
  [ -e "$1" ] \
    || { echo "placeholder-check: cinc/policyfiles/ holds no .rb policyfile" >&2; exit 2; }
  files=$(grep -l 'REPLACE_ME' "$@" 2>/dev/null)
  rc=$?
  case "$rc" in
    0) found="$found$files"$'\n'; seen_any=1 ;;
    1) ;;
    *) echo "placeholder-check: grep failed (rc=$rc) — cannot tell filled in from not" >&2
       exit 2 ;;
  esac
fi

if [ "$seen_any" -eq 1 ]; then
  printf '%s' "$found" | sed '/^$/d'
  exit 0
fi
exit 1
