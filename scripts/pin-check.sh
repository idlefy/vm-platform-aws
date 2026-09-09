#!/usr/bin/env bash
# Verify that the committed lock still means what it says.
#
# Stage 1: has the pinned tag moved upstream?
# Stage 2: is the committed lock what this policyfile resolves to?
#
# They are separate because the fixes are opposite. A moved tag must NOT be
# re-locked — re-locking adopts content that changed under you, which is the
# thing tag immutability exists to prevent. A stale lock must be re-locked.
#
# Stage 2 resolves into an EMPTY directory, seeded with the policyfile only. If
# the lock were copied in first, a failed resolve would leave it exactly as
# seeded, the comparison would succeed, and the gate would report a pass having
# checked nothing.
#
# The comparison covers source_options as well as revision_id. revision_id is
# derived from cookbook CONTENT, so a tag change that does not alter the cookbook
# subtree leaves it identical — and the lock's recorded tag is what stage 1 reads.
#
# Stage 1 needs the network (git ls-remote) and stage 2 needs it too unless the
# resolve hits chef-cli's cache. There is no offline mode on purpose: a gate that
# passes without reaching the remote cannot tell a moved tag from an unreachable
# one. PIN_CHECK=skip is the documented offline path, and it says so loudly.
#
# Run via `make pin-check` from the repo root.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "cannot enter the repository root ($ROOT)"; exit 1; }

POLICYFILE="${POLICYFILE:-cinc/policyfiles/dev-vm.rb}"
LOCKFILE="${LOCKFILE:-cinc/policyfiles/dev-vm.lock.json}"

if [ "${PIN_CHECK:-}" = "skip" ]; then
  echo "⚠  skipping pin-check (PIN_CHECK=skip)"
  echo "   Nothing verifies that what you push is what the pin names."
  echo "   This exists for the documented offline-recovery path only."
  exit 0
fi

[ -f "$LOCKFILE" ] || {
  echo "no $LOCKFILE — run 'make bump-cookbook TAG=base-X.Y.Z'"
  exit 1
}

# ---- stage 1: the tag, at the remote ----------------------------------------
#
# Note the UNPEELED ref: chef-cli records `git rev-parse <tag>`, which for an
# annotated tag is the tag object's SHA, not the commit's. Comparing against
# refs/tags/<tag>^{} would false-alarm on every annotated tag.
read -r git_url tag locked_rev <<<"$(python3 - "$LOCKFILE" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))['cookbook_locks']['base']['source_options']
print(o.get('git', ''), o.get('tag', ''), o.get('revision', ''))
PY
)"

[ -n "$git_url" ] || {
  echo "the lock has no git source — is this policyfile still on a local path?"
  exit 1
}

remote_rev=$(git ls-remote "$git_url" "refs/tags/$tag" 2>/dev/null | awk '{print $1}')
if [ -z "$remote_rev" ]; then
  echo "could not resolve tag $tag at $git_url"
  echo "  Either the remote is unreachable (network, SSH agent, access) or the tag was deleted."
  echo "  A deleted tag can leave the pinned commit unreachable; 'When upstream is"
  echo "  unreachable' in CLAUDE.md is the way out."
  exit 1
fi

if [ "$remote_rev" != "$locked_rev" ]; then
  echo "the tag moved upstream — do NOT bump"
  echo "  $tag now names   $remote_rev"
  echo "  your lock records $locked_rev"
  echo "  Establish what changed before adopting it. Tags are supposed to be immutable;"
  echo "  a re-created tag at the same commit also does this and is harmless, but you"
  echo "  cannot tell the two apart from here."
  exit 1
fi
echo "  ok   tag $tag still names $locked_rev"

# ---- stage 2: the lock, against the policyfile -------------------------------
# chef-cli materialises a git-sourced cookbook with `git filter-branch`, which
# sleeps 10 seconds printing a deprecation warning unless this is set. Measured
# 2026-09-05: 10.9s -> 0.9s per resolve. The sleep is the whole cost of stage 2.
export FILTER_BRANCH_SQUELCH_WARNING=1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$POLICYFILE" "$tmp/"
if ! ( cd "$tmp" && chef update "$(basename "$POLICYFILE")" >/dev/null 2>&1 ); then
  echo "could not resolve the policyfile"
  echo "  The resolve itself failed, so nothing was verified. This is not a pass."
  exit 1
