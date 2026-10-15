#!/usr/bin/env bash
# Functional test for scripts/policy-publish.sh — the operator's half of
# serverless policy delivery (`make push` / `make promote` in a tenant).
#
# End to end on purpose: every case that publishes then runs the VM's own
# dev-vm-policy-fetch against the same stand-in bucket, so the two halves of
# the protocol are tested against each other rather than against what either
# one assumes the other does.
#
# Runs with no AWS account and no Chef: `aws` is a directory standing in for
# S3, with ETags and conditional writes; `chef export` is a stub that, like the
# real one, never produces the same bytes twice.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH="$ROOT/scripts/policy-publish.sh"
FETCH="$ROOT/vms/modules/ec2/files/dev-vm-policy-fetch"
PASS=0
FAIL=0

BUCKET=tenant-policies
OWNER=111122223333
PREFIX=dev-vm-policies
POLICY=dev-vm
NOW=1760524800

check() {
  local name="$1" cond="$2"
  if [ "$cond" = "0" ]; then echo "  PASS: $name"; PASS=$((PASS + 1))
  else echo "  FAIL: $name"; FAIL=$((FAIL + 1)); fi
}
ok() { if "$@"; then echo 0; else echo 1; fi; }
no() { if "$@"; then echo 1; else echo 0; fi; }

setup() {
  WORK=$(mktemp -d)
  STUB="$WORK/bin"; S3="$WORK/s3"; KEYS="$WORK/keys"
  mkdir -p "$STUB" "$S3/$BUCKET" "$KEYS" "$WORK/repo/policyfiles"
  AWS_LOG="$WORK/aws.log"; : > "$AWS_LOG"

  # aws: get-object and put-object against $STUB_S3_ROOT, with ETags and
  # --if-match / --if-none-match semantics as S3 implements them.
  cat > "$STUB/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AWS_LOG"
[ "$1" = s3api ] || { echo "stub: unsupported: $*" >&2; exit 2; }
op=$2; shift 2
bucket='' key='' out='' body='' if_match='' if_none=''
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) bucket=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --body) body=$2; shift 2 ;;
    --if-match) if_match=$2; shift 2 ;;
    --if-none-match) if_none=$2; shift 2 ;;
    --expected-bucket-owner|--region) shift 2 ;;
    --*) echo "stub: unknown flag $1" >&2; exit 2 ;;
    *) out=$1; shift ;;
  esac
done
obj="$STUB_S3_ROOT/$bucket/$key"
etag() { printf '"%s"' "$(md5sum "$1" | cut -d' ' -f1)"; }
case "$op" in
  get-object)
    [ -f "$obj" ] || { echo "An error occurred (NoSuchKey) when calling the GetObject operation" >&2; exit 254; }
    cp "$obj" "$out"; printf '{"ETag": %s}\n' "$(etag "$obj" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" ;;
  put-object)
    if [ -n "${STUB_RACE_KEY:-}" ] && [ "$key" = "$STUB_RACE_KEY" ] && [ -f "$obj" ]; then
      echo '{"tampered": true}' > "$obj"   # someone else wrote between our read and our write
    fi
    if [ "$if_none" = '*' ] && [ -f "$obj" ]; then
      echo "An error occurred (PreconditionFailed) when calling the PutObject operation" >&2; exit 254
    fi
    if [ -n "$if_match" ] && { [ ! -f "$obj" ] || [ "$(etag "$obj")" != "$if_match" ]; }; then
      echo "An error occurred (PreconditionFailed) when calling the PutObject operation" >&2; exit 254
    fi
    mkdir -p "$(dirname "$obj")"; cp "$body" "$obj"; printf '{"ETag": "x"}\n' ;;
  *) echo "stub: unsupported op $op" >&2; exit 2 ;;
esac
EOF

  # chef: `chef export POLICYFILE DIR --archive`. Like the real exporter, the
  # bytes differ on every run (here: a random file), so a sha taken from a
  # fresh export never matches an archive pushed earlier.
  cat > "$STUB/chef" <<'EOF'
