#!/usr/bin/env bash
# scripts/hardened-image-retire.sh against a shimmed `aws`. Nothing here
# touches AWS. The shim:
#   sts get-caller-identity   Account ${RETIRE_ACCOUNT:-995603458290}
#   ec2 describe-images       prints $IMAGES_<region, dashes as underscores>,
#                             else no images; exits 254 for a region in $DESCRIBE_FAIL
#   ec2 enable-image-deprecation | deregister-image | delete-snapshot | disable-image
#                             log their arguments to mut.log, one line per call;
#                             exit 254 when "<region>:<verb>" is in $MUT_FAIL
# The clock is HARDENED_NOW. Fixtures are built by `imgs`, below.

# The checks read `[ … ]; echo $?` and `run_retire; check … "$?"` on purpose.
# shellcheck disable=SC2181,SC2319

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/r"
mkdir -p "$T/bin" "$R/scripts" "$R/image/hardened"
cp "$ROOT/scripts/hardened-image-retire.sh" "$R/scripts/" 2>/dev/null
printf '# Regions, one per line; the first is the build region.\n\nus-east-1\neu-west-1\n' > "$R/image/hardened/regions"

NOW=1795000000
DEPRECATE_AT=$(python3 -I -c 'import datetime, sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]) + 600, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$NOW")
PREFIX=idlefy-hardened-agent-ubuntu-24.04-amd64

cat > "$T/bin/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$AWS_LOG"
region=""; a=("$@")
for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" != --region ] || region=${a[i+1]}; done
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
case "$1 $2" in
  "sts get-caller-identity")
    printf '{"Account": "%s"}\n' "${RETIRE_ACCOUNT:-995603458290}" ;;
  "ec2 describe-images")
    if in_list "$region" "${DESCRIBE_FAIL:-}"; then echo "An error occurred (RequestLimitExceeded)" >&2; exit 254; fi
    var="IMAGES_${region//-/_}"; v="${!var:-}"
    [ -n "$v" ] || v='{"Images": []}'
    printf '%s\n' "$v" ;;
  "ec2 enable-image-deprecation"|"ec2 deregister-image"|"ec2 delete-snapshot"|"ec2 disable-image")
    shift
    echo "$*" >> "$MUT_LOG"
    if in_list "$region:$1" "${MUT_FAIL:-}"; then echo "An error occurred (InvalidAMIID.Unavailable)" >&2; exit 254; fi
    echo '{"Return": true}' ;;
  *) echo "shim: unexpected aws $*" >&2; exit 9 ;;
esac
SH
chmod +x "$T/bin/aws"