fi

fresh="$tmp/$(basename "$LOCKFILE")"
[ -f "$fresh" ] || {
  echo "could not resolve the policyfile (no lock produced)"
  exit 1
}

diff=$(python3 - "$LOCKFILE" "$fresh" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
out = []
if a['revision_id'] != b['revision_id']:
    out.append('revision_id')
ao = a['cookbook_locks']['base']['source_options']
bo = b['cookbook_locks']['base']['source_options']
# Every key, not just tag and revision. `rel` and a changed `git` remote both
# survive a tag+revision comparison — a mirror of the same repository resolves
# the same tag to the same SHA, so the policyfile can name one remote while the
# lock keeps installing from another, and this gate would pass.
for k in sorted(set(ao) | set(bo)):
    if ao.get(k) != bo.get(k):
        out.append('source_options.' + k)
print(','.join(out))
PY
)
rc=$?

# A comparison that crashed produced an empty $diff, which reads as "no
# drift". Same shape as the resolve failure above, same rule: a gate that
# could not check must refuse.
if [ "$rc" -ne 0 ]; then
  echo "could not compare the lock against the fresh resolve (python exited $rc)"
  echo "  The comparison itself failed, so nothing was verified. This is not a pass."
  exit 1
fi

if [ -n "$diff" ]; then
  echo "policyfile has changes not in the lock ($diff)"
  echo "  chef install honours the lock, so 'make push' would upload the PREVIOUS content."
  echo "  Run: make bump-cookbook   (omit TAG to re-lock at the current pin)"
  exit 1
fi
echo "  ok   lock matches the policyfile"

# ---- stage 3: the Terraform pins --------------------------------------------
#
# Two things, and neither is a moved-tag check. A moved tag CANNOT affect a
# SHA-pinned consumer — the content is address-addressed, so there is nothing to
# detect, which is exactly why Terraform pins by SHA and the cookbook does not.
#
#   1. Internal consistency. A module `source` is a literal; Terraform will not
#      interpolate local.platform_pin.sha into it, so nothing stops two module
#      calls resolving at different commits. That plans cleanly and means the
#      fleet guards are computed by one revision of the platform while the VMs
#      are built by another.
#   2. Documentation consistency, doubling as reachability. The recorded tag
#      must still name the pinned commit. A mismatch means the comment lies; a
#      tag that has vanished means the commit may no longer be reachable from
#      any ref, which is the one way a SHA pin stops working.
#
# PEELING: refs/tags/<tag>^{} first, plain ref as fallback — Terraform resolves
# ?ref= to the commit. Stage 1 above compares the COOKBOOK against the UNPEELED
# ref, because chef-cli records `git rev-parse <tag>` without peeling. Same file,
# opposite rules; do not factor them together.

