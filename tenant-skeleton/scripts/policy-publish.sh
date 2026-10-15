#!/usr/bin/env bash
# policy-publish.sh — the operator's half of serverless policy delivery.
#
#   scripts/policy-publish.sh push    cinc/policyfiles/<name>.rb
#   scripts/policy-publish.sh promote cinc/policyfiles/<name>.rb
#   scripts/policy-publish.sh staged  cinc/policyfiles/<name>.rb
#   scripts/policy-publish.sh show    cinc/policyfiles/<name>.rb
#
# `cd cinc && make push` / `make promote` call this after pin-check and
# `chef install`; it is not meant to be run on its own. The VM's half is
# dev-vm-policy-fetch, and the protocol between them is in the platform's
# docs/design/serverless-policy-delivery.md. test/test-policy-publish.sh runs
# both halves against each other.
#
# push:    export the policy from its lock, store the archive once under its
#          revision_id, and write a signed staging envelope naming it.
# promote: verify the staging envelope, require it to carry the committed
#          lock's revision, and write a NEW production envelope for it — signed
#          in the production namespace, so a copied staging envelope never works.
# staged:  promote's checks and nothing else. `make promote` runs it for every
#          policy before asking for confirmation, so a refusal comes before the
#          "yes", not halfway through writing production.
# show:    read-only, for preflight: one line per group, "<group> ok <serial>
#          <revision_id> <signers_sha256>", "<group> missing" or "<group>
#          invalid". Needs no chef and no signing key.
#
# Every mode that signs compares the stored archive's CONTENTS with a fresh
# export of the committed lock before it signs anything over it. Hashing the
# stored bytes is not enough: revision_id is in the lock, so anyone who can
# write the bucket — no signing key needed — can store archives/<rev>.tgz first,
# with the genuine lock inside and a recipe of their own, and have it signed by
# the next push; and a stolen staging-only key can carry such an archive
# through staging into a promote.
#
# Environment (the Makefile fills these from vms/ via terraform console):
#   POLICY_BUCKET POLICY_BUCKET_OWNER POLICY_BUCKET_REGION POLICY_PREFIX
#   POLICY_SIGNERS_FILE  var.policy_signers, one line each — what verifies the
#                        envelopes already in the bucket
#   SIGNING_KEY          your key; default ~/.ssh/id_ed25519. A .pub path signs
#                        through ssh-agent.
#   POLICY_PUBLISH_NOW   tests only
#
# Never prints a secret: nothing it handles is one. Policyfile attributes are
# not secret by rule (see the design record), and the signing key stays in
# ssh-keygen or the agent.

set -uo pipefail
umask 077

die() { echo "policy-publish: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: $0 push|promote|staged|show <policyfile.rb>"
MODE=$1 PF=$2
case "$MODE" in push|promote|staged|show) ;; *) die "usage: $0 push|promote|staged|show <policyfile.rb>" ;; esac
LOCK="${PF%.rb}.lock.json"
{ [ -f "$PF" ] && [ -f "$LOCK" ]; } || die "$PF and its lock $LOCK must both exist"

for v in POLICY_BUCKET POLICY_BUCKET_OWNER POLICY_BUCKET_REGION POLICY_PREFIX POLICY_SIGNERS_FILE; do
  [ -n "${!v:-}" ] || die "$v is not set (run this through make push / make promote)"
done
[ -r "$POLICY_SIGNERS_FILE" ] || die "cannot read $POLICY_SIGNERS_FILE"
for tool in aws ssh-keygen python3 sha256sum; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
[ "$MODE" = show ] || command -v chef >/dev/null || die "chef is not on PATH"

SIGNING_KEY=${SIGNING_KEY:-$HOME/.ssh/id_ed25519}
case "$SIGNING_KEY" in *.pub) PUBKEY=$SIGNING_KEY ;; *) PUBKEY="$SIGNING_KEY.pub" ;; esac
[ "$MODE" = show ] || [ -r "$PUBKEY" ] || die "no public key at $PUBKEY (set SIGNING_KEY)"
NOW=${POLICY_PUBLISH_NOW:-$(date +%s)}

W=$(mktemp -d) || die "cannot create a work directory"
trap 'rm -rf "$W"' EXIT