# imgs SPEC… — a describe-images answer. SPEC is
# ID:AGE_DAYS:PUBLIC[:DEPRECATED_DAYS_AGO[:NAME[:STATE]]]. DEPRECATED empty
# means what AWS does: a public image is deprecated 730 days after its creation
# (so its DeprecationTime is in the future), a private one has none; "none" means
# no DeprecationTime at all; a negative value is a deprecation still ahead. The
# name defaults to the build date's, NN 01; STATE defaults to available, and
# "disabled" also makes the image private; the snapshot is snap-<the id's hex>.
imgs() {
  python3 -I - "$NOW" "$PREFIX" "$@" <<'PY'
import datetime, json, sys
now, prefix = int(sys.argv[1]), sys.argv[2]
def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
out = []
for spec in sys.argv[3:]:
    f = spec.split(":") + [""] * 6
    iid, age, public, dep, name, state = f[0], float(f[1]), f[2] == "true", f[3], f[4], f[5] or "available"
    if state == "disabled":
        public = False
    created = now - int(age * 86400)
    if not name:
        name = "%s-%s-01" % (prefix, datetime.datetime.fromtimestamp(created, datetime.timezone.utc).strftime("%Y%m%d"))
    im = {"ImageId": iid, "Name": name, "Public": public, "State": state,
          "OwnerId": "995603458290", "CreationDate": iso(created),
          "BlockDeviceMappings": [{"DeviceName": "/dev/sda1",
                                   "Ebs": {"SnapshotId": "snap-" + iid.split("-", 1)[1], "VolumeSize": 20}}]}
    if dep == "" and public:
        im["DeprecationTime"] = iso(created + 730 * 86400)
    elif dep not in ("", "none"):
        im["DeprecationTime"] = iso(now - int(float(dep) * 86400))
    out.append(im)
print(json.dumps({"Images": out}))
PY
}
name_of() { python3 -I -c 'import json, sys
for i in json.loads(sys.argv[1])["Images"]:
    if i["ImageId"] == sys.argv[2]: print(i["Name"])' "$1" "$2"; }

# run_retire ARGS… — runs the script with the shim; returns its status.
run_retire() {
  : > "$T/aws.log"; : > "$T/mut.log"
  ( cd "$T" && env PATH="$T/bin:$PATH" AWS_LOG="$T/aws.log" MUT_LOG="$T/mut.log" HARDENED_NOW="${CLOCK:-$NOW}" \
      "$R/scripts/hardened-image-retire.sh" "$@" > "$T/stdout" 2> "$T/stderr" )
}
would() { grep -c '^would ' "$T/stdout"; }
mut() { grep -c . "$T/mut.log"; }
names() { grep -qF -- "$1" "$T/stdout" "$T/stderr"; }

echo "== three public builds, newest two 10 and 40 days old, third 70 =="
export IMAGES_us_east_1 IMAGES_eu_west_1
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true)
IMAGES_eu_west_1=$(imgs ami-0b1:10:true ami-0b2:40:true ami-0b3:70:true)
run_retire; check "dry run exits 0" "$?"
check "would deprecate the third, in us-east-1" "$([ "$(grep -cxF 'would deprecate ami-0a3 (us-east-1)' "$T/stdout")" = 1 ]; echo $?)"
check "would deprecate the third, in eu-west-1" "$([ "$(grep -cxF 'would deprecate ami-0b3 (eu-west-1)' "$T/stdout")" = 1 ]; echo $?)"
check "nothing else would happen" "$([ "$(would)" = 2 ]; echo $?)"
check "no mutation was called" "$([ "$(mut)" = 0 ]; echo $?)"
check "the plan names the kept builds" "$(grep -F 'ami-0a1' "$T/stdout" | grep -qF 'keep'; echo $?)"
check "says it was a dry run" "$(grep -qF -- '--apply' "$T/stdout"; echo $?)"
run_retire --apply; check "--apply exits 0" "$?"
check "deprecates ami-0a3 at now + 10 min, in us-east-1" \
  "$(grep -qxF "enable-image-deprecation --region us-east-1 --image-id ami-0a3 --deprecate-at $DEPRECATE_AT --output json" "$T/mut.log"; echo $?)"
check "deprecates ami-0b3 at now + 10 min, in eu-west-1" \
  "$(grep -qxF "enable-image-deprecation --region eu-west-1 --image-id ami-0b3 --deprecate-at $DEPRECATE_AT --output json" "$T/mut.log"; echo $?)"
check "and nothing else" "$([ "$(mut)" = 2 ]; echo $?)"

echo "== the newest public build is 3 days old =="
IMAGES_us_east_1=$(imgs ami-0a1:3:true ami-0a2:30:true)
IMAGES_eu_west_1=$(imgs ami-0b1:3:true ami-0b2:30:true ami-0b3:60:true)
run_retire --apply; check "exit 0" "$?"
check "nothing would happen, in either region" "$([ "$(would)" = 0 ] && [ "$(mut)" = 0 ]; echo $?)"
check "says why: the current build is too young" "$(grep -F 'eu-west-1' "$T/stdout" | grep -qF '7 days'; echo $?)"

echo "== a build deprecated 8 days ago =="
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true:8)
IMAGES_eu_west_1=$(imgs ami-0b1:10:true ami-0b2:40:true ami-0b3:70:true:8)
run_retire; check "dry run exits 0" "$?"
for x in "ami-0a3 (us-east-1)" "ami-0b3 (eu-west-1)"; do
  check "would deregister $x" "$(grep -qxF "would deregister $x" "$T/stdout"; echo $?)"
