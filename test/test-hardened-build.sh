#!/usr/bin/env bash
# scripts/hardened-image-build.sh against shimmed chef/gh/aws/packer. Nothing
# here touches AWS or GitHub and nothing runs a real `packer build`.
#
# Each scenario runs the driver in a throwaway tree holding the REAL
# image/hardened/ and image/files/, a solo policyfile with a fixture lock, and
# a stub base cookbook. The shims log every call:
#   chef    install writes a lock with revision ${CHEF_INSTALL_REV:-the lock's}
#           next to the policyfile it is given; export --archive writes
#           <dir>/solo-<lock revision>.tgz from $EXPORT_TREE.
#   gh      release view fails while ${GH_RELEASE_MISSING} and nothing created
#           it; download returns $GH_STORED, else what was uploaded, else fails;
#           api …/git/ref/tags/<tag> fails when ${GH_BASE_TAG_MISSING}.
#   aws     describe-images … length(Images) prints ${EXISTING_TODAY:-0}.
#   packer  build copies the user data and reports an AMI for each region in
#           ${ARTIFACT_REGIONS:-every region of ami_regions}; exits ${PACKER_RC:-0}.
# The last section measures the real solo user data against EC2's 16 KB.

# The checks read `[ … ]; echo $?` and `run_build; check … "$?"` on purpose: the
# status of that condition, or of that run, is the thing being checked.
# shellcheck disable=SC2181,SC2319

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/r"
mkdir -p "$T/bin" "$T/state" "$R/scripts" "$R/image" "$R/cinc/policyfiles" "$R/cinc/cookbooks/base"
cp "$ROOT/scripts/hardened-image-build.sh" "$R/scripts/" 2>/dev/null
cp -R "$ROOT/image/hardened" "$ROOT/image/files" "$R/image/"
cp "$ROOT/cinc/policyfiles/solo.rb" "$R/cinc/policyfiles/solo.rb"
printf "name 'base'\nversion '2.1.0'\n" > "$R/cinc/cookbooks/base/metadata.rb"

REV=$(printf 'rev' | sha256sum | cut -d' ' -f1)
OTHERREV=$(printf 'other' | sha256sum | cut -d' ' -f1)
SHA=$(printf 'c%.0s' {1..40})
DATE=$(date -u +%Y%m%d)
SG=sg-0f0f0f0f0f0f0f0f0
URL=https://github.com/idlefy/vm-platform-aws/releases/download/v2.2.0/solo-v2.2.0.tgz
printf '{"name":"solo","revision_id":"%s","cookbook_locks":{"base":{"version":"2.1.0"}}}' "$REV" \
  > "$R/cinc/policyfiles/solo.lock.json"
mapfile -t REGIONS < <(grep -v '^[[:space:]]*\(#\|$\)' "$ROOT/image/hardened/regions")
REGIONS_JSON=$(printf '%s\n' "${REGIONS[@]}" | python3 -I -c 'import json,sys; print(json.dumps(sys.stdin.read().split(), separators=(",", ":")))')

# Two export trees: the same contents written twice (other mtimes, other
# bytes), and other contents.
mktree() { mkdir -p "$1/cookbook_artifacts/base-x"; printf '{"name":"solo"}' > "$1/Policyfile.lock.json"; printf '%s' "$2" > "$1/cookbook_artifacts/base-x/recipe.rb"; }
mktree "$T/tree-a" "converge"; mktree "$T/tree-b" "something else"
tar -C "$T/tree-a" -czf "$T/same.tgz" --mtime='2001-01-01 00:00:00Z' .
tar -C "$T/tree-b" -czf "$T/other.tgz" .