# ---- the lock ------------------------------------------------------------------
# Everything signed comes from the committed lock — the revision, the policy
# name, the signers set the revision installs — never from the policyfile, which
# pin-check has already proven matches it.
eval "$(python3 -I - "$LOCK" <<'EOF'
import hashlib, json, re, shlex, sys
lock = json.load(open(sys.argv[1]))
rev, name = lock.get("revision_id", ""), lock.get("name", "")
if not re.fullmatch(r"[0-9a-f]{64}", rev) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", name):
    sys.exit("lock has no usable revision_id or name")
signers = lock.get("default_attributes", {}).get("base", {}).get("policy", {}).get("signers", [])
if not isinstance(signers, list) or not all(isinstance(s, str) for s in signers):
    sys.exit("base.policy.signers in the lock is not a list of strings")
kept = sorted({s.strip() for s in signers if s.strip()})
canonical = "".join(l + "\n" for l in kept)
base = lock.get("cookbook_locks", {}).get("base", {})
tag = base.get("source_options", {}).get("tag") or ("base-" + base.get("version", ""))
if not re.fullmatch(r"base-\d+\.\d+\.\d+", tag):
    sys.exit("cannot tell which base tag the lock pins")
open(sys.argv[1] + ".signers", "w").write(canonical)
for k, v in (("REV", rev), ("NAME", name), ("TAG", tag),
             ("SIGNERS_SHA", hashlib.sha256(canonical.encode()).hexdigest())):
    print(f"{k}={shlex.quote(v)}")
EOF
)" || die "cannot read $LOCK"
LOCK_SIGNERS="$LOCK.signers"
trap 'rm -rf "$W" "$LOCK_SIGNERS"' EXIT
[ "$MODE" = show ] || [ -s "$LOCK_SIGNERS" ] || die "base.policy.signers in $LOCK is empty; every VM would reject every envelope"

KEY_BASE="$POLICY_PREFIX/$NAME"
FLEET_ID="$POLICY_BUCKET/$POLICY_PREFIX"

# ---- S3 -------------------------------------------------------------------------

s3() {  # s3 OP ARGS... — every call pinned to the bucket owner and region
  local op=$1; shift
  aws s3api "$op" --bucket "$POLICY_BUCKET" "$@" \
    --expected-bucket-owner "$POLICY_BUCKET_OWNER" --region "$POLICY_BUCKET_REGION"
}

# get KEY OUT → prints the ETag; 1 if the object does not exist, 2 on any other error.
get() {
  local out
  if out=$(s3 get-object --key "$1" "$2" 2>"$W/aws.err"); then
    python3 -I -c 'import json,sys;print(json.load(sys.stdin)["ETag"])' <<<"$out"
    return 0
  fi
  grep -qE 'NoSuchKey|\(404\)' "$W/aws.err" && return 1
  cat "$W/aws.err" >&2; return 2
}

# ---- archives -------------------------------------------------------------------------

export_lock() {  # → $EXPORTED, a fresh export of the committed lock
  [ -z "${EXPORTED:-}" ] || return 0
  chef export "$PF" "$W/export" --archive >/dev/null || die "chef export failed"
  EXPORTED=$(find "$W/export" -maxdepth 1 -name '*.tgz' | head -1)
  [ -n "$EXPORTED" ] || die "chef export produced no archive"
}

# require_archive_matches STORED — the stored archive holds exactly what the
# lock exports: same paths, same types, same file contents and link targets.
# Read with tarfile, never extracted: the stored bytes are untrusted here.
# Timestamps and modes are not compared; they differ between exports.
require_archive_matches() {
  export_lock
  python3 -I - "$1" "$EXPORTED" <<'EOF' \
    || die "archives/$REV.tgz does not match what $LOCK exports; someone other than make push wrote it — investigate, and do not sign it"
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
EOF
}

# ---- envelopes --------------------------------------------------------------------