#!/usr/bin/env bash
[ "$1 $4" = "export --archive" ] || { echo "stub: unsupported: $*" >&2; exit 2; }
pf=$2 dir=$3 lock="${2%.rb}.lock.json"
rev=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["revision_id"])' "$lock")
t=$(mktemp -d); mkdir -p "$t/.chef"
cp "$lock" "$t/Policyfile.lock.json"; echo 'policy_name "x"' > "$t/.chef/config.rb"
head -c 16 /dev/urandom | od -An -tx1 > "$t/nondeterminism"
mkdir -p "$dir"; tar -C "$t" -czf "$dir/$(basename "$pf" .rb)-$rev.tgz" .; rm -rf "$t"
EOF
  cat > "$STUB/cinc-client" <<'EOF'
#!/usr/bin/env bash
conf=''; while [ $# -gt 0 ]; do [ "$1" = "-c" ] && conf=$2; shift; done
repo=$(sed -n 's/^chef_repo_path "\(.*\)"$/\1/p' "$conf")
python3 -I -c 'import json,sys;print("REV", json.load(open(sys.argv[1]))["revision_id"])' "$repo/Policyfile.lock.json" >> "$CINC_LOG"
EOF
  chmod +x "$STUB/aws" "$STUB/chef" "$STUB/cinc-client"
  CINC_LOG="$WORK/cinc.log"; : > "$CINC_LOG"
  export AWS_LOG CINC_LOG STUB_S3_ROOT="$S3"
  PATH="$STUB:$PATH"

  ssh-keygen -q -t ed25519 -N '' -C ops -f "$KEYS/ops"
  ssh-keygen -q -t ed25519 -N '' -C ci -f "$KEYS/ci"
  ssh-keygen -q -t ed25519 -N '' -C stranger -f "$KEYS/stranger"
  OPS_LINE="ops namespaces=\"dev-vm-policy-staging,dev-vm-policy-production\" $(cut -d' ' -f1,2 "$KEYS/ops.pub")"
  CI_LINE="ci namespaces=\"dev-vm-policy-staging\" $(cut -d' ' -f1,2 "$KEYS/ci.pub")"
  printf '%s\n%s\n' "$OPS_LINE" "$CI_LINE" > "$WORK/signers"

  PF="$WORK/repo/policyfiles/$POLICY.rb"
  echo "name '$POLICY'" > "$PF"
  write_lock "$(newrev)" "$OPS_LINE" "$CI_LINE"

  export POLICY_BUCKET="$BUCKET" POLICY_BUCKET_OWNER="$OWNER" POLICY_BUCKET_REGION=eu-central-1
  export POLICY_PREFIX="$PREFIX" POLICY_SIGNERS_FILE="$WORK/signers"
  export SIGNING_KEY="$KEYS/ops" POLICY_PUBLISH_NOW="$NOW"
}
teardown() { rm -rf "$WORK"; }

newrev() { head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1; }

write_lock() {  # write_lock REV SIGNER_LINE...
  local rev=$1; shift
  python3 -I - "${PF%.rb}.lock.json" "$rev" "$POLICY" "$@" <<'EOF'
import json, sys
out, rev, name, *signers = sys.argv[1:]
json.dump({"revision_id": rev, "name": name,
           "cookbook_locks": {"base": {"version": "2.0.0",
                                       "source_options": {"tag": "base-2.0.0"}}},
           "default_attributes": {"base": {"policy": {"signers": signers}}}}, open(out, "w"))
EOF
  REV=$rev
}

publish() { "$PUBLISH" "$@" "$PF" >"$WORK/out" 2>"$WORK/err"; echo $?; }

# A VM in GROUP, with the signers the lock installs, fetching from the same bucket.
vm_fetch() {  # vm_fetch GROUP [state-dir]
  local group=$1 state=${2:-$WORK/vm-$1}
  mkdir -p "$state/etc"
  cat > "$state/etc/policy.conf" <<EOF
POLICY_BUCKET=$BUCKET
POLICY_BUCKET_OWNER=$OWNER
POLICY_BUCKET_REGION=eu-central-1
POLICY_PREFIX=$PREFIX
FLEET_ID=$BUCKET/$PREFIX
POLICY_NAME=$POLICY
POLICY_GROUP=$group
NODE_NAME=vm-$group
EOF
  [ -f "$state/etc/policy-signers" ] || cp "$WORK/signers" "$state/etc/policy-signers"
  : > "$CINC_LOG"
  DEV_VM_POLICY_CONF="$state/etc/policy.conf" DEV_VM_POLICY_SIGNERS="$state/etc/policy-signers" \
  DEV_VM_POLICY_STATE="$state/state" DEV_VM_POLICY_RUN="$state/run" \
  DEV_VM_POLICY_NOW="$NOW" DEV_VM_POLICY_RETRY_SLEEP=0 \
    "$FETCH" >"$WORK/vm.out" 2>"$WORK/vm.err"
  echo $?
}
vm_rev() { sed -n 's/^REV //p' "$CINC_LOG" | tail -1; }
envelope_field() {  # envelope_field GROUP FIELD
  python3 -I - "$S3/$BUCKET/$PREFIX/$POLICY/$1.json" "$2" <<'EOF'
import base64, json, sys
print(json.loads(base64.b64decode(json.load(open(sys.argv[1]))["manifest"]))[sys.argv[2]])
EOF
}

