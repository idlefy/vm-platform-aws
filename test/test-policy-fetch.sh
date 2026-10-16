#!/usr/bin/env bash
# Functional test for dev-vm-policy-fetch and its launcher, dev-vm-policy-run.
#
# Runs with no AWS account and no CINC: `aws` is stubbed by a directory that
# stands in for S3, and `cinc-client` by a recorder. Signatures are real
# `ssh-keygen -Y sign` output, so the verify path is the one a VM runs.
#
# The script under test is the module copy, vms/modules/ec2/files/; the
# cookbook copy is held byte-identical by test-fetch-sync.sh.
#
# Not covered here (needs root, measured on a VM): ownership of the state tree.
# The script only creates directories with mode 0700, which holds unprivileged.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FETCH="$ROOT/vms/modules/ec2/files/dev-vm-policy-fetch"
LAUNCH="$ROOT/vms/modules/ec2/files/dev-vm-policy-run"
PASS=0
FAIL=0

BUCKET=tenant-policies
OWNER=111122223333
PREFIX=dev-vm-policies
POLICY=dev-vm
FLEET="$BUCKET/$PREFIX"
NOW=1760524800

check() {
  local name="$1" cond="$2"
  if [ "$cond" = "0" ]; then
    echo "  PASS: $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"; FAIL=$((FAIL + 1))
  fi
}
ok() { if "$@"; then echo 0; else echo 1; fi; }

# --- fixtures ---------------------------------------------------------------

setup() {
  WORK=$(mktemp -d)
  STUB="$WORK/bin"; S3="$WORK/s3/$BUCKET"; KEYS="$WORK/keys"
  mkdir -p "$STUB" "$S3/$PREFIX/$POLICY/archives" "$KEYS" "$WORK/etc" "$WORK/state" "$WORK/run"
  AWS_LOG="$WORK/aws.log"; CINC_LOG="$WORK/cinc.log"
  : > "$AWS_LOG"; : > "$CINC_LOG"

  # aws: only `s3api get-object --bucket B --key K ... OUTFILE` is supported.
  # Every argv is recorded so the suite catches a dropped
  # --expected-bucket-owner or --region, which no artefact would reveal.
  cat > "$STUB/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AWS_LOG"
[ -n "${STUB_S3_DOWN:-}" ] && { echo "Could not connect to the endpoint URL" >&2; exit 255; }
[ "$1 $2" = "s3api get-object" ] || { echo "stub: unsupported: $*" >&2; exit 2; }
shift 2
bucket= key= out=
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) bucket=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --expected-bucket-owner|--region) shift 2 ;;
    --*) echo "stub: unknown flag $1" >&2; exit 2 ;;
    *) out=$1; shift ;;
  esac
done
src="$STUB_S3_ROOT/$bucket/$key"
[ -f "$src" ] || { echo "An error occurred (AccessDenied) when calling the GetObject operation" >&2; exit 254; }
cp "$src" "$out" && echo '{}'
EOF

  # cinc-client: records argv and the client config it was handed, and checks
  # the tree it is pointed at is an extracted archive.
  cat > "$STUB/cinc-client" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS %s\n' "$*" >> "$CINC_LOG"
printf 'SIGNED_BY %s\n' "${DEV_VM_POLICY_SIGNED_BY-<unset>}" >> "$CINC_LOG"
printf 'GROUP %s\n' "${DEV_VM_POLICY_GROUP-<unset>}" >> "$CINC_LOG"
printf 'SIGNED_KEY %s\n' "${DEV_VM_POLICY_SIGNED_KEY-<unset>}" >> "$CINC_LOG"
conf=
while [ $# -gt 0 ]; do [ "$1" = "-c" ] && conf=$2; shift; done
[ -n "$conf" ] && sed 's/^/CONF /' "$conf" >> "$CINC_LOG"
repo=$(sed -n 's/^chef_repo_path "\(.*\)"$/\1/p' "$conf")
rev=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["revision_id"])' "$repo/Policyfile.lock.json")
printf 'REV %s\n' "$rev" >> "$CINC_LOG"
# STUB_OVERLAP: start a second run of the script mid-converge, as the timer
# did on a live first boot, and record whether this converge's tree survived.
if [ -n "${STUB_OVERLAP:-}" ]; then
  before=$(stat -c %i "$repo")
  o=$STUB_OVERLAP
  ( unset STUB_OVERLAP; "$STUB_FETCH" > "$o.out" 2>&1; echo $? > "$o.rc" ) &
  sleep 2
  after=$(stat -c %i "$repo" 2>/dev/null || echo gone)
  [ "$before" = "$after" ] && echo 'TREE intact' >> "$CINC_LOG" || echo 'TREE replaced' >> "$CINC_LOG"