cat > "$T/bin/chef" <<'SH'
#!/usr/bin/env bash
echo "chef $*" >> "$CHEF_LOG"
lockof() { printf '%s' "${1%.rb}.lock.json"; }
case "$1" in
  install)
    printf '{"name":"solo","revision_id":"%s","cookbook_locks":{"base":{"version":"2.1.0"}}}' \
      "${CHEF_INSTALL_REV:-$REV}" > "$(lockof "$2")" ;;
  export)
    [ "${4:-}" = --archive ] || exit 9
    rev=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision_id"])' "$(lockof "$2")")
    mkdir -p "$3" && tar -C "$EXPORT_TREE" -czf "$3/solo-$rev.tgz" . ;;
  *) exit 9 ;;
esac
SH
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
# Logged without -R, which goes to its own log, one line per call.
a=(); repo=none
while [ $# -gt 0 ]; do if [ "$1" = -R ]; then repo=$2; shift 2; else a+=("$1"); shift; fi; done
set -- "${a[@]}"
echo "gh $*" >> "$GH_LOG"
case "$1" in api) echo "${2%%/git/*}" ;; *) echo "$repo" ;; esac >> "$GH_LOG.repo"
case "$1 ${2:-}" in
  "release view")
    if [ -n "${GH_RELEASE_MISSING:-}" ] && [ ! -e "$GH_STATE/created" ]; then exit 1; fi
    case " $* " in *" --json body "*) printf 'Existing notes.\n' ;; esac ;;
  "release create") : > "$GH_STATE/created" ;;
  "release upload") cp "$4" "$GH_STATE/" ;;
  "release download")
    pat="" out=""
    while [ $# -gt 0 ]; do case "$1" in --pattern) pat=$2; shift ;; -O) out=$2; shift ;; esac; shift; done
    if [ -n "${GH_STORED:-}" ]; then cp "$GH_STORED" "$out"
    elif [ -f "$GH_STATE/$pat" ]; then cp "$GH_STATE/$pat" "$out"
    else exit 1; fi ;;
  "release edit")
    while [ $# -gt 0 ]; do [ "$1" = --notes-file ] && cp "$2" "$GH_STATE/notes"; shift; done ;;
  api\ repos/*/git/ref/tags/*) [ -z "${GH_BASE_TAG_MISSING:-}" ] || exit 1; echo '{"ref":"x"}' ;;
  *) exit 9 ;;
esac
SH
cat > "$T/bin/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$AWS_LOG"
[ "$1 $2" = "ec2 describe-images" ] || exit 9
echo "${EXISTING_TODAY:-0}"
SH
cat > "$T/bin/packer" <<'SH'
#!/usr/bin/env bash
echo "packer $1" >> "$ORDER_LOG"
if [ "$1" = init ]; then echo "init $2" >> "$PACKER_LOG"; exit 0; fi
printf '%s\n' "$@" >> "$PACKER_LOG"
regions=""
for a in "$@"; do
  case "$a" in
    user_data_file=*) cp "${a#user_data_file=}" "$UD_COPY" ;;
    ami_regions=*) regions=$(python3 -I -c 'import json,sys; print(" ".join(json.loads(sys.argv[1])))' "${a#ami_regions=}") ;;
  esac
done
echo '1697000000,,ui,say,==> amazon-ebs.hardened: Waiting for the instance to power off...'
ids=""; i=0
for r in ${ARTIFACT_REGIONS:-$regions}; do
  i=$((i+1)); ids="$ids${ids:+%!(PACKER_COMMA)}$r:ami-0$(printf '%016x' "$i")"
done
echo "1697000001,amazon-ebs.hardened,artifact,0,id,$ids"
exit "${PACKER_RC:-0}"
SH
chmod +x "$T/bin/"*

# run_build — runs the driver with the shims; returns its status.
run_build() {
  rm -rf "$T/state" "$T/out" "$T/ud.gz"; mkdir -p "$T/state"
  : > "$T/chef.log"; : > "$T/gh.log"; : > "$T/gh.log.repo"; : > "$T/aws.log"; : > "$T/packer.log"; : > "$T/order.log"
  local e=(PATH="$T/bin:$PATH" CHEF_LOG="$T/chef.log" GH_LOG="$T/gh.log" AWS_LOG="$T/aws.log"
           PACKER_LOG="$T/packer.log" ORDER_LOG="$T/order.log" UD_COPY="$T/ud.gz" GH_STATE="$T/state"
           EXPORT_TREE="${EXPORT_TREE:-$T/tree-a}" REV="$REV"
           PLATFORM_TAG="${PLATFORM_TAG-v2.2.0}" PLATFORM_SHA="${PLATFORM_SHA-$SHA}"
           HARDENED_SKIP_TAG_CHECK="${SKIP_TAG-1}" HARDENED_OUT="$T/out")
  [ -n "${NO_SG:-}" ] || e+=(HARDENED_SECURITY_GROUP_ID="$SG")
  [ -z "${PUBLIC:-}" ] || e+=(HARDENED_PUBLIC="$PUBLIC")
  [ -z "${ORG:-}" ] || e+=(HARDENED_ATTACHED_ORG_ID="$ORG")
  ( cd "$T" && env -u HARDENED_SECURITY_GROUP_ID -u HARDENED_PUBLIC -u HARDENED_ATTACHED_ORG_ID \
      -u HARDENED_SUBNET_ID -u HARDENED_INSTANCE_TYPE -u GH_REPO "${e[@]}" \
      "$R/scripts/hardened-image-build.sh" > "$T/stdout" 2> "$T/stderr" )
  local rc=$?
  # Decompressed once: `zcat | grep -q` fails under pipefail when grep exits early.
  rm -f "$T/ud"; [ ! -f "$T/ud.gz" ] || zcat "$T/ud.gz" > "$T/ud"
  return "$rc"
}
var() { grep -qxF "$1" "$T/packer.log"; }
ud() { cat "$T/ud"; }
# embedded FILE — the body of the heredoc that writes /usr/local/sbin/FILE.
embedded() { ud | sed -n "/^cat > \/usr\/local\/sbin\/$1 <<'DEV_VM_IMAGE_SCRUB'\$/,/^DEV_VM_IMAGE_SCRUB\$/p" | sed '1d;$d'; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
RECORD="$T/out/hardened-ami-$DATE-01.json"

echo "== a fresh tag builds and publishes =="
GH_RELEASE_MISSING=1 run_build; check "exits 0" "$?"
check "chef install ran on a COPY of the policyfile" \
  "$(grep -q '^chef install .*/cinc/policyfiles/solo.rb$' "$T/chef.log" && ! grep -q "^chef install $R/" "$T/chef.log"; echo $?)"
check "chef export ran on the committed cinc/policyfiles/solo.rb" \
  "$(grep -q "^chef export $R/cinc/policyfiles/solo.rb .* --archive$" "$T/chef.log"; echo $?)"
check "the missing release was created on the existing tag" \
  "$(grep -q '^gh .*release create v2.2.0 --verify-tag ' "$T/gh.log"; echo $?)"
check "the archive was uploaded, then downloaded back" \
  "$(grep -n 'release upload v2.2.0 .*/solo-v2.2.0.tgz$' "$T/gh.log" | head -1 | cut -d: -f1 > "$T/n1"; \
     grep -n 'release download v2.2.0 .*solo-v2.2.0.tgz' "$T/gh.log" | tail -1 | cut -d: -f1 > "$T/n2"; \
     [ -s "$T/n1" ] && [ "$(cat "$T/n1")" -lt "$(cat "$T/n2")" ]; echo $?)"
check "every gh call names the repository" "$(! grep -vx 'idlefy/vm-platform-aws\|repos/idlefy/vm-platform-aws' "$T/gh.log.repo" | grep -q .; echo $?)"
check "packer init on image/hardened, then a machine-readable build" \
  "$(grep -qx "init $R/image/hardened" "$T/packer.log" && grep -qx -- '-machine-readable' "$T/packer.log" && [ "$(tr '\n' ' ' < "$T/order.log")" = "packer init packer build " ]; echo $?)"
check "ami_name is today's first" "$(var "ami_name=idlefy-hardened-agent-ubuntu-24.04-amd64-$DATE-01"; echo $?)"
check "build_region is the first region" "$(var build_region=us-east-1; echo $?)"
check "ami_regions is every region, in order" "$(var "ami_regions=$REGIONS_JSON"; echo $?)"
check "the regions file holds 17 regions" "$([ "${#REGIONS[@]}" = 17 ]; echo $?)"
check "instance_type defaults to c7a.xlarge" "$(var instance_type=c7a.xlarge; echo $?)"
check "the security group is passed" "$(var "security_group_id=$SG"; echo $?)"
check "public defaults to true" "$(var public=true; echo $?)"
check "volume is 20 GiB" "$(var volume_size_gb=20; echo $?)"
check "provenance vars" "$(var platform_tag=v2.2.0 && var "platform_sha=$SHA" && var base_tag=base-2.1.0; echo $?)"
STORED_SHA=$(sha_of "$T/state/solo-v2.2.0.tgz")
check "archive_sha256 is the stored asset's" "$(var "archive_sha256=$STORED_SHA"; echo $?)"
check "attached_org_id is empty when unset" "$(var attached_org_id=; echo $?)"
check "subnet_id is empty when unset" "$(var subnet_id=; echo $?)"
check "no profile: credentials come from the environment" "$(! grep -q '^aws_profile=' "$T/packer.log"; echo $?)"
check "user data is gzip within 16384 bytes" "$(gzip -t "$T/ud.gz" && [ "$(stat -c %s "$T/ud.gz")" -le 16384 ]; echo $?)"
check "user data starts #!/bin/bash" "$([ "$(ud | head -1)" = '#!/bin/bash' ]; echo $?)"
check "the archive's sha256 and URL are rendered in" \
  "$(grep -qxF "ARCHIVE_SHA256='$STORED_SHA'" "$T/ud" && grep -qxF "ARCHIVE_URL='$URL'" "$T/ud"; echo $?)"
check "no placeholder survives" "$(! grep -qE '__[A-Z_]+__' "$T/ud"; echo $?)"
check "the embedded scrub is image/files/dev-vm-image-scrub, byte for byte" \
  "$(embedded dev-vm-image-scrub | cmp -s - "$ROOT/image/files/dev-vm-image-scrub"; echo $?)"
check "the embedded solo hooks are image/files/dev-vm-image-scrub-solo, byte for byte" \
  "$(embedded dev-vm-image-scrub-solo | cmp -s - "$ROOT/image/files/dev-vm-image-scrub-solo"; echo $?)"
check "both are installed 0755 root:root before they are written" \
  "$(grep -qxF 'install -m 0755 -o root -g root /dev/null /usr/local/sbin/dev-vm-image-scrub' "$T/ud" \
     && grep -qxF 'install -m 0755 -o root -g root /dev/null /usr/local/sbin/dev-vm-image-scrub-solo' "$T/ud"; echo $?)"
L_FILES=$(ud | grep -nx 'DEV_VM_IMAGE_SCRUB' | tail -1 | cut -d: -f1)
L_EXEC=$(ud | grep -nxF 'exec >/dev/console 2>&1' | cut -d: -f1)
L_LAST=$(ud | wc -l)
check "output leaves the log file after both files and before the scrub" \
  "$([ -n "$L_EXEC" ] && [ -n "$L_FILES" ] && [ "$L_EXEC" -gt "$L_FILES" ] && [ "$L_EXEC" -lt "$L_LAST" ]; echo $?)"
check "the last line runs the solo scrub with the archive's sha256" \
  "$([ "$(ud | tail -1)" = "/usr/local/sbin/dev-vm-image-scrub --profile solo $STORED_SHA" ]; echo $?)"
check "the record is written" "$([ -f "$RECORD" ]; echo $?)"
check "the record has exactly the schema" "$(python3 -I - "$RECORD" "$STORED_SHA" "$SHA" "$URL" "$DATE" "${REGIONS[@]}" <<'PY'
import json, re, sys
p, sha, psha, url, date, *regions = sys.argv[1:]
raw = open(p, encoding="utf-8").read()
d = json.loads(raw)
want = {"format", "image", "name", "owner_id", "architecture", "public", "root_volume_gib", "login_user",
        "platform_tag", "platform_sha", "base_tag", "archive_sha256", "archive_url", "built_at", "amis"}
assert set(d) == want and len(want) == 15, sorted(d)
assert list(d) == sorted(d) and list(d["amis"]) == sorted(d["amis"]), "keys not sorted"
assert raw.endswith("\n")
assert d["format"] == 1 and d["image"] == "ubuntu-24.04-hardened"
assert d["name"] == "idlefy-hardened-agent-ubuntu-24.04-amd64-%s-01" % date
assert d["owner_id"] == "995603458290" and d["architecture"] == "x86_64"
assert d["public"] is True and d["root_volume_gib"] == 20 and d["login_user"] == "ubuntu"
assert d["platform_tag"] == "v2.2.0" and d["platform_sha"] == psha and d["base_tag"] == "base-2.1.0"
assert d["archive_sha256"] == sha and d["archive_url"] == url
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["built_at"])
assert sorted(d["amis"]) == sorted(regions) and len(regions) == 17
assert all(re.fullmatch(r"ami-[0-9a-f]{17}", v) for v in d["amis"].values())
PY
echo $?)"
check "the record is uploaded to the release" "$(grep -q "release upload v2.2.0 $RECORD\$" "$T/gh.log" && cmp -s "$RECORD" "$T/state/$(basename "$RECORD")"; echo $?)"
check "the notes keep the old body and gain a row per region" \
  "$(grep -q '^gh .*release edit v2.2.0 --notes-file ' "$T/gh.log" && grep -qx 'Existing notes.' "$T/state/notes" \
     && grep -qF "### Hardened image idlefy-hardened-agent-ubuntu-24.04-amd64-$DATE-01" "$T/state/notes" \
     && for r in "${REGIONS[@]}"; do grep -q "| $r | ami-0[0-9a-f]\{16\} |" "$T/state/notes" || exit 1; done; echo $?)"