# --- cases ---------------------------------------------------------------------

echo "== push publishes an archive and a staging envelope a staging VM converges =="
setup
rc=$(publish push)
check "exit 0" "$(ok [ "$rc" = 0 ])"
check "archive stored under its revision" "$(ok [ -f "$S3/$BUCKET/$PREFIX/$POLICY/archives/$REV.tgz" ])"
check "archive written with --if-none-match" "$(ok grep -q -- "--key $PREFIX/$POLICY/archives/$REV.tgz.*--if-none-match \*" "$AWS_LOG")"
check "staging envelope written" "$(ok [ -f "$S3/$BUCKET/$PREFIX/$POLICY/staging.json" ])"
check "no production envelope" "$(ok [ ! -e "$S3/$BUCKET/$PREFIX/$POLICY/production.json" ])"
check "every call pins the bucket owner" "$(ok [ "$(grep -c -- "--expected-bucket-owner $OWNER" "$AWS_LOG")" = "$(wc -l < "$AWS_LOG")" ])"
check "serial is now" "$(ok [ "$(envelope_field staging serial)" = "$NOW" ])"
rc=$(vm_fetch staging)
check "a staging VM converges it" "$(ok [ "$rc" = 0 ])"
check "...at the lock's revision" "$(ok [ "$(vm_rev)" = "$REV" ])"
rc=$(vm_fetch production)
check "a production VM has nothing yet (14)" "$(ok [ "$rc" = 14 ])"
teardown

echo "== a second push of the same lock reuses the stored archive =="
setup
publish push >/dev/null
stored_sha=$(sha256sum "$S3/$BUCKET/$PREFIX/$POLICY/archives/$REV.tgz" | cut -d' ' -f1)
vm_fetch staging >/dev/null
rc=$(publish push)
check "exit 0" "$(ok [ "$rc" = 0 ])"
check "the stored archive was not replaced" "$(ok [ "$(sha256sum "$S3/$BUCKET/$PREFIX/$POLICY/archives/$REV.tgz" | cut -d' ' -f1)" = "$stored_sha" ])"
check "the envelope names the stored bytes, not the fresh export" "$(ok [ "$(envelope_field staging archive_sha256)" = "$stored_sha" ])"
check "serial moved past the last one" "$(ok [ "$(envelope_field staging serial)" = "$((NOW + 1))" ])"
rc=$(vm_fetch staging)
check "the same staging VM converges it again" "$(ok [ "$rc" = 0 ])"
teardown

echo "== promote re-signs staging's revision for production =="
setup
publish push >/dev/null
rc=$(publish promote)
check "exit 0" "$(ok [ "$rc" = 0 ])"
check "production envelope written" "$(ok [ -f "$S3/$BUCKET/$PREFIX/$POLICY/production.json" ])"
check "for production" "$(ok [ "$(envelope_field production policy_group)" = production ])"
check "naming staging's revision" "$(ok [ "$(envelope_field production revision_id)" = "$REV" ])"
check "and staging's archive" "$(ok [ "$(envelope_field production archive_sha256)" = "$(envelope_field staging archive_sha256)" ])"
rc=$(vm_fetch production)
check "a production VM converges it" "$(ok [ "$rc" = 0 ])"
check "...at the lock's revision" "$(ok [ "$(vm_rev)" = "$REV" ])"
teardown

echo "== promote refuses what staging does not carry =="
setup
publish push >/dev/null
write_lock "$(newrev)" "$OPS_LINE" "$CI_LINE"
rc=$(publish promote)
check "lock moved past staging: refused" "$(no [ "$rc" = 0 ])"
check "says staging does not carry it" "$(ok grep -qi 'staging' "$WORK/err")"
check "no production envelope" "$(ok [ ! -e "$S3/$BUCKET/$PREFIX/$POLICY/production.json" ])"
teardown