fi
exit "${STUB_CONVERGE_RC:-0}"
EOF
  chmod +x "$STUB/aws" "$STUB/cinc-client"
  export AWS_LOG CINC_LOG STUB_S3_ROOT="$WORK/s3"
  PATH="$STUB:$PATH"

  ssh-keygen -q -t ed25519 -N '' -C ops -f "$KEYS/ops"
  ssh-keygen -q -t ed25519 -N '' -C ci -f "$KEYS/ci"
  ssh-keygen -q -t ed25519 -N '' -C stranger -f "$KEYS/stranger"
  SIGNERS="$WORK/etc/policy-signers"
  {
    printf 'ops namespaces="dev-vm-policy-staging,dev-vm-policy-production" %s\n' "$(cut -d' ' -f1,2 "$KEYS/ops.pub")"
    printf 'ci namespaces="dev-vm-policy-staging" %s\n' "$(cut -d' ' -f1,2 "$KEYS/ci.pub")"
  } > "$SIGNERS"

  write_conf production vm-one
  export DEV_VM_POLICY_CONF="$WORK/etc/policy.conf"
  export DEV_VM_POLICY_SIGNERS="$SIGNERS"
  export DEV_VM_POLICY_STATE="$WORK/state"
  export DEV_VM_POLICY_RUN="$WORK/run"
  export DEV_VM_POLICY_NOW="$NOW"
  export DEV_VM_POLICY_RETRY_SLEEP=0
}

teardown() { rm -rf "$WORK"; }

write_conf() {  # group node_name
  cat > "$WORK/etc/policy.conf" <<EOF
POLICY_BUCKET=$BUCKET
POLICY_BUCKET_OWNER=$OWNER
POLICY_BUCKET_REGION=eu-central-1
POLICY_PREFIX=$PREFIX
FLEET_ID=$FLEET
POLICY_NAME=$POLICY
POLICY_GROUP=$1
NODE_NAME=$2
EOF
}

signers_sha() {  # the canonical form: trimmed, non-empty, sorted, unique
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$1" | grep -v '^$' | LC_ALL=C sort -u | sha256sum | cut -d' ' -f1
}

newrev() { head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1; }

# make_archive REV [evil]: an archive shaped like `chef export --archive`.
# evil = dotdot | symlink | hardlink | absolute plants one unsafe member;
# evil = wronglock stores an archive whose lock names a different revision.
make_archive() {
  local rev=$1 evil=${2:-} d out
  d=$(mktemp -d "$WORK/arch.XXXX")
  local lockrev=$rev
  [ "$evil" = wronglock ] && lockrev=$(newrev)
  printf '{"revision_id":"%s","name":"%s"}\n' "$lockrev" "$POLICY" > "$d/Policyfile.lock.json"
  mkdir -p "$d/.chef" "$d/cookbook_artifacts/base-x/recipes"
  printf 'policy_name "%s"\n' "$POLICY" > "$d/.chef/config.rb"
  echo "# recipe" > "$d/cookbook_artifacts/base-x/recipes/default.rb"
  out="$S3/$PREFIX/$POLICY/archives/$rev.tgz"
  case "$evil" in
    ""|wronglock) tar -C "$d" -czf "$out" . ;;
    symlink) ln -s /etc/shadow "$d/link"; tar -C "$d" -czf "$out" . ;;
    hardlink) ln "$d/Policyfile.lock.json" "$d/hard"; tar -C "$d" -czf "$out" . ;;
    dotdot|absolute)
      python3 -I - "$d" "$out" "$evil" <<'EOF'
import io, sys, tarfile
src, out, evil = sys.argv[1:]
with tarfile.open(out, "w:gz") as t:
    t.add(src, arcname=".")
    name = "../escape" if evil == "dotdot" else "/tmp/escape"
    data = b"x"
    info = tarfile.TarInfo(name); info.size = len(data)
    t.addfile(info, io.BytesIO(data))
EOF
      ;;
  esac
  rm -rf "$d"
  sha256sum "$out" | cut -d' ' -f1
}