check "stdout has one '<region> <ami>' line per region" \
  "$(for r in "${REGIONS[@]}"; do [ "$(grep -cE "^$r ami-0[0-9a-f]{16}\$" "$T/stdout")" = 1 ] || exit 1; done; echo $?)"
check "the same-day count sees disabled and deprecated images, of this owner, in the build region" \
  "$(grep -q -- '--region us-east-1 ' "$T/aws.log" && grep -q -- '--owners self ' "$T/aws.log" \
     && grep -q -- '--include-deprecated' "$T/aws.log" && grep -q -- '--include-disabled' "$T/aws.log" \
     && grep -qF "Values=idlefy-hardened-agent-ubuntu-24.04-amd64-$DATE-*" "$T/aws.log"; echo $?)"
check "the user data temp file is gone" "$(f=$(grep '^user_data_file=' "$T/packer.log" | cut -d= -f2); [ -n "$f" ] && [ ! -e "$f" ]; echo $?)"
check "the work directory is gone" "$(d=$(grep '^chef install ' "$T/chef.log" | cut -d' ' -f3); [ -n "$d" ] && [ ! -e "$d" ]; echo $?)"
check "nothing went to stderr" "$([ ! -s "$T/stderr" ]; echo $?)"

echo "== an existing release is reused, not re-created =="
run_build; check "exits 0" "$?"
check "no release create" "$(! grep -q 'release create' "$T/gh.log"; echo $?)"