echo "== staged: promote's checks alone, before anyone is asked to confirm =="
setup
rc=$(publish staged)
check "nothing pushed yet: refused" "$(no [ "$rc" = 0 ])"
publish push >/dev/null
rc=$(publish staged)
check "staging carries the lock's revision: exit 0" "$(ok [ "$rc" = 0 ])"
check "...and writes nothing" "$(ok [ ! -e "$S3/$BUCKET/$PREFIX/$POLICY/production.json" ])"
check "...naming the revision" "$(ok grep -q "$REV" "$WORK/out")"
write_lock "$(newrev)" "$OPS_LINE" "$CI_LINE"
rc=$(publish staged)
check "lock moved past staging: refused" "$(no [ "$rc" = 0 ])"
check "says staging does not carry it" "$(ok grep -qi 'staging' "$WORK/err")"
teardown

echo "== promote refuses a staging envelope that does not verify =="
setup
publish push >/dev/null
python3 -I - "$S3/$BUCKET/$PREFIX/$POLICY/staging.json" <<'EOF'
import json, sys
e = json.load(open(sys.argv[1])); e["signature"] = e["signature"].replace("A", "B", 1)
json.dump(e, open(sys.argv[1], "w"))
EOF
rc=$(publish promote)
check "refused" "$(no [ "$rc" = 0 ])"
check "says why" "$(ok grep -qi 'verify' "$WORK/err")"
check "no production envelope" "$(ok [ ! -e "$S3/$BUCKET/$PREFIX/$POLICY/production.json" ])"
teardown

echo "== keys and namespaces =="
setup
rc=$(SIGNING_KEY="$KEYS/stranger" publish push)
check "a key the lock does not trust cannot push" "$(no [ "$rc" = 0 ])"
check "says so before signing" "$(ok grep -qi 'not in the signers' "$WORK/err")"
rc=$(SIGNING_KEY="$KEYS/ci" publish push)
check "a staging-only key can push" "$(ok [ "$rc" = 0 ])"
rc=$(SIGNING_KEY="$KEYS/ci" publish promote)
check "...but cannot promote" "$(no [ "$rc" = 0 ])"
check "no production envelope" "$(ok [ ! -e "$S3/$BUCKET/$PREFIX/$POLICY/production.json" ])"
write_lock "$REV" "$CI_LINE"
rc=$(publish push)
check "a lock that drops the pushing key is refused" "$(no [ "$rc" = 0 ])"
teardown

echo "== serial =="
setup
publish push >/dev/null
python3 -I - "$S3/$BUCKET/$PREFIX/$POLICY/staging.json" <<'EOF'
import json, sys
e = json.load(open(sys.argv[1])); e["manifest"] = "e30="   # {} — tampered, unsigned
json.dump(e, open(sys.argv[1], "w"))
EOF
rc=$(publish push)
check "a current envelope that does not verify stops a push" "$(no [ "$rc" = 0 ])"
check "says so" "$(ok grep -qi 'verify' "$WORK/err")"
teardown
setup
publish push >/dev/null
rc=$(POLICY_PUBLISH_NOW=$((NOW - 3600)) publish push)
check "a slow clock still moves the serial forward" "$(ok [ "$(envelope_field staging serial)" = "$((NOW + 1))" ])"
teardown

echo "== concurrent writers =="
setup
publish push >/dev/null
rc=$(STUB_RACE_KEY="$PREFIX/$POLICY/staging.json" publish push)
check "a staging.json changed under us fails the push" "$(no [ "$rc" = 0 ])"
check "says it changed" "$(ok grep -qi 'changed' "$WORK/err")"
teardown

echo "== signers_sha256 is the lock's set, which a new VM checks =="
setup
publish push >/dev/null
rm -rf "$WORK/vm-new"; mkdir -p "$WORK/vm-new/etc"
printf '%s\n' "$OPS_LINE" > "$WORK/vm-new/etc/policy-signers"
rc=$(vm_fetch staging "$WORK/vm-new")
check "a new VM built with a different set refuses it (12)" "$(ok [ "$rc" = 12 ])"
rc=$(vm_fetch staging)
check "a new VM built with the lock's set converges" "$(ok [ "$rc" = 0 ])"
teardown

echo "== usage =="
"$PUBLISH" >/dev/null 2>&1; rc=$?
check "no arguments: non-zero" "$(no [ "$rc" = 0 ])"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
