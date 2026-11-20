#!/usr/bin/env bash
# hardened-image-leftovers.sh — what a failed or cancelled hardened build may
# have left in this account. Design: docs/design/hardened-image.md ("A build
# that failed after its images"); clean-up: docs/runbook.md.
#
#   scripts/hardened-image-leftovers.sh [--clean-build] [<ami-name>]
#
# It lists:
#   - images named exactly <ami-name> in every region of image/hardened/regions
#     (only when a name is given) — id, state, Public flag and whether
#     IdlefyPublishedImage=true is set, "none", or why a region could not be
#     read. Images are only ever listed: removing one is the owner's call;
#   - in the build region (the file's first line), every instance tagged
#     Name=idlefy-hardened-image-build that is not terminated or shutting
#     down, and every key pair named packer_* carrying that tag. A runner
#     killed mid-build (an Actions cancel or timeout) leaves both behind:
#     Packer never gets to clean up.
# With --clean-build it then terminates those instances and deletes those key
# pairs — exactly those, and nothing else; the publisher role may do no more.
# Without it, it calls describe-* only.
#
# Called by scripts/hardened-image-build.sh (read-only) when a build fails
# after `packer build` started, and with --clean-build by the publish
# workflow's leftovers step after a failed, cancelled or timed-out build.
#
# Exit 0 when every read and every clean-up call succeeded, 1 otherwise (or on
# a malformed argument). Credentials come from the environment; nothing here
# prints one.

set -euo pipefail
export AWS_PAGER=""

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGIONS_FILE="$ROOT/image/hardened/regions"
NAME_PREFIX=idlefy-hardened-agent-ubuntu-24.04-amd64
BUILD_TAG=idlefy-hardened-image-build

die() { echo "✗ hardened-image-leftovers: $*" >&2; exit 1; }
usage="usage: scripts/hardened-image-leftovers.sh [--clean-build] [<ami-name>]"

CLEAN=0 NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --clean-build) CLEAN=1 ;;
    -*) die "unknown option '$1' — $usage" ;;
    *) [ -z "$NAME" ] || die "$usage"; NAME=$1 ;;
  esac
  shift
done
if [ -n "$NAME" ]; then
  [[ $NAME =~ ^${NAME_PREFIX//./\\.}-[0-9]{8}-[0-9]{2}$ ]] \
    || die "'$NAME' is not a name of the form $NAME_PREFIX-YYYYMMDD-NN"
fi
for c in aws python3; do command -v "$c" >/dev/null || die "$c is not on PATH"; done

# The same parse as scripts/hardened-image-build.sh.
REGIONS="$(python3 -I - "$REGIONS_FILE" <<'PY'
import re, sys
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
print(" ".join(regions))
PY
)" || die "image/hardened/regions: see above — fix the file"
BUILD_REGION=${REGIONS%% *}

ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT
RC=0

# ---- images (read-only) ----------------------------------------------------------
if [ -n "$NAME" ]; then
  echo "!! Images named $NAME may exist, and may be PUBLIC; no release record names them."
  echo "!! Deregister them and delete their snapshots before any retention run or new"
  echo "!! build — docs/runbook.md, \"A hardened build that failed after its images\"."
  for r in $REGIONS; do
    if ! out="$(aws ec2 describe-images --region "$r" --owners self --include-deprecated --include-disabled \
                  --filters "Name=name,Values=$NAME" --output json 2>"$ERR" < /dev/null)"; then
      echo "   $r: could not list (check by hand): $(tr '\n' ' ' < "$ERR")"
      RC=1
      continue
    fi
    python3 -I - "$r" "$out" "$NAME" <<'PY' || { echo "   $r: unreadable answer (check by hand)"; RC=1; }
import json, sys
region, answer, name = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    images = [i for i in json.loads(answer)["Images"] if i.get("Name") == name]
    rows = []
    for i in images:
        fenced = any(t.get("Key") == "IdlefyPublishedImage" and t.get("Value") == "true" for t in i.get("Tags") or [])
        rows.append("   %s: %s  state=%s  public=%s  IdlefyPublishedImage=true: %s"
                    % (region, i["ImageId"], i.get("State", "?"), str(i.get("Public")).lower(), "yes" if fenced else "no"))
except (ValueError, KeyError, TypeError, AttributeError):
    sys.exit(1)
print("\n".join(rows) if rows else "   %s: none" % region)
PY
  done
else
  echo "No image name given: images are not listed."
fi

# ---- the build instance and its key pair -------------------------------------------
# Only what carries the build's Name tag, in the build region, and only key
# pairs Packer names packer_*: the publisher role may terminate and delete
# exactly these.
INSTANCES="" KEYS=""
echo "Build resources in $BUILD_REGION (Name=$BUILD_TAG):"
if out="$(aws ec2 describe-instances --region "$BUILD_REGION" \
            --filters "Name=tag:Name,Values=$BUILD_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
            --output json 2>"$ERR" < /dev/null)" \
   && INSTANCES="$(python3 -I -c '
import json, re, sys
rows = []
for res in json.loads(sys.argv[1])["Reservations"]:
    for i in res["Instances"]:
        if not re.fullmatch(r"i-[0-9a-f]+", i["InstanceId"]):
            raise ValueError(i["InstanceId"])
        rows.append("%s:%s" % (i["InstanceId"], i["State"]["Name"]))
print(" ".join(rows))' "$out" 2>/dev/null)"; then
  if [ -n "$INSTANCES" ]; then
    for x in $INSTANCES; do echo "   instance ${x%%:*}  state=${x#*:}"; done
  else
    echo "   instances: none"
  fi
else
  echo "   instances: could not list (check by hand): $(tr '\n' ' ' < "$ERR")"
  INSTANCES="" RC=1
fi
if out="$(aws ec2 describe-key-pairs --region "$BUILD_REGION" --filters "Name=tag:Name,Values=$BUILD_TAG" \
            --output json 2>"$ERR" < /dev/null)" \
   && KEYS="$(python3 -I -c '
import json, re, sys
names = [k["KeyName"] for k in json.loads(sys.argv[1])["KeyPairs"]]
print(" ".join(n for n in names if re.fullmatch(r"packer_[0-9a-zA-Z_-]+", n)))' "$out" 2>/dev/null)"; then
  if [ -n "$KEYS" ]; then
    for k in $KEYS; do echo "   key pair $k"; done
  else
    echo "   packer_* key pairs: none"
  fi
else
  echo "   packer_* key pairs: could not list (check by hand): $(tr '\n' ' ' < "$ERR")"
  KEYS="" RC=1
fi

if [ "$CLEAN" = 1 ]; then
  for x in $INSTANCES; do
    if aws ec2 terminate-instances --region "$BUILD_REGION" --instance-ids "${x%%:*}" --output json \
         > /dev/null 2>"$ERR" < /dev/null; then
      echo "   terminated ${x%%:*}"
    else
      echo "   could not terminate ${x%%:*} (do it by hand): $(tr '\n' ' ' < "$ERR")"; RC=1
    fi
  done
  for k in $KEYS; do
    if aws ec2 delete-key-pair --region "$BUILD_REGION" --key-name "$k" --output json \
         > /dev/null 2>"$ERR" < /dev/null; then
      echo "   deleted key pair $k"
    else
      echo "   could not delete key pair $k (do it by hand): $(tr '\n' ' ' < "$ERR")"; RC=1
    fi
  done
elif [ -n "$INSTANCES$KEYS" ]; then
  echo "   (the publish workflow's leftovers step removes these; by hand: scripts/hardened-image-leftovers.sh --clean-build)"
fi
exit "$RC"