# publish KEY NS [field=value ...]: sign a manifest and write the group envelope.
# Defaults describe a valid production envelope for $REV/$SHA.
publish() {
  local key=$1 ns=$2; shift 2
  local group=${ns#dev-vm-policy-}
  python3 -I - "$WORK/manifest" "$group" "$REV" "$SHA" "$NOW" "$(signers_sha "$SIGNERS")" "$FLEET" "$POLICY" "$@" <<'EOF'
import json, sys
out, group, rev, sha, now, ssha, fleet, policy, *over = sys.argv[1:]
m = {"format": 1, "fleet_id": fleet, "policy_name": policy, "policy_group": group,
     "revision_id": rev, "archive_sha256": sha, "cookbook_tag": "base-2.0.0",
     "signers_sha256": ssha, "serial": int(now)}
for kv in over:
    k, v = kv.split("=", 1)
    m[k] = int(v) if k in ("serial", "format") else v
open(out, "wb").write(json.dumps(m, sort_keys=True).encode())
EOF
  rm -f "$WORK/manifest.sig"
  ssh-keygen -q -Y sign -f "$KEYS/$key" -n "$ns" "$WORK/manifest" 2>/dev/null
  python3 -I - "$WORK/manifest" "$WORK/manifest.sig" "$S3/$PREFIX/$POLICY/${ENVELOPE_AS:-$group}.json" <<'EOF'
import base64, json, sys
m, s, out = sys.argv[1:]
json.dump({"manifest": base64.b64encode(open(m, "rb").read()).decode(),
           "signature": open(s).read()}, open(out, "w"))
EOF
}

fetch() { "$FETCH" >"$WORK/out" 2>"$WORK/err"; echo $?; }
converged_rev() { sed -n 's/^REV //p' "$CINC_LOG" | tail -1; }
converges() { grep -c '^ARGS' "$CINC_LOG"; }
archive_gets() { grep -c -- "--key $PREFIX/$POLICY/archives/" "$AWS_LOG"; }

# Establish a converged baseline at $REV; later cases replace the envelope.
baseline() {
  REV=$(newrev); SHA=$(make_archive "$REV")
  publish ops dev-vm-policy-production
  [ "$(fetch)" = 0 ] || { echo "  baseline failed:"; cat "$WORK/err"; }
  BASE_REV=$REV
  : > "$CINC_LOG"; : > "$AWS_LOG"
}

# A rejected envelope must converge the last good revision and exit 12.
expect_rejected() {
  local rc=$1 label=$2
  check "$label: exit 12" "$(ok [ "$rc" = 12 ])"
  check "$label: converged the last good revision" "$(ok [ "$(converged_rev)" = "$BASE_REV" ])"
  check "$label: last-serial unchanged" "$(ok grep -q "$BASE_REV" "$WORK/state/last-serial")"
}

# --- cases -----------------------------------------------------------------

echo "== a valid envelope converges =="
setup
REV=$(newrev); SHA=$(make_archive "$REV")
publish ops dev-vm-policy-production
rc=$(fetch)
check "exit 0" "$(ok [ "$rc" = 0 ])"
check "converged the published revision" "$(ok [ "$(converged_rev)" = "$REV" ])"
check "local mode" "$(ok grep -q '^ARGS.* -z' "$CINC_LOG")"
check "node_name from policy.conf" "$(ok grep -qx 'CONF node_name "vm-one"' "$CINC_LOG")"
check "policy_name from policy.conf" "$(ok grep -qx "CONF policy_name \"$POLICY\"" "$CINC_LOG")"
check "policyfile mode" "$(ok grep -qx 'CONF use_policyfile true' "$CINC_LOG")"
# The stub accepts any config, and so did this test while the script wrote
# `chef_zero.listen false`, which the real client refuses as an unknown option:
# every first boot failed closed (measured on a live VM, 2026-10-16). So the
# config is also loaded by chef-config itself, strict as cinc-client is.
check "no chef-zero socket" "$(ok grep -qx 'CONF listen false' "$CINC_LOG")"
sed -n 's/^CONF //p' "$CINC_LOG" > "$WORK/client.rb"
if command -v chef >/dev/null; then
  chef exec ruby -e \
    'require "chef-config/config"; ChefConfig::Config.from_file(ARGV[0]); exit(ChefConfig::Config[:listen] == false ? 0 : 1)' \
    "$WORK/client.rb" >/dev/null 2>&1
  check "chef-config accepts the client config" "$?"
