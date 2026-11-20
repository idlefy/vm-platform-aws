#!/usr/bin/env bash
# hardened-image-build.sh — build and publish Idlefy's hardened image for AI
# agents, idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN, from a platform
# tag. Run by the release workflow; not a tenant tool. Design:
# docs/design/ami-image.md.
#
#   PLATFORM_TAG=vX.Y.Z PLATFORM_SHA=<40 hex> HARDENED_SECURITY_GROUP_ID=sg-… \
#     scripts/hardened-image-build.sh
#
# Optional: HARDENED_PUBLIC (true|false, default true), HARDENED_ATTACHED_ORG_ID
# (a UUID), HARDENED_INSTANCE_TYPE (default c7a.xlarge), HARDENED_SUBNET_ID,
# HARDENED_OUT (default dist), GH_REPO (default idlefy/vm-platform-aws).
# HARDENED_SKIP_TAG_CHECK=1 is for the tests only.
#
# What it does, refusing at the first thing that is not so:
#   1. the tag names PLATFORM_SHA and the tree is that commit;
#   2. image/hardened/regions parses (the first region is the build region);
#   3. the committed solo lock is what solo.rb resolves to today;
#   4. the lock's base-X.Y.Z tag exists on GitHub;
#   5. the lock is exported as solo-<tag>.tgz and stored once as an asset of the
#      tag's release — a stored asset whose contents differ is never used;
#   6. the user data pins that asset's sha256 (law A1: the build instance has no
#      instance profile and fetches nothing else of Idlefy's);
#   7. Packer builds and copies the AMI to every region;
#   8. the release record hardened-ami-YYYYMMDD-NN.json, naming every region,
#      is uploaded to the release and its table appended to the release notes.
#
# Talks to GitHub (gh) and AWS (EC2 through Packer, plus one DescribeImages).
# Credentials come from the environment; nothing here prints one.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="$ROOT/image/hardened"
FILES="$ROOT/image/files"
POLICYFILE="$ROOT/cinc/policyfiles/solo.rb"
LOCKFILE="$ROOT/cinc/policyfiles/solo.lock.json"
OWNER_ID=995603458290
VOLUME_GIB=20
NAME_PREFIX=idlefy-hardened-agent-ubuntu-24.04-amd64

die() { echo "✗ hardened-image-build: $*" >&2; exit 1; }

# ---- 1. inputs -----------------------------------------------------------------
for c in chef packer aws gh python3 gzip sha256sum git; do
  command -v "$c" >/dev/null || die "$c is not on PATH"
done
PLATFORM_TAG="${PLATFORM_TAG:-}"
PLATFORM_SHA="${PLATFORM_SHA:-}"
HARDENED_SECURITY_GROUP_ID="${HARDENED_SECURITY_GROUP_ID:-}"
HARDENED_PUBLIC="${HARDENED_PUBLIC:-true}"
HARDENED_ATTACHED_ORG_ID="${HARDENED_ATTACHED_ORG_ID:-}"
HARDENED_INSTANCE_TYPE="${HARDENED_INSTANCE_TYPE:-c7a.xlarge}"
HARDENED_SUBNET_ID="${HARDENED_SUBNET_ID:-}"
HARDENED_OUT="${HARDENED_OUT:-dist}"
GH_REPO="${GH_REPO:-idlefy/vm-platform-aws}"

