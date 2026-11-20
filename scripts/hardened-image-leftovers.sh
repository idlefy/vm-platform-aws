#!/usr/bin/env bash
# hardened-image-leftovers.sh — list this account's images named exactly
# <ami-name> in every region of image/hardened/regions. Read-only: it calls
# ec2 describe-images and nothing else. Design: docs/design/hardened-image.md
# ("A build that failed after its images"); clean-up: docs/runbook.md.
#
#   scripts/hardened-image-leftovers.sh idlefy-hardened-agent-ubuntu-24.04-amd64-YYYYMMDD-NN
#
# Called by scripts/hardened-image-build.sh when a build fails after
# `packer build` started, and by the publish workflow's step after a failed,
# cancelled or timed-out build (the runner may kill the driver before it can
# list anything itself). Prints, on stdout, a heading and one line per region:
# the images' ids, state, Public flag and whether IdlefyPublishedImage=true
# is set, "none", or why the region could not be read.
#
# Exit 0 when every region was read, 1 when one was not or the name is
# malformed. Credentials come from the environment; nothing here prints one.

set -euo pipefail
export AWS_PAGER=""

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGIONS_FILE="$ROOT/image/hardened/regions"
NAME_PREFIX=idlefy-hardened-agent-ubuntu-24.04-amd64

die() { echo "✗ hardened-image-leftovers: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: scripts/hardened-image-leftovers.sh <ami-name>"
NAME=$1
[[ $NAME =~ ^${NAME_PREFIX//./\\.}-[0-9]{8}-[0-9]{2}$ ]] \
  || die "'$NAME' is not a name of the form $NAME_PREFIX-YYYYMMDD-NN"
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

ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

echo "!! Images named $NAME may exist, and may be PUBLIC; no release record names them."
echo "!! Deregister them and delete their snapshots before any retention run or new"
echo "!! build — docs/runbook.md, \"A hardened build that failed after its images\"."
RC=0
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
exit "$RC"