else
  echo "  FAIL: chef-config accepts the client config — needs chef (Cinc Workstation) on PATH"
  FAIL=$((FAIL + 1))
fi
check "every S3 call pins the bucket owner" "$(ok [ "$(grep -c -- "--expected-bucket-owner $OWNER" "$AWS_LOG")" = "$(wc -l < "$AWS_LOG")" ])"
check "every S3 call names the bucket region" "$(ok [ "$(grep -c -- '--region eu-central-1' "$AWS_LOG")" = "$(wc -l < "$AWS_LOG")" ])"
check "reads the production envelope" "$(ok grep -q -- "--key $PREFIX/$POLICY/production.json" "$AWS_LOG")"
check "records the serial" "$(ok grep -q "^$NOW $REV $SHA$" "$WORK/state/last-serial")"
check "status says ok" "$(ok grep -q ' ok ' "$WORK/state/status")"
# base::cinc_client refuses a signers set that drops the key that signed the
# revision it is converging; this is how it learns which key that was.
check "tells the converge who signed" "$(ok grep -qx 'SIGNED_BY ops' "$CINC_LOG")"
check "tells the converge the group" "$(ok grep -qx 'GROUP production' "$CINC_LOG")"
# The key, not just the principal: a principal can hold several keys, and the
# recipe must refuse a set that drops the one that actually signed.
check "tells the converge which key signed" "$(ok grep -qxF "SIGNED_KEY $(cut -d' ' -f1,2 "$KEYS/ops.pub")" "$CINC_LOG")"
check "state tree is 0700" "$(ok [ "$(stat -c %a "$WORK/state")" = 700 ])"
check "run dir is 0700" "$(ok [ "$(stat -c %a "$WORK/run")" = 700 ])"
teardown

echo "== an unchanged envelope does not download the archive again =="
setup; baseline
rc=$(fetch)
check "exit 0" "$(ok [ "$rc" = 0 ])"
check "converged again" "$(ok [ "$(converged_rev)" = "$BASE_REV" ])"
check "no archive download" "$(ok [ "$(archive_gets)" = 0 ])"
check "envelope was read" "$(ok grep -q -- "production.json" "$AWS_LOG")"
teardown

echo "== a corrupted cached archive is caught and fetched again =="
setup; baseline
echo garbage >> "$WORK/state/archives/$BASE_REV.tgz"
rc=$(fetch)
check "exit 0" "$(ok [ "$rc" = 0 ])"
check "re-downloaded" "$(ok [ "$(archive_gets)" = 1 ])"
check "converged" "$(ok [ "$(converged_rev)" = "$BASE_REV" ])"
teardown

echo "== a new revision replaces the old one =="
setup; baseline
REV=$(newrev); SHA=$(make_archive "$REV")
publish ops dev-vm-policy-production serial=$((NOW + 60))
rc=$(fetch)
check "exit 0" "$(ok [ "$rc" = 0 ])"
check "converged the new revision" "$(ok [ "$(converged_rev)" = "$REV" ])"
check "records the new serial" "$(ok grep -q "^$((NOW + 60)) $REV $SHA$" "$WORK/state/last-serial")"
teardown