[[ $PLATFORM_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "PLATFORM_TAG='$PLATFORM_TAG' is not a vX.Y.Z tag"
[[ $PLATFORM_SHA =~ ^[0-9a-f]{40}$ ]] || die "PLATFORM_SHA='$PLATFORM_SHA' is not a full commit SHA"
[[ $HARDENED_SECURITY_GROUP_ID =~ ^sg-[0-9a-f]+$ ]] \
  || die "HARDENED_SECURITY_GROUP_ID='$HARDENED_SECURITY_GROUP_ID' is not a security group id — set it to the build's fixed group"
[[ $HARDENED_PUBLIC =~ ^(true|false)$ ]] || die "HARDENED_PUBLIC='$HARDENED_PUBLIC' must be true or false"
[ -z "$HARDENED_ATTACHED_ORG_ID" ] \
  || [[ $HARDENED_ATTACHED_ORG_ID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || die "HARDENED_ATTACHED_ORG_ID='$HARDENED_ATTACHED_ORG_ID' is not a lowercase UUID"
[[ $HARDENED_INSTANCE_TYPE =~ ^[a-z0-9-]+\.[a-z0-9]+$ ]] || die "HARDENED_INSTANCE_TYPE='$HARDENED_INSTANCE_TYPE' is not an instance type"
[ -z "$HARDENED_SUBNET_ID" ] || [[ $HARDENED_SUBNET_ID =~ ^subnet-[0-9a-f]+$ ]] \
  || die "HARDENED_SUBNET_ID='$HARDENED_SUBNET_ID' is not a subnet id"
[[ $GH_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GH_REPO='$GH_REPO' is not owner/name"

# The record says which commit built the image; it must be the one checked out.
if [ -z "${HARDENED_SKIP_TAG_CHECK:-}" ]; then
  tagged="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$PLATFORM_TAG^{commit}" 2>/dev/null)" \
    || die "no tag $PLATFORM_TAG in this checkout — fetch tags, or check PLATFORM_TAG"
  [ "$tagged" = "$PLATFORM_SHA" ] || die "$PLATFORM_TAG names ${tagged:0:12}, PLATFORM_SHA is ${PLATFORM_SHA:0:12} — pass the tag's commit"
  [ "$(git -C "$ROOT" rev-parse HEAD)" = "$PLATFORM_SHA" ] \
    || die "the checkout is not PLATFORM_SHA ${PLATFORM_SHA:0:12} — check out $PLATFORM_TAG and retry"
fi

TMPS=()
# shellcheck disable=SC2317  # reached only through the traps below
cleanup() { [ ${#TMPS[@]} -eq 0 ] || rm -rf "${TMPS[@]}"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
# tmp VAR — a fresh 0600 file in VAR, removed on exit. Not $(…): a subshell
# would lose the registration.
tmp() { local f; f="$(mktemp)"; TMPS+=("$f"); printf -v "$1" '%s' "$f"; }
W="$(mktemp -d)"; TMPS+=("$W")

# ---- 2. regions ----------------------------------------------------------------
# '#' lines and blank lines are comments; every other line is exactly a region.
REGIONS_VARS="$(python3 -I - "$IMG/regions" <<'PY'
import json, re, shlex, sys
try:
    lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
except OSError as e:
    sys.exit("cannot read %s: %s" % (sys.argv[1], e.strerror))
regions = []
for n, line in enumerate(lines, 1):
    if line.strip() == "" or line.lstrip().startswith("#"):
        continue
    if not re.fullmatch(r"[a-z]{2}-[a-z]+-[0-9]", line):
        sys.exit("line %d is not a region: %r" % (n, line))
    if line in regions:
        sys.exit("line %d repeats %s" % (n, line))
    regions.append(line)
if not regions:
    sys.exit("it lists no region")
print("BUILD_REGION=%s" % shlex.quote(regions[0]))
print("REGIONS=%s" % shlex.quote(" ".join(regions)))
print("AMI_REGIONS=%s" % shlex.quote(json.dumps(regions, separators=(",", ":"))))
PY
)" || die "image/hardened/regions: see above — fix the file"
eval "$REGIONS_VARS"

# ---- 3. the lock is fresh --------------------------------------------------------
# `chef install` honours an existing lock, so resolve a copy that has none.
[ -f "$POLICYFILE" ] && [ -f "$LOCKFILE" ] || die "no cinc/policyfiles/solo.rb with its lock"
read -r LOCK_REV COOKBOOK_VERSION < <(python3 -I -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
r, v = d["revision_id"], d["cookbook_locks"]["base"]["version"]
assert d["name"] == "solo" and re.fullmatch(r"[0-9a-f]{64}", r) and re.fullmatch(r"\d+\.\d+\.\d+", v)
print(r, v)' "$LOCKFILE" 2>/dev/null) \
  || die "cannot read name, revision_id and cookbook_locks.base.version from cinc/policyfiles/solo.lock.json"
mkdir -p "$W/cinc/cookbooks" "$W/cinc/policyfiles"
cp -R "$ROOT/cinc/cookbooks/base" "$W/cinc/cookbooks/base"
cp "$POLICYFILE" "$W/cinc/policyfiles/solo.rb"
chef install "$W/cinc/policyfiles/solo.rb" > "$W/install.log" 2>&1 \
  || { tail -20 "$W/install.log" >&2; die "chef install of a copy of solo.rb failed"; }
FRESH_REV="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision_id"])' \
  "$W/cinc/policyfiles/solo.lock.json" 2>/dev/null)" || die "chef install wrote no readable lock"
[ "$FRESH_REV" = "$LOCK_REV" ] \
  || die "cinc/policyfiles/solo.lock.json is stale (${LOCK_REV:0:12}; solo.rb resolves to ${FRESH_REV:0:12}) — run 'cd cinc && make install', commit the lock, tag again"

# ---- 4. the cookbook tag ---------------------------------------------------------
BASE_TAG="base-$COOKBOOK_VERSION"
gh api "repos/$GH_REPO/git/ref/tags/$BASE_TAG" >/dev/null 2>&1 \
  || die "the lock says base $COOKBOOK_VERSION, but $GH_REPO has no tag $BASE_TAG — release it first (make release TAG=$BASE_TAG)"

# ---- 5. the archive --------------------------------------------------------------
ASSET="solo-$PLATFORM_TAG.tgz"
chef export "$POLICYFILE" "$W/export" --archive > "$W/export.log" 2>&1 \
  || { tail -20 "$W/export.log" >&2; die "chef export of cinc/policyfiles/solo.rb failed"; }
[ -f "$W/export/solo-$LOCK_REV.tgz" ] || die "chef export wrote no solo-$LOCK_REV.tgz"
cp "$W/export/solo-$LOCK_REV.tgz" "$W/$ASSET"

gh release view -R "$GH_REPO" "$PLATFORM_TAG" >/dev/null 2>&1 \
  || gh release create -R "$GH_REPO" "$PLATFORM_TAG" --verify-tag --title "$PLATFORM_TAG" --notes "" >/dev/null \
  || die "could not create the release $PLATFORM_TAG — is the tag pushed?"

# The same comparison as tree() in scripts/policy-publish.sh, duplicated: that
# script ships byte-identical to tenants and cannot grow a mode for this one.
# An export is not byte-reproducible (mtimes), so contents are compared — paths,
# types, file hashes and link targets — read with tarfile, never extracted.
same_tree() {
  python3 -I - "$1" "$2" <<'PY'
import hashlib, sys, tarfile
def tree(path):
    out = {}
    with tarfile.open(path, "r:gz") as t:
        for m in t:
            name = m.name.removeprefix("./").rstrip("/")
            if name in ("", "."):
                continue
            if name in out:
                sys.exit(f"duplicate member {name}")
            if m.isfile():
                out[name] = "f" + hashlib.sha256(t.extractfile(m).read()).hexdigest()
            elif m.isdir():
                out[name] = "d"
            elif m.issym():
                out[name] = "l" + m.linkname
            else:
                sys.exit(f"unexpected member type: {name}")
    return out
sys.exit(0 if tree(sys.argv[1]) == tree(sys.argv[2]) else 1)
PY
}
download() { gh release download -R "$GH_REPO" "$PLATFORM_TAG" --pattern "$ASSET" -O "$W/stored.tgz" >/dev/null 2>&1; }
if download; then
  same_tree "$W/stored.tgz" "$W/$ASSET" \
    || die "the release asset $ASSET of $PLATFORM_TAG does not match what cinc/policyfiles/solo.lock.json exports; someone other than this script wrote it — investigate, delete it, and rerun"
else
  rm -f "$W/stored.tgz"
  # No --clobber: if the asset exists after all, the upload fails, and nothing
  # here ever replaces a stored asset.
  gh release upload -R "$GH_REPO" "$PLATFORM_TAG" "$W/$ASSET" >/dev/null \
    || die "could not upload $ASSET to the release $PLATFORM_TAG"
  download || die "uploaded $ASSET but could not download it back"
  cmp -s "$W/stored.tgz" "$W/$ASSET" || die "the $ASSET downloaded back is not the one uploaded"
fi
ARCHIVE_SHA256="$(sha256sum "$W/stored.tgz" | cut -d' ' -f1)"
ARCHIVE_URL="https://github.com/$GH_REPO/releases/download/$PLATFORM_TAG/$ASSET"

# ---- 6. the name -----------------------------------------------------------------
# Deprecated and disabled images keep their names, so they are counted.
DATE="$(date -u +%Y%m%d)"
n="$(aws ec2 describe-images --region "$BUILD_REGION" --owners self --include-deprecated --include-disabled \
      --filters "Name=name,Values=$NAME_PREFIX-$DATE-*" --query 'length(Images)' --output text)" \
  || die "could not count today's images in $BUILD_REGION"
[[ $n =~ ^[0-9]+$ ]] || die "describe-images returned '$n', not a count"
[ "$n" -lt 99 ] || die "$n images are already named $NAME_PREFIX-$DATE-NN; NN has two digits — build tomorrow"
NN="$(printf %02d $((10#$n + 1)))"
AMI_NAME="$NAME_PREFIX-$DATE-$NN"

# ---- 7. the user data ------------------------------------------------------------
# bootstrap-solo with its placeholders rendered, then both scrub files written
# side by side (the scrub sources "$0-solo"), then the scrub as the last line.
for f in dev-vm-image-scrub dev-vm-image-scrub-solo; do
  ! grep -qx 'DEV_VM_IMAGE_SCRUB' "$FILES/$f" || die "image/files/$f contains its own heredoc terminator"
  [ "$(tail -c1 "$FILES/$f" | od -An -c | tr -d ' ')" = '\n' ] || die "image/files/$f does not end in a newline"
done
tmp UD_PLAIN; tmp UD
python3 -I - "$FILES/bootstrap-solo" "$ARCHIVE_URL" "$ARCHIVE_SHA256" "$UD_PLAIN" <<'PY' \
  || die "image/files/bootstrap-solo did not render — fix the placeholders it names"
import sys
src, url, sha, out = sys.argv[1:]
s = open(src, encoding="utf-8").read()
if not s.startswith("#!/bin/bash\n"):
    sys.exit("bootstrap-solo does not start with #!/bin/bash")
s = s.replace("__ARCHIVE_URL__", url).replace("__ARCHIVE_SHA256__", sha)
if not s.endswith("\n"):
    s += "\n"
open(out, "w", encoding="utf-8").write(s)
PY
{
  printf '\n# ---- image build: scrub and power off (appended by hardened-image-build.sh) ----\n'
  for f in dev-vm-image-scrub dev-vm-image-scrub-solo; do
    printf 'install -m 0755 -o root -g root /dev/null /usr/local/sbin/%s\n' "$f"
    printf "cat > /usr/local/sbin/%s <<'DEV_VM_IMAGE_SCRUB'\n" "$f"
    cat "$FILES/$f"
    printf 'DEV_VM_IMAGE_SCRUB\n'
  done
  # The scrub deletes /var/log/user-data.log while this shell holds it open;
  # its blocks would be freed untrimmed into the public snapshot.
  printf 'exec >/dev/console 2>&1\n'
  printf '/usr/local/sbin/dev-vm-image-scrub --profile solo %s\n' "$ARCHIVE_SHA256"
} >> "$UD_PLAIN"
left="$(grep -oE '__[A-Z_]+__' "$UD_PLAIN" | sort -u | tr '\n' ' ')" || true
[ -z "$left" ] || die "the user data still holds placeholders: $left— render them in this script"
gzip -9 -n < "$UD_PLAIN" > "$UD"
UD_SIZE="$(stat -c %s "$UD")"
[ "$UD_SIZE" -le 16384 ] || die "user data is $UD_SIZE bytes gzipped; EC2 takes 16384"

# ---- 8. build --------------------------------------------------------------------
echo "Building $AMI_NAME ($PLATFORM_TAG, $BASE_TAG, archive ${ARCHIVE_SHA256:0:12}, public=$HARDENED_PUBLIC) in $BUILD_REGION for: $REGIONS"
packer init "$IMG" >/dev/null || die "packer init failed"
tmp PKLOG
# -machine-readable: the artifact line is the only reliable source of the AMI
# ids. The ui lines are echoed as they come, so the operator sees progress.
packer build -machine-readable \
  -var "ami_name=$AMI_NAME" \
  -var "build_region=$BUILD_REGION" \
  -var "ami_regions=$AMI_REGIONS" \
  -var "user_data_file=$UD" \
  -var "instance_type=$HARDENED_INSTANCE_TYPE" \
  -var "subnet_id=$HARDENED_SUBNET_ID" \
  -var "security_group_id=$HARDENED_SECURITY_GROUP_ID" \
  -var "public=$HARDENED_PUBLIC" \
  -var "volume_size_gb=$VOLUME_GIB" \
  -var "platform_tag=$PLATFORM_TAG" \
  -var "platform_sha=$PLATFORM_SHA" \
  -var "base_tag=$BASE_TAG" \
  -var "archive_sha256=$ARCHIVE_SHA256" \
  -var "attached_org_id=$HARDENED_ATTACHED_ORG_ID" \
  "$IMG" \
  | tee "$PKLOG" \
  | awk -F, '$3 == "ui" { m = $5; for (i = 6; i <= NF; i++) m = m "," $i; gsub(/%!\(PACKER_COMMA\)/, ",", m); gsub(/\\n/, "\n", m); print m; fflush() }' \
  || die "packer build failed — no record is written; the instance's serial console holds the bootstrap log"

# ---- 9. the record ---------------------------------------------------------------
# "<region>:<ami>,<region>:<ami>", commas escaped as %!(PACKER_COMMA). Every
# region of the file, and no other, or no record at all.
ARTIFACT="$(awk -F, '$3 == "artifact" && $4 == "0" && $5 == "id" { print $6 }' "$PKLOG")"
mkdir -p "$HARDENED_OUT"
RECORD="$HARDENED_OUT/hardened-ami-$DATE-$NN.json"
tmp RECORD_TMP; tmp NOTES_ADD
python3 -I - "$ARTIFACT" "$RECORD_TMP" "$NOTES_ADD" "$REGIONS" "$AMI_NAME" "$OWNER_ID" "$HARDENED_PUBLIC" \
  "$VOLUME_GIB" "$PLATFORM_TAG" "$PLATFORM_SHA" "$BASE_TAG" "$ARCHIVE_SHA256" "$ARCHIVE_URL" "$ASSET" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$RECORD")" <<'PY' \
  || die "packer's artifact does not name exactly the regions of image/hardened/regions — no record is written"
import json, re, sys
(artifact, record, notes, regions, name, owner, public, volume, tag, sha, base_tag,
 archive_sha, archive_url, asset, built_at, record_name) = sys.argv[1:]
regions = regions.split()
amis = {}
for part in artifact.replace("%!(PACKER_COMMA)", ",").split(","):
    m = re.fullmatch(r"([a-z0-9-]+):(ami-[0-9a-f]{8,17})", part)
    if not m or m.group(1) in amis:
        sys.exit("unexpected artifact entry %r" % part)
    amis[m.group(1)] = m.group(2)
missing = [r for r in regions if r not in amis]
extra = sorted(set(amis) - set(regions))
if missing or extra:
    sys.exit("missing: %s; not in the file: %s" % (" ".join(missing) or "none", " ".join(extra) or "none"))
d = {
    "format": 1,
    "image": "ubuntu-24.04-hardened",
    "name": name,
    "owner_id": owner,
    "architecture": "x86_64",
    "public": public == "true",
    "root_volume_gib": int(volume),
    "login_user": "ubuntu",
    "platform_tag": tag,
    "platform_sha": sha,
    "base_tag": base_tag,
    "archive_sha256": archive_sha,
    "archive_url": archive_url,
    "built_at": built_at,
    "amis": amis,
}
open(record, "w", encoding="utf-8").write(json.dumps(d, sort_keys=True, indent=2) + "\n")
rows = "".join("| %s | %s |\n" % (r, amis[r]) for r in regions)
open(notes, "w", encoding="utf-8").write(
    "\n### Hardened image %s\n\n" % name
    + "- Owner %s, public: %s, %s, %d GiB root, login user %s\n"
      % (owner, public, d["architecture"], d["root_volume_gib"], d["login_user"])
    + "- Platform %s (%s), cookbook %s\n" % (tag, sha, base_tag)
    + "- Policy archive [%s](%s), sha256 %s\n" % (asset, archive_url, archive_sha)
    + "- Built %s; record %s\n\n" % (built_at, record_name)
    + "| region | ami |\n|---|---|\n" + rows)
PY
chmod 0644 "$RECORD_TMP"
mv "$RECORD_TMP" "$RECORD"
gh release upload -R "$GH_REPO" "$PLATFORM_TAG" "$RECORD" >/dev/null \
  || die "the AMIs exist but the record $RECORD was not uploaded — upload it to $PLATFORM_TAG by hand (gh release upload)"
tmp NOTES
gh release view -R "$GH_REPO" "$PLATFORM_TAG" --json body -q .body > "$NOTES" \
  && cat "$NOTES_ADD" >> "$NOTES" \
  && gh release edit -R "$GH_REPO" "$PLATFORM_TAG" --notes-file "$NOTES" >/dev/null \
  || { cat "$NOTES_ADD" >&2; die "the record is uploaded but the release notes were not updated — append the section above to $PLATFORM_TAG's notes by hand"; }

echo
for r in $REGIONS; do
  python3 -I -c 'import json,sys; print(sys.argv[2], json.load(open(sys.argv[1]))["amis"][sys.argv[2]])' "$RECORD" "$r"
done
echo
echo "Record: $RECORD (uploaded to $PLATFORM_TAG)"