done
check "would delete-snapshot snap-0a3 (us-east-1)" "$(grep -qxF 'would delete-snapshot snap-0a3 (us-east-1)' "$T/stdout"; echo $?)"
check "would delete-snapshot snap-0b3 (eu-west-1)" "$(grep -qxF 'would delete-snapshot snap-0b3 (eu-west-1)' "$T/stdout"; echo $?)"
check "nothing else would happen, no mutation" "$([ "$(would)" = 4 ] && [ "$(mut)" = 0 ]; echo $?)"
run_retire --apply; check "--apply exits 0" "$?"
check "us-east-1: deregisters, then deletes the snapshot" "$(grep -F -- '--region us-east-1' "$T/mut.log" | cut -d' ' -f1 | tr '\n' ' ' | grep -qxF 'deregister-image delete-snapshot '; echo $?)"
check "deregister names the image" "$(grep -qxF 'deregister-image --region us-east-1 --image-id ami-0a3 --output json' "$T/mut.log"; echo $?)"
check "delete-snapshot names its snapshot" "$(grep -qxF 'delete-snapshot --region us-east-1 --snapshot-id snap-0a3 --output json' "$T/mut.log"; echo $?)"
check "four calls in all" "$([ "$(mut)" = 4 ]; echo $?)"

echo "== every snapshot of the image, after the deregistration =="
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true:8 \
  | python3 -I -c 'import json, sys
d = json.load(sys.stdin)
d["Images"][2]["BlockDeviceMappings"].append({"DeviceName": "/dev/sdb", "Ebs": {"SnapshotId": "snap-0a3b"}})
d["Images"][2]["BlockDeviceMappings"].append({"DeviceName": "/dev/sdc", "VirtualName": "ephemeral0"})
print(json.dumps(d))')
IMAGES_eu_west_1=""
run_retire --apply; check "exit 0" "$?"
check "deregister first, then both snapshots" \
  "$(cut -d' ' -f1,5 "$T/mut.log" | tr '\n' ' ' | grep -qxF 'deregister-image ami-0a3 delete-snapshot snap-0a3 delete-snapshot snap-0a3b '; echo $?)"

echo "== a build deprecated 2 days ago =="
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true:2)
IMAGES_eu_west_1=$(imgs ami-0b1:10:true ami-0b2:40:true ami-0b3:70:true:2)
run_retire --apply; check "exit 0" "$?"
check "nothing happens" "$([ "$(would)" = 0 ] && [ "$(mut)" = 0 ]; echo $?)"

echo "== a future DeprecationTime is not a deprecation =="
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true:-0.005)
IMAGES_eu_west_1=$(imgs ami-0b1:10:true ami-0b2:40:true ami-0b3:70:true:-730)
run_retire --apply; check "exit 0" "$?"
check "scheduled within 10 minutes (an earlier run's): waits, no call" \
  "$(! grep -qF -- '--region us-east-1' "$T/mut.log" && grep -F 'ami-0a3' "$T/stdout" | grep -qF 'deprecation pending'; echo $?)"
check "scheduled 2 years ahead on a superseded build: deprecated now" \
  "$(grep -qxF "enable-image-deprecation --region eu-west-1 --image-id ami-0b3 --deprecate-at $DEPRECATE_AT --output json" "$T/mut.log" && [ "$(mut)" = 1 ]; echo $?)"
IMAGES_us_east_1=$(imgs ami-0a1:10:true:none ami-0a2:40:true:none ami-0a3:70:true:none)
IMAGES_eu_west_1=""
run_retire; check "no DeprecationTime at all: the third would be deprecated" \
  "$([ $? -eq 0 ] && grep -qxF 'would deprecate ami-0a3 (us-east-1)' "$T/stdout" && [ "$(would)" = 1 ]; echo $?)"

echo "== one of the newest two public builds is past its deprecation date =="
IMAGES_us_east_1=$(imgs ami-0a1:740:true ami-0a2:800:true ami-0a3:900:true:100)
IMAGES_eu_west_1=$(imgs ami-0b1:10:true ami-0b2:740:true ami-0b3:800:true)
run_retire --apply; check "exit 1" "$([ $? -eq 1 ]; echo $?)"
check "nothing is done in either region" "$([ "$(mut)" = 0 ]; echo $?)"
check "us-east-1 is flagged: publish a new build" \
  "$(grep -F 'us-east-1' "$T/stderr" | grep -F 'ami-0a1' | grep -qF 'publish a new build'; echo $?)"