echo "== rejections converge the last good revision =="
setup; baseline
REV=$(newrev); SHA=$(make_archive "$REV")
publish stranger dev-vm-policy-production serial=$((NOW + 60))
expect_rejected "$(fetch)" "unknown signer"
check "unknown signer: says why" "$(ok grep -qi 'signature' "$WORK/err")"
# Nothing was verified on this run, so the converge must not be told a signer:
# the recipe then keeps the signers set it already has.
check "fallback: no signer passed to the converge" "$(ok grep -qx 'SIGNED_BY ' "$CINC_LOG")"
check "fallback: no signing key passed to the converge" "$(ok grep -qx 'SIGNED_KEY ' "$CINC_LOG")"
: > "$CINC_LOG"
ENVELOPE_AS=production publish ci dev-vm-policy-staging policy_group=production serial=$((NOW + 60))
expect_rejected "$(fetch)" "staging signature presented as production"
: > "$CINC_LOG"
publish ci dev-vm-policy-production serial=$((NOW + 60))
expect_rejected "$(fetch)" "staging-only key signing production"
: > "$CINC_LOG"
publish ops dev-vm-policy-production serial=$((NOW + 60)) fleet_id=other-bucket/dev-vm-policies
expect_rejected "$(fetch)" "fleet mismatch"
: > "$CINC_LOG"
publish ops dev-vm-policy-production serial=$((NOW + 60)) policy_group=staging
expect_rejected "$(fetch)" "group mismatch"
: > "$CINC_LOG"
publish ops dev-vm-policy-production serial=$((NOW + 60)) policy_name=other
expect_rejected "$(fetch)" "policy mismatch"
: > "$CINC_LOG"
publish ops dev-vm-policy-production serial=$((NOW - 60))
expect_rejected "$(fetch)" "serial regression"
: > "$CINC_LOG"
publish ops dev-vm-policy-production serial=$NOW
expect_rejected "$(fetch)" "equal serial, different revision"
: > "$CINC_LOG"
publish ops dev-vm-policy-production serial=$((NOW + 86400 + 1))
expect_rejected "$(fetch)" "serial more than 24h ahead"
: > "$CINC_LOG"
publish ops dev-vm-policy-production serial=$((NOW + 60)) archive_sha256="$(printf %064d 0)"
expect_rejected "$(fetch)" "sha mismatch"
: > "$CINC_LOG"
publish ops dev-vm-policy-production serial=$((NOW + 60)) revision_id=../../etc
expect_rejected "$(fetch)" "revision_id is not a hash"
: > "$CINC_LOG"
publish ops dev-vm-policy-production serial=$((NOW + 60)) format=2
expect_rejected "$(fetch)" "unknown manifest format"
for evil in dotdot absolute symlink hardlink wronglock; do
  : > "$CINC_LOG"
  REV=$(newrev); SHA=$(make_archive "$REV" "$evil")
  publish ops dev-vm-policy-production serial=$((NOW + 60))
  expect_rejected "$(fetch)" "archive member: $evil"
done
check "nothing escaped the state tree" "$(ok [ ! -e "$WORK/escape" ] && [ ! -e "$WORK/state/escape" ])"
: > "$CINC_LOG"
printf '{"manifest": "%s", "signature": "x", "extra": 1}' "$(echo '{}' | base64)" > "$S3/$PREFIX/$POLICY/production.json"
expect_rejected "$(fetch)" "malformed envelope"
teardown

echo "== an equal serial for the same revision converges =="
setup; baseline
publish ops dev-vm-policy-production
rc=$(fetch)
check "exit 0" "$(ok [ "$rc" = 0 ])"
teardown

echo "== staging VMs read staging.json =="
setup
write_conf staging vm-two
REV=$(newrev); SHA=$(make_archive "$REV")
publish ci dev-vm-policy-staging
rc=$(fetch)
check "exit 0" "$(ok [ "$rc" = 0 ])"
check "reads the staging envelope" "$(ok grep -q -- "--key $PREFIX/$POLICY/staging.json" "$AWS_LOG")"
teardown

echo "== first boot =="
setup
rc=$(fetch)
check "no envelope, nothing to fall back to: exit 14" "$(ok [ "$rc" = 14 ])"
check "no converge" "$(ok [ "$(converges)" = 0 ])"
REV=$(newrev); SHA=$(make_archive "$REV")
publish ops dev-vm-policy-production signers_sha256="$(printf %064d 0 | tr 0 a)"
rc=$(fetch)
check "signers_sha256 mismatch: exit 12" "$(ok [ "$rc" = 12 ])"
check "signers_sha256 mismatch: no converge" "$(ok [ "$(converges)" = 0 ])"
check "signers_sha256 mismatch: says why" "$(ok grep -q 'signers' "$WORK/err")"
publish ops dev-vm-policy-production
rc=$(fetch)
check "matching signers_sha256: exit 0" "$(ok [ "$rc" = 0 ])"
teardown

