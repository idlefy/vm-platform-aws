#!/usr/bin/env bash
# hardened-image-retire.sh — retire old builds of Idlefy's hardened image, or
# yank one. Run by hand through the retire workflow; not a tenant tool. Design:
# docs/design/hardened-image.md.
#
# Every region of image/hardened/regions is read on its own; a problem in one
# region stops that region and no other.
#
# A wrong deregistration breaks every customer's machine creation that still
# names the image, so the script does nothing in a region it is unsure of and
# says why: a name outside the pattern, a name twice, a date or snapshot it
# cannot read, an answer it cannot parse. It is a dry run unless --apply.

set -euo pipefail
export AWS_PAGER=""

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGIONS_FILE="$ROOT/image/hardened/regions"
ACCOUNT_ID=995603458290
NAME_PREFIX=idlefy-hardened-agent-ubuntu-24.04-amd64
FENCE_KEY=IdlefyPublishedImage

usage() {
  cat <<EOF
usage: scripts/hardened-image-retire.sh [--apply] [--disable <ami-name>]

Retention (no --disable), per region of image/hardened/regions, over the images
of this account tagged $FENCE_KEY=true and named $NAME_PREFIX-YYYYMMDD-NN:
  keep       the two newest (by name) public builds not yet deprecated — never
             touched, whatever their age; the consumer pins exactly these two.
             A build is deprecated once its DeprecationTime has PASSED: AWS
             gives every public image one two years after creation, and a
             future date is not a deprecation;
  deprecate  any other public build once the newest is 7 days old, and a
             private build once it is itself 7 days old (deprecation is set
             10 minutes ahead: AWS refuses a time in the past; a date within
             the next 11 minutes — AWS rounds it up to the minute — is a
             pending deprecation and is left be);
  deregister a build deprecated 7 days ago or more, or disabled and created 7
             days ago or more and not one of the two newest builds — then
             delete its snapshots.
  safety net one of the two newest public builds whose DeprecationTime has
             passed (the two-year default, if publishing stopped) is never
             deregistered: the region is reported, nothing is done in it, and
             the run exits 1 — publish a new build.

--disable <ami-name>  yank one build: disable-image on that exact name in every
             region, and nothing else. A disabled image can no longer launch,
             so the costpilot PR that removes its ids from the consumer's pin
             must ship FIRST; disable only after it is live. A later retention
             run deregisters it once it is 7 days old and two newer builds
             exist.

Without --apply nothing changes: every action is printed as "would …".
Exit 0 unless an AWS call failed or a region was left alone out of doubt.
Environment: HARDENED_NOW (epoch seconds) replaces the clock, for tests.
EOF
}
die() { echo "✗ hardened-image-retire: $*" >&2; exit 1; }

