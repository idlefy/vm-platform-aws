#!/usr/bin/env bash
# Generate the fixture that `dev-vm-policy-fetch --self-test` runs against.
#
#   test/make-policy-fetch-fixture.sh cinc/cookbooks/base/files/default/policy-fetch-selftest
#
# base::cinc_client ships the result to every VM and runs a new version of
# the script against it before letting that version replace the one in use.
# Re-run this whenever the envelope or manifest format changes; the test suite
# (test-policy-fetch.sh) fails while the fixture is stale.
#
# The signing key is thrown away after use. It signs only for a fleet, bucket
# and signers set that exist nowhere but here, so the fixture grants nothing:
# no VM trusts its key, and the self-test runs with its own signers file.

set -euo pipefail

OUT=${1:?usage: $0 OUTPUT_DIR}
NOW=1760524800
BUCKET=selftest-bucket
PREFIX=selftest
POLICY=selftest
GROUP=production
REV=$(printf '%064d' 0 | tr 0 5)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/s3/$BUCKET/$PREFIX/$POLICY/archives"

ssh-keygen -q -t ed25519 -N '' -C selftest -f "$TMP/key"
printf 'selftest namespaces="dev-vm-policy-%s" %s\n' "$GROUP" "$(cut -d' ' -f1,2 "$TMP/key.pub")" \
  > "$OUT/policy-signers"
echo "$NOW" > "$OUT/now"

cat > "$OUT/policy.conf" <<EOF
POLICY_BUCKET=$BUCKET
POLICY_BUCKET_OWNER=000000000000
POLICY_BUCKET_REGION=us-east-1
POLICY_PREFIX=$PREFIX
FLEET_ID=$BUCKET/$PREFIX
POLICY_NAME=$POLICY
POLICY_GROUP=$GROUP
NODE_NAME=selftest
EOF

# The archive: the shape of `chef export --archive`, minus the cookbooks.
mkdir -p "$TMP/archive/.chef"
printf '{"revision_id":"%s","name":"%s"}\n' "$REV" "$POLICY" > "$TMP/archive/Policyfile.lock.json"
printf 'policy_name "%s"\n' "$POLICY" > "$TMP/archive/.chef/config.rb"
ARCHIVE="$OUT/s3/$BUCKET/$PREFIX/$POLICY/archives/$REV.tgz"
tar -C "$TMP/archive" --owner=0 --group=0 --mtime=@"$NOW" -czf "$ARCHIVE" .
SHA=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
SIGNERS_SHA=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$OUT/policy-signers" | grep -v '^$' \
              | LC_ALL=C sort -u | sha256sum | cut -d' ' -f1)

printf '{"archive_sha256": "%s", "cookbook_tag": "base-0.0.0", "fleet_id": "%s", "format": 1, "policy_group": "%s", "policy_name": "%s", "revision_id": "%s", "serial": %s, "signers_sha256": "%s"}' \
  "$SHA" "$BUCKET/$PREFIX" "$GROUP" "$POLICY" "$REV" "$NOW" "$SIGNERS_SHA" > "$TMP/manifest"
ssh-keygen -q -Y sign -f "$TMP/key" -n "dev-vm-policy-$GROUP" "$TMP/manifest" 2>/dev/null
python3 -I - "$TMP/manifest" "$TMP/manifest.sig" "$OUT/s3/$BUCKET/$PREFIX/$POLICY/$GROUP.json" <<'EOF'
import base64, json, sys
m, s, out = sys.argv[1:]
json.dump({"manifest": base64.b64encode(open(m, "rb").read()).decode(),
           "signature": open(s).read()}, open(out, "w"))
EOF

# Stubs. They answer only what the script asks during one clean run.
cat > "$OUT/bin/aws" <<'EOF'
#!/bin/sh
# self-test stub: `aws s3api get-object --bucket B --key K ... OUTFILE` from $STUB_S3_ROOT
[ "$1 $2" = "s3api get-object" ] || exit 2
shift 2
bucket='' key='' out=''
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) bucket=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --*) shift 2 ;;
    *) out=$1; shift ;;
  esac
done
[ -f "$STUB_S3_ROOT/$bucket/$key" ] || { echo "AccessDenied" >&2; exit 254; }
cp "$STUB_S3_ROOT/$bucket/$key" "$out"
EOF
cat > "$OUT/bin/cinc-client" <<'EOF'
#!/bin/sh
# self-test stub: succeed only if pointed at an extracted archive and told who signed.
conf=''
while [ $# -gt 0 ]; do [ "$1" = "-c" ] && conf=$2; shift; done
repo=$(sed -n 's/^chef_repo_path "\(.*\)"$/\1/p' "$conf")
[ -f "$repo/Policyfile.lock.json" ] && [ "${DEV_VM_POLICY_SIGNED_BY:-}" = selftest ]
EOF
chmod 0755 "$OUT/bin/aws" "$OUT/bin/cinc-client"
echo "fixture written to $OUT"