echo "== POLICY_MIN_SERIAL refuses anything older, first boot included =="
# A bucket writer can serve a new VM an old, validly signed envelope; with no
# rotation since, signers_sha256 matches. The operator raises the floor after a
# security fix, and nothing below it converges anywhere.
setup
echo "POLICY_MIN_SERIAL=$((NOW + 1))" >> "$WORK/etc/policy.conf"
REV=$(newrev); SHA=$(make_archive "$REV")
publish ops dev-vm-policy-production
rc=$(fetch)
check "first boot, below the floor: exit 12" "$(ok [ "$rc" = 12 ])"
check "below the floor: no converge" "$(ok [ "$(converges)" = 0 ])"
check "says why" "$(ok grep -q 'POLICY_MIN_SERIAL' "$WORK/err")"
publish ops dev-vm-policy-production serial=$((NOW + 1))
rc=$(fetch)
check "at the floor: exit 0" "$(ok [ "$rc" = 0 ])"
echo "POLICY_MIN_SERIAL=soon" >> "$WORK/etc/policy.conf"
rc=$(fetch)
check "malformed floor: exit 70" "$(ok [ "$rc" = 70 ])"
teardown

echo "== delivery failures count to three before the unit fails =="
setup; baseline
for n in 1 2; do
  : > "$CINC_LOG"
  rc=$(STUB_S3_DOWN=1 fetch)
  check "failure $n: exit 0" "$(ok [ "$rc" = 0 ])"
  check "failure $n: converged the last good revision" "$(ok [ "$(converged_rev)" = "$BASE_REV" ])"
done
check "status says degraded" "$(ok grep -q ' delivery-failed ' "$WORK/state/status")"
rc=$(STUB_S3_DOWN=1 fetch)
check "failure 3: exit 11" "$(ok [ "$rc" = 11 ])"
rc=$(fetch)
check "recovery: exit 0" "$(ok [ "$rc" = 0 ])"
rc=$(STUB_S3_DOWN=1 fetch)
check "counter was reset by the success" "$(ok [ "$rc" = 0 ])"
check "retried within the run" "$(ok [ "$(grep -c production.json "$AWS_LOG")" -ge 3 ])"
teardown

echo "== a missing envelope counts as a delivery failure =="
setup; baseline
rm "$S3/$PREFIX/$POLICY/production.json"
rc=$(fetch)
check "exit 0 below the threshold" "$(ok [ "$rc" = 0 ])"
check "says missing or denied" "$(ok grep -q 'missing or denied' "$WORK/err")"
teardown

echo "== a failed converge =="
setup; baseline
REV=$(newrev); SHA=$(make_archive "$REV")
publish ops dev-vm-policy-production serial=$((NOW + 60))
rc=$(STUB_CONVERGE_RC=1 fetch)
check "exit 13" "$(ok [ "$rc" = 13 ])"
check "last-serial unchanged" "$(ok grep -q "$BASE_REV" "$WORK/state/last-serial")"
teardown

# Measured on a live first boot, 2026-10-16: the converge enables
# cinc-client.timer, the timer fires two minutes later while that converge is
# still running, and the unit's run re-extracted the revision tree under it.
# The first converge then failed on a cookbook file chef-zero could no longer
# serve, and, with cinc-client's own lock inside the replaced tree, the two
# converged at once.
echo "== a run that starts mid-converge waits for it =="
setup
REV=$(newrev); SHA=$(make_archive "$REV")
publish ops dev-vm-policy-production
rc=$(STUB_OVERLAP="$WORK/overlap" STUB_FETCH="$FETCH" fetch)
check "first run exit 0" "$(ok [ "$rc" = 0 ])"
check "the converging tree was left alone" "$(ok grep -qx 'TREE intact' "$CINC_LOG")"
for _ in $(seq 1 50); do [ -s "$WORK/overlap.rc" ] && break; sleep 0.2; done
check "the second run converged after it" "$(ok [ "$(cat "$WORK/overlap.rc" 2>/dev/null)" = 0 ])"
check "two converges in all" "$(ok [ "$(converges)" = 2 ])"
teardown

echo "== bad configuration is an internal error =="
setup
write_conf production 'vm"one'
rc=$(fetch)
check "quote in node name: exit 70" "$(ok [ "$rc" = 70 ])"
write_conf canary vm-one
rc=$(fetch)
check "unknown group: exit 70" "$(ok [ "$rc" = 70 ])"
rm "$WORK/etc/policy.conf"
rc=$(fetch)
check "missing policy.conf: exit 70" "$(ok [ "$rc" = 70 ])"
teardown

echo "== old revisions are garbage-collected =="
setup; baseline
FIRST=$BASE_REV
for i in 1 2; do
  REV=$(newrev); SHA=$(make_archive "$REV")
  publish ops dev-vm-policy-production serial=$((NOW + 60 * i))
  fetch >/dev/null
