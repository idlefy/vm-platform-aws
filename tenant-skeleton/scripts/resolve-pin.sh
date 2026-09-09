#!/usr/bin/env bash
# Turn the skeleton's __PLATFORM_TAG__ / __PLATFORM_SHA__ placeholders into a
# real pin.
#
# The skeleton cannot ship its own pin: a commit cannot contain its own hash, so
# tenant-skeleton/ at tag vX.Y.Z cannot carry the SHA that tag names. Shipping
# the previous release's SHA would start every new tenant one version behind,
# silently — the same defect as the 0.1.0 cookbook pin this design removes.
#
# PEELING, and it is the opposite of the cookbook's. Terraform resolves
# ?ref=<tag> to the COMMIT, so the pin must be `refs/tags/<tag>^{}`, falling
# back to the plain ref for a lightweight tag which has no peeled form.
# scripts/pin-check.sh compares the COOKBOOK against the UNPEELED ref, because
# chef-cli records `git rev-parse <tag>` without peeling. Do not merge the two.
#
# Both forms turn up in practice: `make release` creates lightweight tags, and a
# maintainer signing a release by hand creates an annotated one. Nothing on the
# remote enforces either, so this script must accept both.
#
# Called by `make prepare PLATFORM_TAG=vX.Y.Z`.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "cannot enter the repository root ($ROOT)"; exit 1; }

TAG="${1:-}"
REMOTE="${PLATFORM_REMOTE:-https://github.com/idlefy/vm-platform-aws.git}"

[ -n "$TAG" ] || {
  echo "usage: resolve-pin.sh vX.Y.Z"
  exit 1
}

case "$TAG" in
  v*) ;;
  *)  echo "refusing: '$TAG' is not a v- tag. The Terraform stream is vX.Y.Z;"
      echo "          base-X.Y.Z publishes the cookbook and is pinned in the policyfile."
      exit 1 ;;
esac

# One predicate, one spelling: scripts/placeholder-check.sh. Its exit 2 means
# "could not check", which must refuse — not read as pinned or unpinned.
files=$(scripts/placeholder-check.sh)
pc_rc=$?
if [ "$pc_rc" -ge 2 ]; then
  echo "refusing: could not check vms/ for placeholders (placeholder-check exited $pc_rc)."
  echo "  Nothing has been written."
  exit 1
fi
if [ "$pc_rc" -ne 0 ]; then
  echo "refusing: no placeholder found under vms/ — this tree is already pinned."
  echo "  Resolving again would rewrite a pin that is in use. To move a pinned"
  echo "  tenant to a new release, edit local.platform_pin and both module"
  echo "  source lines together, then run 'make pin-check'."
  exit 1
fi

# ^{} first, plain ref second. An annotated tag has both; a lightweight tag has
# only the plain one, and awk on an empty result must not silently yield "".
sha=$(git ls-remote "$REMOTE" "refs/tags/$TAG^{}" 2>/dev/null | awk 'NR==1{print $1}')
[ -n "$sha" ] || sha=$(git ls-remote "$REMOTE" "refs/tags/$TAG" 2>/dev/null | awk 'NR==1{print $1}')

if [ -z "$sha" ]; then
  echo "refusing: tag $TAG does not resolve at $REMOTE"
  echo "  Either the tag does not exist, or the remote is unreachable"
  echo "  (network, SSH agent, repository access). Nothing has been written."
  exit 1
fi

case "$sha" in
  ????????????????????????????????????????) ;;
  *) echo "refusing: '$sha' is not a 40-character object name"; exit 1 ;;
esac

# Write to a staged copy first and move only after every file has been rewritten
# successfully. `sed -i` in a plain loop leaves the tree half-pinned when one
# write fails — earlier files already carry the new SHA while later ones still
# hold placeholders, and the script's own success line prints anyway. A
# half-pinned tree is worse than an unpinned one: `terraform init` resolves what
# it can and the failure surfaces as an unrelated-looking source error.
staged=""
for f in $files; do
  tmp="$f.resolve-pin.$$"
  if ! sed -e "s/__PLATFORM_SHA__/$sha/g" -e "s/__PLATFORM_TAG__/$TAG/g" "$f" > "$tmp"; then
    rm -f "$tmp"
    for t in $staged; do rm -f "${t%%:*}"; done
    echo "refusing: could not rewrite $f — nothing has been changed."
    exit 1
  fi
  if grep -q '__PLATFORM_' "$tmp"; then
    rm -f "$tmp"
    for t in $staged; do rm -f "${t%%:*}"; done
    echo "refusing: $f still carries a placeholder after substitution."
    echo "  A placeholder in a form this script does not recognise would leave the"
    echo "  tree half-pinned. Nothing has been changed."
    exit 1
  fi
  staged="$staged $tmp:$f"
done

# Three phases, and the split matters. Backing up inside the replacement loop
# looks equivalent and is not: a backup that fails on the second file leaves the
# first already replaced and nothing restores it. So every destination is backed
# up before any of them is touched, and a failure in that phase exits with the
# tree untouched.
backups=""
for pair in $staged; do
  dst=${pair#*:}
  if ! cp "$dst" "$dst.pin-backup.$$"; then
    echo "refusing: could not back up $dst — nothing has been changed."
    for b in $backups; do rm -f "$b"; done
    for t in $staged; do rm -f "${t%%:*}"; done
    exit 1
  fi
  backups="$backups $dst.pin-backup.$$"
done

done_files=""
for pair in $staged; do
  tmp=${pair%%:*}; dst=${pair#*:}
  if ! mv "$tmp" "$dst"; then
    echo "refusing: could not replace $dst — restoring the files already written."
    # A failed restore must not be followed by deleting the backup: that copy is
    # the only thing left that can recover the file. So restores are counted, and
    # the backups survive if any of them failed.
    stuck=""
    for d in $done_files; do
      mv "$d.pin-backup.$$" "$d" 2>/dev/null || stuck="$stuck $d"
    done
    for t in $staged; do rm -f "${t%%:*}"; done
    if [ -n "$stuck" ]; then
      echo ""
      echo "AND the restore failed for:$stuck"
      echo "  Their backups have been KEPT. Recover each by hand:"
      for d in $stuck; do echo "    mv '$d.pin-backup.$$' '$d'"; done
      echo "  Every other file is back to its committed content."
      exit 1
    fi
    for b in $backups; do rm -f "$b"; done
    exit 1
  fi
  done_files="$done_files $dst"
  echo "  pinned $dst"
done

for b in $backups; do rm -f "$b"; done

echo "✓ platform pin resolved: $TAG -> $sha"
echo "  Verify with: make pin-check"