APPLY=0 DISABLE="" HAVE_DISABLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --disable)
      [ $# -ge 2 ] || { usage >&2; die "--disable needs an image name"; }
      DISABLE=$2; HAVE_DISABLE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument '$1'" ;;
  esac
  shift
done
if [ "$HAVE_DISABLE" = 1 ]; then
  [[ $DISABLE =~ ^${NAME_PREFIX//./\\.}-[0-9]{8}-[0-9]{2}$ ]] \
    || die "--disable '$DISABLE' is not a name of the form $NAME_PREFIX-YYYYMMDD-NN"
fi
NOW="${HARDENED_NOW:-$(date -u +%s)}"
[[ $NOW =~ ^[0-9]+$ ]] || die "HARDENED_NOW='$NOW' is not epoch seconds"
for c in aws python3; do command -v "$c" >/dev/null || die "$c is not on PATH"; done

TMPS=()
# shellcheck disable=SC2317  # reached only through the traps below
cleanup() { [ ${#TMPS[@]} -eq 0 ] || rm -rf "${TMPS[@]}"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
W="$(mktemp -d)"; TMPS+=("$W")

# ---- regions -------------------------------------------------------------------
# The same parse as scripts/hardened-image-build.sh: '#' lines and blank lines
# are comments; every other line is exactly a region, none repeated.
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

# ---- the account -----------------------------------------------------------------
aws sts get-caller-identity --output json > "$W/id.json" 2> "$W/err" < /dev/null \
  || die "sts get-caller-identity failed: $(head -n1 "$W/err")"
acct="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["Account"])' "$W/id.json" 2>/dev/null)" \
  || die "sts get-caller-identity returned no Account"
[ "$acct" = "$ACCOUNT_ID" ] || die "these credentials are for account $acct, not $ACCOUNT_ID — nothing was listed or changed"

DEPRECATE_AT="$(python3 -I -c 'import datetime, sys
print(datetime.datetime.fromtimestamp(int(sys.argv[1]) + 600, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$NOW")"

# plan REGION FILE — the plan for one region's describe-images answer, one
# tab-separated action per line:
#   say <text> | none | notfound | doubt <why>
#   deprecate <id> <name> <why> | deregister <id> <name> <snapshot ids> <why>
#   disable <id> <name>
# Any doubt line means: do nothing in this region. Deprecations come before
# deregistrations — the least destructive first.
plan() {
  python3 -I - "$2" "$NOW" "$NAME_PREFIX" "$DISABLE" "$HAVE_DISABLE" <<'PY'
import calendar, json, re, sys, time
path, now, prefix, target, disable = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5] == "1"
DAY = 86400
GRACE = 7 * DAY
# This script sets a deprecation 600 s ahead and AWS rounds --deprecate-at up
# to the next minute, so an earlier run's date can lie up to 659 s ahead.
PENDING = 660
NAME = re.compile(re.escape(prefix) + r"-[0-9]{8}-[0-9]{2}")
STAMP = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?Z")

def out(*f):
    print("\t".join(f))

def doubt(why):
    out("doubt", why)
    sys.exit(0)

def epoch(s):
    m = STAMP.fullmatch(s) if isinstance(s, str) else None
    if not m:
        return None
    try:
        return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None

def days(t):
    return "%d days" % (t // DAY)

try:
    images = json.load(open(path))["Images"]
    if not isinstance(images, list) or not all(isinstance(i, dict) for i in images):
        raise TypeError
except (OSError, ValueError, KeyError, TypeError):
    doubt("describe-images returned something unreadable")

if disable:
    hits = [i for i in images if i.get("Name") == target]
    if not hits:
        out("notfound")
    elif len(hits) > 1:
        doubt("%d images are named %s" % (len(hits), target))
    elif not re.fullmatch(r"ami-[0-9a-f]+", str(hits[0].get("ImageId"))):
        doubt("%s has an unreadable image id %r" % (target, hits[0].get("ImageId")))
    elif hits[0].get("State") == "disabled":
        out("already", hits[0]["ImageId"], target)
    else:
        out("disable", hits[0]["ImageId"], target)
    sys.exit(0)

if not images:
    out("none")
    sys.exit(0)

builds, names = [], set()
for i in images:
    iid, name = i.get("ImageId"), i.get("Name")
    if not isinstance(iid, str) or not re.fullmatch(r"ami-[0-9a-f]+", iid):
        doubt("an image has an unreadable id %r" % (iid,))
    if not isinstance(name, str) or not NAME.fullmatch(name):
        doubt("%s is named %r, outside %s-YYYYMMDD-NN — names decide which builds are newest" % (iid, name, prefix))
    if name in names:
        doubt("two images are named %s" % name)
    names.add(name)
    if not isinstance(i.get("Public"), bool):
        doubt("%s has no readable Public" % iid)
    created = epoch(i.get("CreationDate"))
    if created is None:
        doubt("%s has an unreadable CreationDate %r" % (iid, i.get("CreationDate")))
    deprecated = None
    if "DeprecationTime" in i:
        deprecated = epoch(i["DeprecationTime"])
        if deprecated is None:
            doubt("%s has an unreadable DeprecationTime %r" % (iid, i["DeprecationTime"]))
    snaps = []
    for m in i.get("BlockDeviceMappings") or []:
        if not isinstance(m, dict) or "Ebs" not in m:
            continue
        s = m["Ebs"].get("SnapshotId") if isinstance(m["Ebs"], dict) else None
        if not isinstance(s, str) or not re.fullmatch(r"snap-[0-9a-f]+", s):
            doubt("%s has an EBS mapping without a readable snapshot id" % iid)
        snaps.append(s)
    state = i.get("State", "available")
    if not isinstance(state, str):
        doubt("%s has no readable State" % iid)
    builds.append(dict(id=iid, name=name, public=i["Public"], created=created,
                       deprecated=deprecated, snaps=snaps, disabled=state == "disabled"))

# A DeprecationTime is not a deprecation until it has passed: AWS gives every
# public image one, two years after its creation. Ours, set by an earlier run,
# lies within the next PENDING seconds.
def past(b):
    return b["deprecated"] is not None and b["deprecated"] <= now

def pending(b):
    return b["deprecated"] is not None and now < b["deprecated"] <= now + PENDING

builds.sort(key=lambda b: b["name"], reverse=True)
keep = [b for b in builds if b["public"] and not b["disabled"] and not past(b)][:2]
keep_ids = {b["id"] for b in keep}
# The two newest builds that were ever published (public now, or disabled by a
# yank). Nothing among them is deregistered, whatever its dates say.
newest = [b for b in builds if b["public"] or b["disabled"]][:2]
newest_ids = {b["id"] for b in newest}
for b in newest:
    if b["public"] and not b["disabled"] and past(b):
        doubt("%s (%s), one of the two newest public builds, passed its deprecation date %s ago — "
              "the consumer no longer accepts it; publish a new build. Nothing here deregisters it"
              % (b["id"], b["name"], days(now - b["deprecated"])))
current_age = now - keep[0]["created"] if keep else None
says, deprecations, deregistrations = [], [], []
for label, b in zip(("current", "previous"), keep):
    says.append("keep %s %s (%s, %s old)" % (b["id"], b["name"], label, days(now - b["created"])))
for b in builds:
    if b["id"] in keep_ids:
        continue
    age = now - b["created"]
    if b["disabled"]:
        if b["id"] in newest_ids:
            says.append("%s waits: disabled, and one of the two newest builds; deregistered once two newer ones exist" % b["id"])
        elif age >= GRACE:
            if not b["snaps"]:
                doubt("%s is due for deregistration but lists no snapshot" % b["id"])
            deregistrations.append((b, "disabled, %s old" % days(age)))
        else:
            says.append("%s waits: disabled, %s old; deregistered once 7 days old" % (b["id"], days(age)))
    elif past(b):
        since = now - b["deprecated"]
        if since >= GRACE:
            if not b["snaps"]:
                doubt("%s is due for deregistration but lists no snapshot" % b["id"])
            deregistrations.append((b, "deprecated %s ago" % days(since)))
        else:
            says.append("%s waits: deprecated %s ago; deregistered once 7 days have passed" % (b["id"], days(since)))
    elif pending(b):
        says.append("%s waits: deprecation pending (scheduled within 11 minutes)" % b["id"])
    elif b["public"]:
        # Public, live and not kept: two newer live public builds exist, so
        # keep[0] and current_age are set.
        if current_age >= GRACE:
            deprecations.append((b, "superseded; the current build %s is %s old" % (keep[0]["id"], days(current_age))))
        else:
            says.append("%s waits: the current build is %s old; older builds are deprecated once it is 7 days old"
                        % (b["id"], days(current_age)))
    else:
        if age >= GRACE:
            deprecations.append((b, "private build, %s old" % days(age)))
        else:
            says.append("%s waits: a private build, %s old; deprecated once 7 days old" % (b["id"], days(age)))

for s in says:
    out("say", s)
for b, why in deprecations:
    out("deprecate", b["id"], b["name"], why)
for b, why in deregistrations:
    out("deregister", b["id"], b["name"], " ".join(b["snaps"]), why)
PY
}

# mutate REGION DESC aws-args… — performs one change, or reports the failure.
mutate() {
  local r=$1 desc=$2; shift 2
  echo "$desc ($r)"
  if aws "$@" --output json > /dev/null 2> "$W/err" < /dev/null; then return 0; fi
  echo "✗ $r: $1 $2 failed: $(head -n1 "$W/err") — nothing more is done in $r" >&2
  return 1
}

RC=0 ACTIONS=0 FOUND=0
for r in $REGIONS; do
  if ! aws ec2 describe-images --region "$r" --owners self --include-deprecated --include-disabled \
         --filters "Name=tag:$FENCE_KEY,Values=true" "Name=name,Values=$NAME_PREFIX-*" \
         --output json > "$W/images.json" 2> "$W/err" < /dev/null; then
    echo "✗ $r: describe-images failed: $(head -n1 "$W/err") — nothing is done in $r" >&2
    RC=1; continue
  fi
  plan "$r" "$W/images.json" > "$W/plan" || { echo "✗ $r: could not plan — nothing is done in $r" >&2; RC=1; continue; }
  if grep -q '^doubt' "$W/plan"; then
    while IFS=$'\t' read -r _ why; do
      echo "✗ $r: left alone: $why" >&2
    done < <(grep '^doubt' "$W/plan")
    RC=1; continue
  fi
  while IFS=$'\t' read -r kind a b c d; do
    case "$kind" in
      none) echo "$r: no published images" ;;
      notfound) echo "$r: no image named $DISABLE" ;;
      already) FOUND=1; echo "$r: $a $b is already disabled" ;;
      say) echo "$r: $a" ;;
      deprecate)
        ACTIONS=$((ACTIONS+1))
        if [ "$APPLY" = 0 ]; then echo "would deprecate $a ($r)"; echo "    $b — $c"
        else
          mutate "$r" "deprecate $a $b at $DEPRECATE_AT" \
            ec2 enable-image-deprecation --region "$r" --image-id "$a" --deprecate-at "$DEPRECATE_AT" \
            || { RC=1; break; }
        fi ;;
      deregister)
        ACTIONS=$((ACTIONS+1))
        if [ "$APPLY" = 0 ]; then
          echo "would deregister $a ($r)"; echo "    $b — $d"
          for s in $c; do echo "would delete-snapshot $s ($r)"; done
        else
          mutate "$r" "deregister $a $b" ec2 deregister-image --region "$r" --image-id "$a" || { RC=1; break; }
          read -ra left <<< "$c"
          while [ ${#left[@]} -gt 0 ]; do
            mutate "$r" "delete-snapshot ${left[0]}" ec2 delete-snapshot --region "$r" --snapshot-id "${left[0]}" || break
            left=("${left[@]:1}")
          done
          if [ ${#left[@]} -gt 0 ]; then
            echo "✗ $r: $a is deregistered, but these snapshots are left — delete them by hand in $r: ${left[*]}" >&2
            RC=1; break
          fi
        fi ;;
      disable)
        ACTIONS=$((ACTIONS+1)); FOUND=1
        if [ "$APPLY" = 0 ]; then echo "would disable $a ($r)"; echo "    $b"
        else mutate "$r" "disable $a $b" ec2 disable-image --region "$r" --image-id "$a" || { RC=1; break; }
        fi ;;
      *) echo "✗ $r: unexpected plan line '$kind' — stopping $r" >&2; RC=1; break ;;
    esac
  done < "$W/plan"
done

echo
if [ "$HAVE_DISABLE" = 1 ] && [ "$FOUND" = 0 ]; then
  echo "✗ hardened-image-retire: no region holds an image named $DISABLE" >&2
  RC=1
fi
if [ "$ACTIONS" = 0 ]; then
  echo "Nothing to do."
elif [ "$APPLY" = 0 ]; then
  echo "Dry run — nothing was changed. Re-run with --apply to do the above."
fi
exit "$RC"