echo "== a stored asset with the same contents is reused, not re-uploaded =="
GH_STORED="$T/same.tgz" run_build; check "exits 0" "$?"
check "the archive is not uploaded" "$(! grep -q 'release upload .*solo-v2.2.0.tgz' "$T/gh.log"; echo $?)"
check "the stored bytes differ from the fresh export (the test means something)" \
  "$(tar -C "$T/tree-a" -czf "$T/fresh.tgz" . && [ "$(sha_of "$T/fresh.tgz")" != "$(sha_of "$T/same.tgz")" ]; echo $?)"
check "archive_sha256 is the stored bytes'" "$(var "archive_sha256=$(sha_of "$T/same.tgz")"; echo $?)"
check "...and so is the user data's" "$(ud | tail -1 | grep -q "$(sha_of "$T/same.tgz")\$"; echo $?)"

echo "== a stored asset with other contents refuses =="
GH_STORED="$T/other.tgz" run_build
check "exits non-zero, names the asset" "$([ $? -ne 0 ] && grep -q 'solo-v2.2.0.tgz' "$T/stderr"; echo $?)"
check "...packer never runs" "$([ ! -s "$T/packer.log" ]; echo $?)"
check "...nothing is uploaded" "$(! grep -q 'release upload' "$T/gh.log"; echo $?)"