check "eu-west-1 is flagged for the previous build" "$(grep -F 'eu-west-1' "$T/stderr" | grep -qF 'ami-0b2'; echo $?)"
check "--help states the rule" "$(run_retire --help; grep -qF 'never' "$T/stdout" && grep -qF 'deregistered' "$T/stdout" && grep -qiF 'two-year' "$T/stdout"; echo $?)"

echo "== disabled builds (a yank) =="
IMAGES_us_east_1=$(imgs "ami-0a9:10:false:none:$PREFIX-20991231-01:disabled" ami-0a1:10:true ami-0a2:40:true \
  "ami-0a7:20:false:none:$PREFIX-20000102-01:disabled" "ami-0a8:5:false:none:$PREFIX-20000101-01:disabled")
IMAGES_eu_west_1=""
run_retire; check "exit 0" "$?"
check "a disabled build among the newest two waits" "$(grep -F 'ami-0a9' "$T/stdout" | grep -qF 'waits'; echo $?)"
check "the two public builds are kept" "$(grep -F 'ami-0a1' "$T/stdout" | grep -qF 'keep' && grep -F 'ami-0a2' "$T/stdout" | grep -qF 'keep'; echo $?)"
check "an older disabled build 20 days old would be deregistered, with its snapshot" \
  "$(grep -qxF 'would deregister ami-0a7 (us-east-1)' "$T/stdout" && grep -qxF 'would delete-snapshot snap-0a7 (us-east-1)' "$T/stdout"; echo $?)"
check "an older disabled build 5 days old waits" "$(grep -F 'ami-0a8' "$T/stdout" | grep -qF 'waits'; echo $?)"
check "nothing else" "$([ "$(would)" = 2 ]; echo $?)"
run_retire --apply; check "--apply deregisters, then deletes the snapshot, and nothing else" \
  "$([ $? -eq 0 ] && cut -d' ' -f1,5 "$T/mut.log" | tr '\n' ' ' | grep -qxF 'deregister-image ami-0a7 delete-snapshot snap-0a7 '; echo $?)"

echo "== a snapshot delete fails after the deregistration =="
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true:8 \
  | python3 -I -c 'import json, sys
d = json.load(sys.stdin)
d["Images"][2]["BlockDeviceMappings"].append({"DeviceName": "/dev/sdb", "Ebs": {"SnapshotId": "snap-0a3b"}})
print(json.dumps(d))')
MUT_FAIL="us-east-1:delete-snapshot" run_retire --apply; check "exit non-zero" "$([ $? -ne 0 ]; echo $?)"
check "names the region and every snapshot left behind" \
  "$(grep -F 'us-east-1' "$T/stderr" | grep -F 'snap-0a3 snap-0a3b' | grep -qF 'by hand'; echo $?)"

echo "== private builds =="
IMAGES_us_east_1=$(imgs ami-0a1:8:false)
IMAGES_eu_west_1=$(imgs ami-0b1:3:false)
run_retire; check "exit 0" "$?"
check "a private build 8 days old with no public build → would deprecate" "$(grep -qxF 'would deprecate ami-0a1 (us-east-1)' "$T/stdout"; echo $?)"
check "a private build 3 days old → nothing" "$(grep -F 'ami-0b1' "$T/stdout" | grep -q '^would '; [ $? -ne 0 ]; echo $?)"
check "one would-line in all" "$([ "$(would)" = 1 ]; echo $?)"
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a9:1:false)
IMAGES_eu_west_1=""
run_retire; check "a private build newer than the current public one waits for its own 7 days" \
  "$([ $? -eq 0 ] && [ "$(would)" = 0 ]; echo $?)"