# `-f vms/main.tf`, not `-d vms`. The platform repo keeps vms/modules/ and a README
# but no root, so a directory test is true there and the check then reports a
# template checkout as a tenant that never migrated.
if [ -f vms/main.tf ]; then
  pin_tag=$(sed -n 's/^[[:space:]]*tag[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' vms/main.tf | head -1)
  pin_sha=$(sed -n 's/^[[:space:]]*sha[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' vms/main.tf | head -1)

  if [ -z "$pin_tag" ] || [ -z "$pin_sha" ]; then
    echo "vms/main.tf has no local.platform_pin — is this tenant still on a local module path?"
    exit 1
  fi

  case "$pin_sha" in
    __PLATFORM_SHA__)
      echo "vms/ still carries pin placeholders — run 'make prepare PLATFORM_TAG=vX.Y.Z'"
      exit 1 ;;
  esac

  bad=0
  seen=0
  while IFS= read -r line; do
    seen=$((seen + 1))
    ref=${line##*\?ref=}
    ref=${ref%%\"*}
    [ "$ref" = "$pin_sha" ] && continue
    echo "  ✗ $line"
    bad=1
  # -H, not just -n. grep prints the filename only when it is given more than
  # one file, and a tenant has exactly one vms/main.tf — so the offending line
  # would be reported as "8:  source = …" with nothing saying which file.
  # Only real assignments feed the loop. A bare 'ref=' grep also matches the
  # '# was: source = …' comments the offline-recovery path keeps, in both
  # directions: the commented copies counted as live sources (seen=2 on a tree
  # with zero git pins), and a commented OLD source hard-failed a correct bump.
  done < <(grep -Hn '^[[:space:]]*source[[:space:]]*=' vms/*.tf | grep 'git::')

  # Zero matches is a failure, not a pass. grep prints nothing when no file
  # carries a git:: source, the loop body never runs, and without this the next
  # line would report "every module source names <sha>" having checked none —
  # which is exactly what a tenant that reverted to local module paths would see.
  if [ "$seen" -eq 0 ]; then
    echo "no git:: module source under vms/*.tf, but local.platform_pin names $pin_tag"
    echo "  Either this tenant was switched back to local module paths, or the"
    echo "  sources were rewritten into a form this check does not recognise."
    echo "  Both mean the pin above describes something nothing consumes."
    exit 1
  fi

  if [ "$bad" -ne 0 ]; then
    echo "module sources disagree with local.platform_pin.sha ($pin_sha)"
    echo "  A module source is a literal — Terraform will not interpolate the pin into it,"
    echo "  so nothing but this check keeps them together. Two calls at different commits"
    echo "  plan cleanly and build the fleet from two revisions of the platform."
    exit 1
  fi
  echo "  ok   every module source names $pin_sha"

  # Any scheme, not just ssh://. Measured: an ssh-anchored pattern returns
  # nothing for a file:// or https:// source, the fallback remote below then
  # fires, ls-remote queries the wrong repository and the check reports the
  # tag as deleted — a hard failure on a correct tree.
  # Anchored to a real assignment for the same reason as the loop feed above:
  # an unanchored '.*"git::' also matches a '# was: source = …' comment, and
  # when that comment sits before the live source in the file, head -1 picks
  # the retired remote instead — turning a correct post-bump tree red.
  remote=$(sed -n 's|^[[:space:]]*source[[:space:]]*=[[:space:]]*"git::\([^"]*\)//vms/modules/.*|\1|p' vms/main.tf | head -1)
  if [ -z "$remote" ]; then
    echo "could not read the module remote out of vms/main.tf"
    echo "  Expected a source of the form git::<url>//vms/modules/<name>?ref=<sha>."
    exit 1
  fi

  tag_sha=$(git ls-remote "$remote" "refs/tags/$pin_tag^{}" 2>/dev/null | awk 'NR==1{print $1}')
  [ -n "$tag_sha" ] || tag_sha=$(git ls-remote "$remote" "refs/tags/$pin_tag" 2>/dev/null | awk 'NR==1{print $1}')

  if [ -z "$tag_sha" ]; then
    echo "tag $pin_tag no longer exists at $remote — reachability risk"
    echo "  Your pin still names $pin_sha and is unaffected while that commit survives."
    echo "  But a commit reachable from no ref can be garbage-collected upstream, and"
    echo "  then a cold 'terraform init' cannot resolve it. Restore the tag, or move to"
    echo "  a published release."
    exit 1
  fi

  if [ "$tag_sha" != "$pin_sha" ]; then
    echo "tag $pin_tag no longer names your pinned commit"
    echo "  $pin_tag now names   $tag_sha"
    echo "  your pin records     $pin_sha"
    echo "  Your build is unaffected — a SHA pin cannot be moved out from under you."
    echo "  What is wrong is the record: the tag in local.platform_pin and in every"
    echo "  source comment no longer describes what you run."
    exit 1
  fi
  echo "  ok   tag $pin_tag still names $pin_sha"
else
  # No vms/main.tf. On the platform checkout that is normal — vms/ holds only
  # modules/ and a README, and there are no top-level .tf files. But a tenant
  # that renamed or split its root would otherwise lose every check in this
  # stage forever, silently. Tenant-shaped content anywhere else in vms/*.tf
  # is therefore a refusal, not a skip.
  stray=$(grep -l 'git::\|platform_pin' vms/*.tf 2>/dev/null | head -1)
  if [ -n "$stray" ]; then
    echo "no vms/main.tf, but $stray carries a module source or platform_pin"
    echo "  Stage 3 reads the pin out of vms/main.tf and cannot find it. If the root"
    echo "  was renamed or split, move local.platform_pin and both module sources back"
    echo "  into vms/main.tf — otherwise every Terraform-pin check is silently skipped."
    exit 1
  fi
fi

echo "✓ pin-check passed"