echo "== a stale lock refuses =="
CHEF_INSTALL_REV=$OTHERREV run_build
check "exits non-zero, says make install" "$([ $? -ne 0 ] && grep -q 'make install' "$T/stderr"; echo $?)"
check "...no export" "$(! grep -q '^chef export' "$T/chef.log"; echo $?)"

echo "== a base tag not on origin refuses =="
GH_BASE_TAG_MISSING=1 run_build
check "exits non-zero, names base-2.1.0" "$([ $? -ne 0 ] && grep -q 'base-2.1.0' "$T/stderr"; echo $?)"
check "...no export" "$(! grep -q '^chef export' "$T/chef.log"; echo $?)"

echo "== the second build of a day is -02 =="
EXISTING_TODAY=1 run_build; check "exits 0" "$?"
check "ami_name ends -02" "$(var "ami_name=idlefy-hardened-agent-ubuntu-24.04-amd64-$DATE-02"; echo $?)"
check "...and so does the record" "$([ -f "$T/out/hardened-ami-$DATE-02.json" ]; echo $?)"
EXISTING_TODAY=99 run_build
check "a hundredth build of a day refuses, packer never runs" "$([ $? -ne 0 ] && [ ! -s "$T/packer.log" ]; echo $?)"
EXISTING_TODAY=None run_build
check "a count that is not a number refuses" "$([ $? -ne 0 ] && [ ! -s "$T/packer.log" ]; echo $?)"