echo "== the newest two public builds are never named, whatever their age =="
IMAGES_us_east_1=$(imgs ami-0a1:300:true ami-0a2:400:true ami-0a3:500:true ami-0a4:600:true:30 ami-0a5:900:false)
IMAGES_eu_west_1=$(imgs ami-0b1:300:true ami-0b2:400:true)
run_retire; check "exit 0" "$?"
for x in ami-0a1 ami-0a2 ami-0b1 ami-0b2; do
  check "$x is in no would-line" "$(grep '^would ' "$T/stdout" | grep -qF "$x"; [ $? -ne 0 ]; echo $?)"
done
check "the older ones are" "$(grep -qxF 'would deprecate ami-0a3 (us-east-1)' "$T/stdout" \
  && grep -qxF 'would deregister ami-0a4 (us-east-1)' "$T/stdout" && grep -qxF 'would deprecate ami-0a5 (us-east-1)' "$T/stdout"; echo $?)"
# Name order, not creation time, decides which two are newest.
IMAGES_us_east_1=$(imgs "ami-0a1:300:true::$PREFIX-20260101-02" "ami-0a2:10:true::$PREFIX-20260101-01" "ami-0a3:5:true::$PREFIX-20250101-01")
IMAGES_eu_west_1=""
run_retire; check "the two newest by name are kept, even when an older name is younger" \
  "$([ $? -eq 0 ] && grep -qxF 'would deprecate ami-0a3 (us-east-1)' "$T/stdout" && [ "$(would)" = 1 ]; echo $?)"

echo "== seven days is the line =="
IMAGES_us_east_1=$(imgs ami-0a1:6.9:true ami-0a2:40:true ami-0a3:70:true ami-0a4:80:true:6.9 "ami-0a5:6.9:false::$PREFIX-20000101-01")
IMAGES_eu_west_1=$(imgs ami-0b1:7:true ami-0b2:40:true ami-0b3:70:true ami-0b4:80:true:7 "ami-0b5:7:false::$PREFIX-20000101-01")
run_retire; check "exit 0" "$?"
check "us-east-1 was planned, not left alone" "$(grep -qF 'us-east-1' "$T/stderr"; [ $? -ne 0 ]; echo $?)"
check "just under 7 days: nothing in us-east-1" "$(grep '^would ' "$T/stdout" | grep -qF 'us-east-1'; [ $? -ne 0 ]; echo $?)"
check "7 days: deprecate, deregister and deprecate the private one in eu-west-1" \
  "$(grep -qxF 'would deprecate ami-0b3 (eu-west-1)' "$T/stdout" && grep -qxF 'would deregister ami-0b4 (eu-west-1)' "$T/stdout" \
     && grep -qxF 'would deprecate ami-0b5 (eu-west-1)' "$T/stdout"; echo $?)"

echo "== a deprecated build is never one of the two kept =="
# Two yanked builds are the newest two; behind them a public build deprecated
# 8 days ago, then three live ones.
IMAGES_us_east_1=$(imgs "ami-0a8:3:false:none:$PREFIX-20991231-02:disabled" "ami-0a9:3:false:none:$PREFIX-20991231-01:disabled" \
  ami-0a1:10:true:8 ami-0a2:40:true ami-0a3:70:true ami-0a4:100:true)
IMAGES_eu_west_1=""
run_retire; check "exit 0" "$?"
check "the two newest live public builds are kept; the deprecated one is deregistered, the next deprecated" \
  "$(grep -qxF 'would deregister ami-0a1 (us-east-1)' "$T/stdout" && grep -qxF 'would deprecate ami-0a4 (us-east-1)' "$T/stdout" \
     && grep -F 'ami-0a2' "$T/stdout" | grep -qF 'keep' && grep -F 'ami-0a3' "$T/stdout" | grep -qF 'keep'; echo $?)"