done
check "oldest archive deleted" "$(ok [ ! -e "$WORK/state/archives/$FIRST.tgz" ])"
check "current archive kept" "$(ok [ -e "$WORK/state/archives/$REV.tgz" ])"
check "two archives at most" "$(ok [ "$(find "$WORK/state/archives" -name '*.tgz' | wc -l)" -le 2 ])"
teardown

echo "== the launcher falls back to .prev only when the script cannot run =="
# Not on 70 or any other code the script can be driven to from outside — a full
# disk, a missing directory — or anyone able to cause one could downgrade the
# fleet to a .prev whose bug the current version fixed.
setup
mkdir -p "$WORK/sbin"
for v in "" .prev; do
  # shellcheck disable=SC2016  # $* and ${RC…} are for the stub, not for us
  printf '#!/bin/sh\necho "%s $*" >> "%s/launch.log"\nexit ${RC%s:-0}\n' "fetch$v" "$WORK" "${v#.}" > "$WORK/sbin/dev-vm-policy-fetch$v"
  chmod +x "$WORK/sbin/dev-vm-policy-fetch$v"
done
export DEV_VM_POLICY_FETCH="$WORK/sbin/dev-vm-policy-fetch"
for code in 2 126 127; do
  RC=$code "$LAUNCH" >/dev/null 2>&1; rc=$?
  check "exit $code: .prev ran" "$(ok grep -q '^fetch\.prev' "$WORK/launch.log")"
  check "exit $code: .prev's exit code" "$(ok [ "$rc" = 0 ])"
  : > "$WORK/launch.log"
done
for code in 1 70; do
  RC=$code "$LAUNCH" >/dev/null 2>&1; rc=$?
  check "exit $code: no fallback" "$(grep -q '^fetch\.prev' "$WORK/launch.log" && echo 1 || echo 0)"
  check "exit $code: exit code kept" "$(ok [ "$rc" = "$code" ])"
  : > "$WORK/launch.log"
done
RC=12 "$LAUNCH" >/dev/null 2>&1; rc=$?
check "rejection: no fallback" "$(grep -q '^fetch\.prev' "$WORK/launch.log" && echo 1 || echo 0)"
check "rejection: exit code kept" "$(ok [ "$rc" = 12 ])"
: > "$WORK/launch.log"
rm "$WORK/sbin/dev-vm-policy-fetch.prev"
RC=127 "$LAUNCH" >/dev/null 2>&1; rc=$?
check "no .prev: exit code kept" "$(ok [ "$rc" = 127 ])"
unset DEV_VM_POLICY_FETCH
teardown

echo "== the self-test passes against the fixture the cookbook ships =="
FIXTURE="$ROOT/cinc/cookbooks/base/files/default/policy-fetch-selftest"
"$FETCH" --self-test "$FIXTURE" >/dev/null 2>&1
check "exit 0" "$(ok [ $? = 0 ])"

echo "== the self-test fails a script that cannot verify =="
SCRATCH=$(mktemp -d)
# shellcheck disable=SC2016  # the pattern is the script's literal text
sed 's/-n "\$NAMESPACE"/-n wrong-namespace/' "$FETCH" > "$SCRATCH/broken"
chmod +x "$SCRATCH/broken"
check "the mutation applied" "$(cmp -s "$FETCH" "$SCRATCH/broken" && echo 1 || echo 0)"
"$SCRATCH/broken" --self-test "$FIXTURE" >/dev/null 2>&1
check "exit non-zero" "$(ok [ $? != 0 ])"
rm -rf "$SCRATCH"

echo "== default paths are the ones user_data and the cookbook write =="
check "policy.conf" "$(ok grep -qF 'DEV_VM_POLICY_CONF:-/etc/dev-vm/policy.conf' "$FETCH")"
check "signers" "$(ok grep -qF 'DEV_VM_POLICY_SIGNERS:-/etc/dev-vm/policy-signers' "$FETCH")"
check "state" "$(ok grep -qF 'DEV_VM_POLICY_STATE:-/var/lib/dev-vm/policy' "$FETCH")"
check "run" "$(ok grep -qF 'DEV_VM_POLICY_RUN:-/run/dev-vm' "$FETCH")"
check "launcher target" "$(ok grep -qF 'DEV_VM_POLICY_FETCH:-/usr/local/sbin/dev-vm-policy-fetch' "$LAUNCH")"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