# verify ENVELOPE GROUP → writes $W/<group>.manifest and prints
# serial revision_id archive_sha256 signers_sha256.
# The same checks a VM makes that can be made from here: shape, signature in the
# group's namespace against the tenant's signers, fleet, policy and group.
verify() {
  local env=$1 group=$2 m="$W/$2.manifest" s="$W/$2.sig" principal ok=''
  python3 -I - "$env" "$m" "$s" <<'EOF' || return 1
import base64, json, sys
e = json.load(open(sys.argv[1]))
if not isinstance(e, dict) or set(e) != {"manifest", "signature"}:
    sys.exit(1)
open(sys.argv[2], "wb").write(base64.b64decode(e["manifest"], validate=True))
open(sys.argv[3], "w").write(e["signature"])
EOF
  while IFS= read -r principal; do
    [ -n "$principal" ] || continue
    ssh-keygen -Y verify -f "$POLICY_SIGNERS_FILE" -I "$principal" -n "dev-vm-policy-$group" \
      -s "$s" < "$m" >/dev/null 2>&1 && { ok=1; break; }
  done < <(ssh-keygen -Y find-principals -s "$s" -f "$POLICY_SIGNERS_FILE" 2>/dev/null)
  [ -n "$ok" ] || return 1
  python3 -I - "$m" "$FLEET_ID" "$NAME" "$group" <<'EOF'
import json, sys
m = json.loads(open(sys.argv[1], "rb").read())
if (m.get("fleet_id"), m.get("policy_name"), m.get("policy_group")) != tuple(sys.argv[2:]) \
        or type(m.get("serial")) is not int:
    sys.exit(1)
print(m["serial"], m["revision_id"], m["archive_sha256"], m["signers_sha256"])
EOF
}

# The key you sign with must be one the lock installs, in the namespace you sign
# for: a revision whose signers set drops its own signer would make every VM
# reject the next push, and a VM would refuse a signature outside its namespace.
require_key_for() {  # require_key_for GROUP
  python3 -I - "$PUBKEY" "$LOCK_SIGNERS" "dev-vm-policy-$1" <<'EOF' \
    || die "your key ($PUBKEY) is not in the signers this revision installs with the $1 namespace (base.policy.signers in the lock)"
import re, sys
key = " ".join(open(sys.argv[1]).read().split()[:2])
for line in open(sys.argv[2]):
    m = re.fullmatch(r'(\S+) namespaces="([^"]+)"(?:,valid-before="[0-9Z]+")? (\S+ \S+)', line.strip())
    if m and m.group(3) == key and sys.argv[3] in m.group(2).split(","):
        sys.exit(0)
sys.exit(1)
EOF
}

# write_envelope GROUP REV SHA CURRENT_SERIAL ETAG
write_envelope() {
  local group=$1 rev=$2 sha=$3 cur=$4 etag=$5 serial
  serial=$NOW
  [ -n "$cur" ] && [ "$cur" -ge "$serial" ] && serial=$((cur + 1))
  printf '{"archive_sha256": "%s", "cookbook_tag": "%s", "fleet_id": "%s", "format": 1, "policy_group": "%s", "policy_name": "%s", "revision_id": "%s", "serial": %s, "signers_sha256": "%s"}' \
    "$sha" "$TAG" "$FLEET_ID" "$group" "$NAME" "$rev" "$serial" "$SIGNERS_SHA" > "$W/new.manifest"
  rm -f "$W/new.manifest.sig"
  ssh-keygen -q -Y sign -f "$SIGNING_KEY" -n "dev-vm-policy-$group" "$W/new.manifest" \
    || die "signing failed"
  python3 -I - "$W/new.manifest" "$W/new.manifest.sig" "$W/new.json" <<'EOF'
import base64, json, sys
json.dump({"manifest": base64.b64encode(open(sys.argv[1], "rb").read()).decode(),
           "signature": open(sys.argv[2]).read()}, open(sys.argv[3], "w"))
EOF
  # Conditional on what we read: two operators pushing at once fails loudly
  # instead of one silently replacing the other.
  local cond=(--if-none-match '*')
  [ -n "$etag" ] && cond=(--if-match "$etag")
  if ! s3 put-object --key "$KEY_BASE/$group.json" --body "$W/new.json" "${cond[@]}" >/dev/null 2>"$W/aws.err"; then
    grep -q PreconditionFailed "$W/aws.err" \
      && die "$group.json changed while this ran (another push or promote?); nothing was written — run it again"
    cat "$W/aws.err" >&2; die "could not write $group.json"
  fi
  echo "✓ $NAME@$group → $rev (serial $serial)"
}