echo "== --disable =="
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true)
IMAGES_eu_west_1=$(imgs ami-0b1:10:true ami-0b2:40:true ami-0b3:70:true)
N1=$(name_of "$IMAGES_us_east_1" ami-0a1)
run_retire --disable "$N1"; check "dry run exits 0" "$?"
check "would disable it in us-east-1" "$(grep -qxF 'would disable ami-0a1 (us-east-1)' "$T/stdout"; echo $?)"
check "would disable it in eu-west-1" "$(grep -qxF 'would disable ami-0b1 (eu-west-1)' "$T/stdout"; echo $?)"
check "no retention mixed in, no mutation" "$([ "$(would)" = 2 ] && [ "$(mut)" = 0 ]; echo $?)"
run_retire --disable "$N1" --apply; check "--apply exits 0" "$?"
check "disable-image in us-east-1" "$(grep -qxF 'disable-image --region us-east-1 --image-id ami-0a1 --output json' "$T/mut.log"; echo $?)"
check "disable-image in eu-west-1" "$(grep -qxF 'disable-image --region eu-west-1 --image-id ami-0b1 --output json' "$T/mut.log"; echo $?)"
check "nothing else" "$([ "$(mut)" = 2 ]; echo $?)"
IMAGES_eu_west_1=$(imgs ami-0b2:40:true ami-0b3:70:true)
run_retire --apply --disable "$N1"; check "a region without the name is skipped" \
  "$([ $? -eq 0 ] && [ "$(mut)" = 1 ] && grep -F 'eu-west-1' "$T/stdout" | grep -qF "no image named $N1"; echo $?)"
IMAGES_eu_west_1=$(imgs "ami-0b1:10:true::$N1:disabled" ami-0b2:40:true)
run_retire --apply --disable "$N1"; check "an already disabled one is said so and left be" \
  "$([ $? -eq 0 ] && [ "$(mut)" = 1 ] && grep -F 'eu-west-1' "$T/stdout" | grep -qF 'already disabled'; echo $?)"
run_retire --disable "$PREFIX-19990101-01" --apply; check "a name in no region → exit 1, nothing disabled" \
  "$([ $? -eq 1 ] && [ "$(mut)" = 0 ]; echo $?)"
run_retire --disable "ubuntu-24.04-something" --apply; check "a name outside the pattern → refused before any aws call" \
  "$([ $? -ne 0 ] && [ ! -s "$T/aws.log" ]; echo $?)"
run_retire --disable; check "--disable without a name → refused" "$([ $? -ne 0 ] && [ ! -s "$T/aws.log" ]; echo $?)"
run_retire --help; check "--help exits 0 and says the consumer's pin goes first" \
  "$([ $? -eq 0 ] && grep -qiF 'costpilot' "$T/stdout" && [ ! -s "$T/aws.log" ]; echo $?)"
run_retire --force; check "an unknown argument → refused" "$([ $? -ne 0 ] && [ ! -s "$T/aws.log" ]; echo $?)"

echo "== a region with no images =="
IMAGES_us_east_1=$(imgs ami-0a1:10:true)
IMAGES_eu_west_1=""
run_retire --apply; check "exit 0" "$?"
check "says eu-west-1: no published images" "$(grep -qxF 'eu-west-1: no published images' "$T/stdout"; echo $?)"

echo "== what describe-images asks for =="
check "owners self, deprecated included, both filters, every region" \
  "$([ "$(grep -F 'ec2 describe-images' "$T/aws.log" | grep -F -- '--owners self' | grep -F -- '--include-deprecated' | grep -F -- '--include-disabled' \
      | grep -F -- 'Name=tag:IdlefyPublishedImage,Values=true' | grep -cF -- "Name=name,Values=$PREFIX-*")" = 2 ]; echo $?)"

echo "== an AWS call fails =="
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true:8 ami-0a4:80:true)
IMAGES_eu_west_1=$(imgs ami-0b1:10:true ami-0b2:40:true ami-0b3:70:true:8)
MUT_FAIL="us-east-1:deregister-image" run_retire --apply; check "exit non-zero" "$([ $? -ne 0 ]; echo $?)"
check "no snapshot deleted and nothing more done in us-east-1" \
  "$([ "$(grep -cF -- '--region us-east-1' "$T/mut.log")" = 2 ] \
     && grep -F -- '--region us-east-1' "$T/mut.log" | tail -1 | grep -q '^deregister-image'; echo $?)"