echo "== a region missing from the artifact refuses =="
ARTIFACT_REGIONS="us-east-1" run_build
check "exits non-zero, names a missing region" "$([ $? -ne 0 ] && grep -q 'sa-east-1' "$T/stderr"; echo $?)"
check "...no record file" "$([ ! -e "$T/out" ] || [ -z "$(ls -A "$T/out")" ]; echo $?)"
check "...no record upload, no notes edit" "$(! grep -q 'release upload .*\.json\|release edit' "$T/gh.log"; echo $?)"
ARTIFACT_REGIONS="${REGIONS[*]} me-south-1" run_build
check "a region the file does not list refuses too" "$([ $? -ne 0 ] && [ ! -e "$RECORD" ]; echo $?)"
PACKER_RC=1 run_build
check "packer fails → refuses, no record" "$([ $? -ne 0 ] && [ ! -e "$RECORD" ] && ! grep -q 'release edit' "$T/gh.log"; echo $?)"

echo "== public=false and an attached org =="
PUBLIC=false ORG=0b7c3c1e-5f0e-4b8e-9a51-3f0c2d1e4a5b run_build; check "exits 0" "$?"
check "packer var public=false" "$(var public=false; echo $?)"
check "record public: false" "$(python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["public"] is not False)' "$RECORD"; echo $?)"
check "attached_org_id is passed" "$(var attached_org_id=0b7c3c1e-5f0e-4b8e-9a51-3f0c2d1e4a5b; echo $?)"