# read_current GROUP → sets CUR_SERIAL CUR_ETAG (empty if none).
# An envelope that does not verify stops everything: its serial must not be
# what the next one counts up from, and someone wrote it who should not have.
read_current() {
  local group=$1 rc
  CUR_SERIAL='' CUR_ETAG=''
  CUR_ETAG=$(get "$KEY_BASE/$group.json" "$W/$group.json"); rc=$?
  [ "$rc" = 1 ] && { CUR_ETAG=''; return 0; }
  [ "$rc" = 0 ] || die "cannot read $group.json"
  read -r CUR_SERIAL _ _ _ < <(verify "$W/$group.json" "$group") \
    || die "the current $group.json does not verify against POLICY_SIGNERS_FILE — investigate before publishing over it"
  [ -n "$CUR_SERIAL" ] || die "the current $group.json does not verify against POLICY_SIGNERS_FILE — investigate before publishing over it"
}

# ---- show ------------------------------------------------------------------------

if [ "$MODE" = show ]; then
  for group in staging production; do
    rc=0; get "$KEY_BASE/$group.json" "$W/$group.json" >/dev/null || rc=$?
    case "$rc" in
      0) if read -r serial rev _ signers < <(verify "$W/$group.json" "$group") && [ -n "${rev:-}" ]; then
           echo "$group ok $serial $rev $signers"
         else
           echo "$group invalid"
         fi ;;
      1) echo "$group missing" ;;
      *) die "cannot read $group.json" ;;
    esac
  done
  exit 0
fi

# ---- push ------------------------------------------------------------------------

if [ "$MODE" = push ]; then
  require_key_for staging
  export_lock

  # Written once per revision. If it already exists the fresh export is
  # discarded: exports are not reproducible, so only the stored bytes can be
  # what the envelope commits to — and those are downloaded, compared with the
  # export and hashed, never trusted by name.
  if s3 put-object --key "$KEY_BASE/archives/$REV.tgz" --body "$EXPORTED" --if-none-match '*' >/dev/null 2>"$W/aws.err"; then
    echo "  stored archives/$REV.tgz"
  elif grep -q PreconditionFailed "$W/aws.err"; then
    echo "  archives/$REV.tgz already stored; reusing it"
  else
    cat "$W/aws.err" >&2; die "could not store the archive"
  fi
  get "$KEY_BASE/archives/$REV.tgz" "$W/stored.tgz" >/dev/null || die "cannot read back archives/$REV.tgz"
  require_archive_matches "$W/stored.tgz"
  SHA=$(sha256sum "$W/stored.tgz" | cut -d' ' -f1)

  read_current staging
  write_envelope staging "$REV" "$SHA" "$CUR_SERIAL" "$CUR_ETAG"
  exit 0
fi

# ---- promote / staged ------------------------------------------------------------

require_key_for production
get "$KEY_BASE/staging.json" "$W/staging-src.json" >/dev/null || die "there is no staging.json to promote — run make push first"
read -r _ S_REV S_SHA _ < <(verify "$W/staging-src.json" staging) \
  || die "staging.json does not verify against POLICY_SIGNERS_FILE; refusing to promote it"
[ -n "${S_REV:-}" ] || die "staging.json does not verify against POLICY_SIGNERS_FILE; refusing to promote it"
[ "$S_REV" = "$REV" ] || die "staging does not carry the revision this tree would promote (lock $REV, staging $S_REV); run make push and verify a staging VM first"
get "$KEY_BASE/archives/$REV.tgz" "$W/stored.tgz" >/dev/null || die "archives/$REV.tgz is missing"
[ "$(sha256sum "$W/stored.tgz" | cut -d' ' -f1)" = "$S_SHA" ] || die "archives/$REV.tgz no longer matches the staging envelope"
require_archive_matches "$W/stored.tgz"
if [ "$MODE" = staged ]; then
  echo "  ok   staging carries $NAME at $REV"
  exit 0
fi

read_current production
write_envelope production "$REV" "$S_SHA" "$CUR_SERIAL" "$CUR_ETAG"