check "eu-west-1 still done" "$(grep -qxF 'delete-snapshot --region eu-west-1 --snapshot-id snap-0b3 --output json' "$T/mut.log"; echo $?)"
check "names the failure" "$(grep -F 'us-east-1' "$T/stderr" | grep -qF 'deregister-image'; echo $?)"
MUT_FAIL="us-east-1:enable-image-deprecation" run_retire --apply
check "a failed deprecation stops us-east-1 before its deregistration" \
  "$([ $? -ne 0 ] && [ "$(grep -cF -- '--region us-east-1' "$T/mut.log")" = 1 ]; echo $?)"
DESCRIBE_FAIL=us-east-1 run_retire --apply; check "a failed listing → exit non-zero" "$([ $? -ne 0 ]; echo $?)"
check "…nothing in us-east-1, eu-west-1 still done" \
  "$(! grep -qF -- '--region us-east-1' "$T/mut.log" && grep -qF -- '--region eu-west-1' "$T/mut.log"; echo $?)"

echo "== when in doubt, nothing is done in that region =="
IMAGES_eu_west_1=$(imgs ami-0b1:10:true ami-0b2:40:true ami-0b3:70:true:8)
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true "ami-0a4:5:true::$PREFIX-latest")
run_retire --apply; check "a name outside the pattern → exit 1" "$([ $? -eq 1 ]; echo $?)"
check "…nothing in us-east-1, says why" \
  "$(! grep -qF -- '--region us-east-1' "$T/mut.log" && grep -F 'us-east-1' "$T/stderr" | grep -qF "$PREFIX-latest"; echo $?)"
check "…eu-west-1 still done" "$(grep -qF -- '--region eu-west-1' "$T/mut.log"; echo $?)"
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true "ami-0a3:70:true::$PREFIX-20260101-01" "ami-0a4:70:true::$PREFIX-20260101-01")
run_retire --apply; check "a name twice → exit 1, nothing in us-east-1" \
  "$([ $? -eq 1 ] && ! grep -qF -- '--region us-east-1' "$T/mut.log"; echo $?)"
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true \
  | python3 -I -c 'import json, sys; d = json.load(sys.stdin); d["Images"][2]["CreationDate"] = "yesterday"; print(json.dumps(d))')
run_retire --apply; check "an unreadable date → exit 1, nothing in us-east-1" \
  "$([ $? -eq 1 ] && ! grep -qF -- '--region us-east-1' "$T/mut.log"; echo $?)"
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true:8 \
  | python3 -I -c 'import json, sys; d = json.load(sys.stdin); d["Images"][2]["BlockDeviceMappings"] = []; print(json.dumps(d))')
run_retire --apply; check "a deregistration candidate with no snapshot → exit 1, nothing in us-east-1" \
  "$([ $? -eq 1 ] && ! grep -qF -- '--region us-east-1' "$T/mut.log"; echo $?)"
IMAGES_us_east_1='not json'
run_retire --apply; check "an unreadable answer → exit 1, nothing in us-east-1" \
  "$([ $? -eq 1 ] && ! grep -qF -- '--region us-east-1' "$T/mut.log"; echo $?)"

echo "== the wrong account =="
IMAGES_us_east_1=$(imgs ami-0a1:10:true ami-0a2:40:true ami-0a3:70:true)
RETIRE_ACCOUNT=111111111111 run_retire --apply; check "exit 1, nothing listed or changed" \
  "$([ $? -eq 1 ] && ! grep -qF 'describe-images' "$T/aws.log" && [ "$(mut)" = 0 ]; echo $?)"
CLOCK=yesterday run_retire; check "a HARDENED_NOW that is not an epoch → refused before any aws call" \
  "$([ $? -ne 0 ] && [ ! -s "$T/aws.log" ]; echo $?)"

echo "== the real regions file parses =="
cp "$R/image/hardened/regions" "$T/regions.orig"
cp "$ROOT/image/hardened/regions" "$R/image/hardened/regions"
run_retire; check "exit 0" "$?"
check "every region of it is listed" \
  "$([ "$(grep -cF 'ec2 describe-images' "$T/aws.log")" = "$(grep -cv '^[[:space:]]*\(#\|$\)' "$ROOT/image/hardened/regions")" ]; echo $?)"
cp "$T/regions.orig" "$R/image/hardened/regions"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