echo "== malformed input refuses before chef =="
cp "$R/image/hardened/regions" "$T/regions.orig"
bad_regions() {
  printf "$1" > "$R/image/hardened/regions"; run_build; local rc=$?
  check "$2" "$([ $rc -ne 0 ] && [ ! -s "$T/chef.log" ] && grep -q 'regions' "$T/stderr"; echo $?)"
}
bad_regions 'us-east-1\nnot-a-region\n' "a line that is not a region"
bad_regions 'us-east-1\neu-west-1\nus-east-1\n' "a duplicate region"
bad_regions '# only a comment\n\n' "no region at all"
bad_regions ' us-east-1\n' "a region with leading space"
printf '# a header\n\n  # indented comment\neu-west-1\nus-east-1\n' > "$R/image/hardened/regions"
run_build; check "comments and blank lines are skipped; the first region builds" "$([ $? -eq 0 ] && var build_region=eu-west-1 && var 'ami_regions=["eu-west-1","us-east-1"]'; echo $?)"
cp "$T/regions.orig" "$R/image/hardened/regions"
refuses_early() {
  local rc=$1 name=$2 word=$3
  check "$name" "$([ "$rc" -ne 0 ] && [ ! -s "$T/chef.log" ] && grep -q -- "$word" "$T/stderr"; echo $?)"
}
NO_SG=1 run_build; refuses_early $? "no security group refuses, names the variable" HARDENED_SECURITY_GROUP_ID
PLATFORM_TAG=v2.2 run_build; refuses_early $? "a malformed PLATFORM_TAG refuses" PLATFORM_TAG
PLATFORM_SHA=abc run_build; refuses_early $? "a malformed PLATFORM_SHA refuses" PLATFORM_SHA
PUBLIC=yes run_build; refuses_early $? "HARDENED_PUBLIC other than true/false refuses" HARDENED_PUBLIC
ORG=not-a-uuid run_build; refuses_early $? "a malformed attached org refuses" HARDENED_ATTACHED_ORG_ID

echo "== the tag must name PLATFORM_SHA, and the tree must be it =="
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm t && git -C "$R" tag v2.2.0
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
SKIP_TAG= PLATFORM_SHA=$HEAD_SHA run_build; check "the tag's commit, checked out → builds" "$?"
SKIP_TAG= run_build; refuses_early $? "a PLATFORM_SHA the tag does not name refuses" PLATFORM_SHA
SKIP_TAG= PLATFORM_TAG=v2.2.1 PLATFORM_SHA=$HEAD_SHA run_build; refuses_early $? "a tag that does not exist refuses" v2.2.1
rm -rf "$R/.git"

echo "== the user data is checked before packer runs =="
cp "$R/image/files/bootstrap-solo" "$T/boot.orig"
python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("__ARCHIVE_URL__", "__ARCHIVE_URLX__"))' "$R/image/files/bootstrap-solo"
run_build; check "an unrendered placeholder refuses, packer never runs" \
  "$([ $? -ne 0 ] && grep -q '__ARCHIVE_URLX__' "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"
{ cat "$T/boot.orig"; printf '# %s\n' "$(head -c 15000 /dev/urandom | base64 -w0)"; } > "$R/image/files/bootstrap-solo"
run_build; check "user data over 16 KB gzipped refuses, says 16384, packer never runs" \
  "$([ $? -ne 0 ] && grep -q '16384' "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"
cp "$T/boot.orig" "$R/image/files/bootstrap-solo"
cp "$R/image/files/dev-vm-image-scrub-solo" "$T/solo.orig"
printf 'DEV_VM_IMAGE_SCRUB\n' >> "$R/image/files/dev-vm-image-scrub-solo"
run_build; check "a scrub file holding the heredoc terminator refuses, packer never runs" \
  "$([ $? -ne 0 ] && grep -q 'terminator' "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"
cp "$T/solo.orig" "$R/image/files/dev-vm-image-scrub-solo"

echo "== the real solo user data fits in 16 KB =="
run_build; check "builds" "$?"
size=$(stat -c %s "$T/ud.gz")
echo "       bootstrap-solo + both scrub files, gzip -9: $size bytes (EC2 takes 16384)"
check "it fits" "$([ "$size" -le 16384 ]; echo $?)"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
