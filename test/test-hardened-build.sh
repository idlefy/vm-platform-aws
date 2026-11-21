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
#           it; download returns $GH_STORED, else what was uploaded (other
#           bytes when ${GH_DOWNLOAD_CORRUPT}), else fails;
#           api …/git/ref/tags/<tag> fails when ${GH_BASE_TAG_MISSING}.
#   aws     sts get-caller-identity prints ${AWS_ACCOUNT:-995603458290}, or
#           fails with AWS's error text when ${STS_FAIL};
#           describe-images … Images[].Name prints ${EXISTING_NAMES_<region>}
#           (dashes as underscores), else ${EXISTING_NAMES}, tab-separated, and
#           fails in ${NAMES_FAIL_REGION}; describe-images by exact name (the
#           leftover listing) prints ${LEFTOVER_<region>}, else no images, and
#           fails in ${LEFTOVER_FAIL}.
#   gh      also: the record upload fails when ${GH_RECORD_UPLOAD_FAIL}, the
#           notes edit when ${GH_NOTES_FAIL}.
#   aws     ec2 get-console-output prints ${CONSOLE_OUTPUT} (printf %b), or
#           fails when ${CONSOLE_FAIL}, hangs when ${CONSOLE_HANG}; describe-instances answers
#           ${BUILD_INSTANCES} ("i-…:state …"), describe-key-pairs ${BUILD_KEYS}
#           (names); terminate-instances and delete-key-pair succeed unless
#           ${TERMINATE_FAIL} / ${DELETEKEY_FAIL}; ${INSTANCES_FAIL} and
#           ${KEYS_FAIL} fail the two reads.
#   packer  build copies the user data and reports an AMI for each region in
#           ${ARTIFACT_REGIONS:-every region of ami_regions}; exits ${PACKER_RC:-0}.
#           With ${PACKER_HOLD} it names its instance, then runs that many
#           seconds unless SIGINT ends it ("interrupted" in its log).
#           `packer build` runs as Packer 1.11 does under panicwrap: a wrapper
#           that catches and swallows SIGINT and forwards only SIGTERM, and a
#           child that does the work; both pids go to ${PACKER_PIDS}.
# The last section measures the real solo user data against EC2's 16 KB.

# The checks read `[ … ]; echo $?` and `run_build; check … "$?"` on purpose: the
# status of that condition, or of that run, is the thing being checked.
# shellcheck disable=SC2181,SC2319

# -e for the setup only: a failed copy or shim must stop the run before
# any script runs. The checks below run without it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/r"
mkdir -p "$T/bin" "$T/state" "$R/scripts" "$R/image" "$R/cinc/policyfiles" "$R/cinc/cookbooks/base"
cp "$ROOT/scripts/hardened-image-build.sh" "$ROOT/scripts/hardened-image-leftovers.sh" "$ROOT/scripts/hardened-guard-check.sh" "$R/scripts/"
cp -R "$ROOT/image/hardened" "$ROOT/image/files" "$R/image/"
cp "$ROOT/cinc/policyfiles/solo.rb" "$R/cinc/policyfiles/solo.rb"
printf "name 'base'\nversion '2.1.0'\n" > "$R/cinc/cookbooks/base/metadata.rb"

REV=$(printf 'rev' | sha256sum | cut -d' ' -f1)
OTHERREV=$(printf 'other' | sha256sum | cut -d' ' -f1)
SHA=$(printf 'c%.0s' {1..40})
# Fixed, and passed as HARDENED_TODAY: a run that crosses UTC midnight must
# not change the expected names.
DATE=20261101
SG=sg-0f0f0f0f0f0f0f0f0
URL=https://github.com/idlefy/vm-platform-aws/releases/download/v2.2.0/solo-v2.2.0.tgz
printf '{"name":"solo","revision_id":"%s","cookbook_locks":{"base":{"version":"2.1.0"}}}' "$REV" \
  > "$R/cinc/policyfiles/solo.lock.json"
# The driver's behaviour is tested on a fixed list of the 17 default-enabled
# commercial regions (build region first), not on the repository's own list;
# the real file is pinned below.
printf '# test fixture\n%s\n' us-east-1 us-east-2 us-west-1 us-west-2 ca-central-1 eu-central-1 eu-west-1 eu-west-2 \
  eu-west-3 eu-north-1 ap-south-1 ap-northeast-1 ap-northeast-2 ap-northeast-3 ap-southeast-1 ap-southeast-2 \
  sa-east-1 > "$R/image/hardened/regions"
mapfile -t REGIONS < <(grep -v '^[[:space:]]*\(#\|$\)' "$R/image/hardened/regions")
# The repository's list: us-east-1, the build region, then eu-central-1 and
# the other published regions.
mapfile -t REAL_REGIONS < <(grep -v '^[[:space:]]*\(#\|$\)' "$ROOT/image/hardened/regions")
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
echo "gh $1 ${2:-}" >> "$ORDER_LOG"
case "$1" in api) echo "${2%%/git/*}" ;; *) echo "$repo" ;; esac >> "$GH_LOG.repo"
case "$1 ${2:-}" in
  "release view")
    if [ -n "${GH_RELEASE_MISSING:-}" ] && [ ! -e "$GH_STATE/created" ]; then exit 1; fi
    case " $* " in *" --json body "*) printf 'Existing notes.\n' ;; esac ;;
  "release create") : > "$GH_STATE/created" ;;
  "release upload")
    case "$4" in *hardened-ami-*.json) [ -z "${GH_RECORD_UPLOAD_FAIL:-}" ] || exit 1 ;; esac
    cp "$4" "$GH_STATE/" ;;
  "release download")
    pat="" out=""
    while [ $# -gt 0 ]; do case "$1" in --pattern) pat=$2; shift ;; -O) out=$2; shift ;; esac; shift; done
    if [ -n "${GH_STORED:-}" ]; then cp "$GH_STORED" "$out"
    elif [ -f "$GH_STATE/$pat" ] && [ -n "${GH_DOWNLOAD_CORRUPT:-}" ]; then cp "$OTHER_TGZ" "$out"
    elif [ -f "$GH_STATE/$pat" ]; then cp "$GH_STATE/$pat" "$out"
    else exit 1; fi ;;
  "release edit")
    [ -z "${GH_NOTES_FAIL:-}" ] || exit 1
    while [ $# -gt 0 ]; do [ "$1" = --notes-file ] && cp "$2" "$GH_STATE/notes"; shift; done ;;
  api\ repos/*/git/ref/tags/*) [ -z "${GH_BASE_TAG_MISSING:-}" ] || exit 1; echo '{"ref":"x"}' ;;
  *) exit 9 ;;
esac
SH
cat > "$T/bin/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$AWS_LOG"
echo "aws $1 $2" >> "$ORDER_LOG"
case "$1 $2" in
  "sts get-caller-identity")
    if [ -n "${STS_FAIL:-}" ]; then echo "An error occurred (ExpiredToken) when calling the GetCallerIdentity operation: expired" >&2; exit 254; fi
    echo "${AWS_ACCOUNT:-995603458290}" ;;
  "ec2 describe-images")
    region=""; a=("$@")
    for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" != --region ] || region=${a[i+1]}; done
    case " $* " in
      *" --query "*)
        if [ "$region" = "${NAMES_FAIL_REGION:-}" ]; then echo "An error occurred (UnauthorizedOperation) in $region" >&2; exit 254; fi
        var="EXISTING_NAMES_${region//-/_}"; names="${!var-${EXISTING_NAMES:-}}"
        printf '%s\n' "$(printf '%s\t' $names | sed 's/\t$//')" ;;
      *)
        if [ "$region" = "${LEFTOVER_FAIL:-}" ]; then echo "An error occurred (RequestLimitExceeded) in $region" >&2; exit 254; fi
        var="LEFTOVER_${region//-/_}"; v="${!var:-}"
        [ -n "$v" ] || v='{"Images": []}'
        printf '%s\n' "$v" ;;
    esac ;;
  "ec2 describe-instances")
    [ -z "${INSTANCES_FAIL:-}" ] || { echo "An error occurred (UnauthorizedOperation) when calling the DescribeInstances operation" >&2; exit 254; }
    # INSTANCES_LATE=N: the first N listings come back empty (an instance
    # just launched, not listable yet); counted in $AWS_LOG.n.
    if [ -n "${INSTANCES_LATE:-}" ]; then
      c=$(( $(cat "$AWS_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$AWS_LOG.n"
      [ "$c" -gt "$INSTANCES_LATE" ] || { echo '{"Reservations": []}'; exit 0; }
    fi
    python3 -I -c 'import json, sys
print(json.dumps({"Reservations": [{"Instances": [{"InstanceId": x.split(":")[0], "State": {"Name": x.split(":")[1]}}
                                                  for x in sys.argv[1].split()]}]}))' "${BUILD_INSTANCES:-}" ;;
  "ec2 describe-key-pairs")
    [ -z "${KEYS_FAIL:-}" ] || { echo "An error occurred (UnauthorizedOperation) when calling the DescribeKeyPairs operation" >&2; exit 254; }
    python3 -I -c 'import json, sys
print(json.dumps({"KeyPairs": [{"KeyName": k, "KeyPairId": "key-0%d" % n} for n, k in enumerate(sys.argv[1].split())]}))' "${BUILD_KEYS:-}" ;;
  "ec2 terminate-instances")
    [ -z "${TERMINATE_FAIL:-}" ] || { echo "An error occurred (UnauthorizedOperation) when calling the TerminateInstances operation" >&2; exit 254; }
    echo '{}' ;;
  "ec2 delete-key-pair")
    [ -z "${DELETEKEY_FAIL:-}" ] || { echo "An error occurred (UnauthorizedOperation) when calling the DeleteKeyPair operation" >&2; exit 254; }
    echo '{}' ;;
  "ec2 get-console-output")
    if [ -n "${CONSOLE_FAIL:-}" ]; then echo "An error occurred (UnauthorizedOperation) when calling the GetConsoleOutput operation" >&2; exit 254; fi
    # A read that hangs, as a stalled API call does.
    [ -z "${CONSOLE_HANG:-}" ] || exec sleep 600
    printf '%b\n' "${CONSOLE_OUTPUT:-}" ;;
  *) exit 9 ;;
esac
SH
# The panicwrap stand-in (panicwrap v1.0.0 Wrap with Packer's config: SIGINT
# is caught and dropped in the wrapper, SIGTERM is forwarded to the child).
cat > "$T/packer-wrap.py" <<'PY'
import os, signal, subprocess, sys
signal.signal(signal.SIGINT, lambda *_: None)
child = subprocess.Popen(sys.argv[1:], env=dict(os.environ, PACKER_CHILD="1"))
signal.signal(signal.SIGTERM, lambda *_: child.send_signal(signal.SIGTERM))
with open(os.environ["PACKER_PIDS"], "a") as f:
    f.write("%d\n%d\n" % (os.getpid(), child.pid))
rc = child.wait()
sys.exit(rc if rc >= 0 else 128 - rc)
PY
cat > "$T/bin/packer" <<'SH'
#!/usr/bin/env bash
if [ "$1" = build ] && [ -z "${PACKER_CHILD:-}" ]; then exec python3 -I "$PACKER_WRAP" "$0" "$@"; fi
echo "packer $1" >> "$ORDER_LOG"
if [ "$1" = init ]; then echo "init $2" >> "$PACKER_LOG"; exit 0; fi
printf '%s\n' "$@" >> "$PACKER_LOG"
# A long build, to be signalled: says it started, then sleeps.
if [ -n "${PACKER_SLEEP:-}" ]; then : > "$PACKER_STARTED"; sleep "$PACKER_SLEEP"; fi
# PACKER_HOLD=N: installs its interrupt handler, writes "packer ready" to
# its log, names its instance as Packer does, then runs N seconds; an
# interrupt (SIGINT, as the console watcher sends) ends it as Packer's does.
# The readiness line comes after the handler, so a test that signals on it
# never hits the instant before the handler exists.
if [ -n "${PACKER_HOLD:-}" ]; then
  # PACKER_INT_OK: a Packer that takes the interrupt, yet reports a complete
  # artifact and exits 0 — the driver must still fail on what it saw.
  if [ -n "${PACKER_INT_OK:-}" ]; then
    trap 'echo interrupted >> "$PACKER_LOG"; end=0' INT
  else
    # Its clean-up (terminating the instance) takes a while; the driver must
    # wait for it before it lists leftovers.
    trap 'echo interrupted >> "$PACKER_LOG"; echo "1697000002,,ui,error,Build was cancelled."; sleep "${PACKER_CLEANUP:-1}"; echo "packer cleaned-up" >> "$ORDER_LOG"; exit 1' INT
  fi
  # PACKER_STUCK: a clean-up that never ends (a stalled plugin): the interrupt
  # is noted and the worker runs on.
  [ -z "${PACKER_STUCK:-}" ] || trap 'echo interrupted >> "$PACKER_LOG"' INT
  echo "packer ready" >> "$PACKER_LOG"
  echo '1697000000,,ui,message,    amazon-ebs.hardened: Instance ID: i-0123456789abcdef0'
  end=$((SECONDS + PACKER_HOLD))
  while [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done
fi
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
# No test may reach a real cloud CLI: each name below must resolve to its
# shim, or the run stops here.
shimmed() {
  local dir=$1 c; shift
  for c in "$@"; do
    [ "$(PATH="$dir:$PATH" command -v "$c")" = "$dir/$c" ] \
      || { echo "setup: $c does not resolve to the shim in $dir — stopping" >&2; exit 1; }
  done
}
shimmed "$T/bin" aws gh packer chef
set +e

# run_build — runs the driver with the shims; returns its status.
run_build() {
  shimmed "$T/bin" aws gh packer chef
  rm -rf "$T/state" "$T/out" "$T/ud.gz" "$T/packer.pids"; mkdir -p "$T/state"
  : > "$T/chef.log"; : > "$T/gh.log"; : > "$T/gh.log.repo"; : > "$T/aws.log"; : > "$T/packer.log"; : > "$T/order.log"
  local e=(PATH="$T/bin:$PATH" CHEF_LOG="$T/chef.log" GH_LOG="$T/gh.log" AWS_LOG="$T/aws.log"
           PACKER_LOG="$T/packer.log" ORDER_LOG="$T/order.log" PACKER_WRAP="$T/packer-wrap.py" PACKER_PIDS="$T/packer.pids" UD_COPY="$T/ud.gz" GH_STATE="$T/state"
           EXPORT_TREE="${EXPORT_TREE:-$T/tree-a}" REV="$REV"
           PLATFORM_TAG="${PLATFORM_TAG-v2.2.0}" PLATFORM_SHA="${PLATFORM_SHA-$SHA}"
           HARDENED_SKIP_TAG_CHECK="${SKIP_TAG-1}" HARDENED_OUT="$T/out" OTHER_TGZ="$T/other.tgz")
  [ -n "${NO_TODAY:-}" ] || e+=(HARDENED_TODAY="${TODAY:-$DATE}")
  [ -n "${NO_SG:-}" ] || e+=(HARDENED_SECURITY_GROUP_ID="$SG")
  [ -z "${PUBLIC:-}" ] || e+=(HARDENED_PUBLIC="$PUBLIC")
  [ -z "${ORG:-}" ] || e+=(HARDENED_ATTACHED_ORG_ID="$ORG")
  local rc
  if [ -n "${SIG_EARLY:-}" ]; then
    # SIGINT (a Ctrl-C) or SIGTERM (a runner's cancel) to the driver's whole
    # session once ${SIG_WHEN:-^packer ready$} shows in ${SIG_LOG:-packer.log} —
    # by default once Packer's interrupt handler is installed. Packer runs in a session of its
    # own, so only the driver can pass it on. The wrapper resets SIGINT to its
    # default: a backgrounded bash would hand the driver an ignored SIGINT.
    ( cd "$T" && exec python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
        env -u HARDENED_SECURITY_GROUP_ID -u HARDENED_PUBLIC -u HARDENED_ATTACHED_ORG_ID \
        -u HARDENED_SUBNET_ID -u HARDENED_INSTANCE_TYPE -u GH_REPO "${e[@]}" \
        "$R/scripts/hardened-image-build.sh" > "$T/stdout" 2> "$T/stderr" ) &
    local pid=$! n=0
    while ! grep -q "${SIG_WHEN:-^packer ready\$}" "$T/${SIG_LOG:-packer.log}" && [ $n -lt 600 ]; do sleep 0.05; n=$((n+1)); done
    kill -"$SIG_EARLY" -- "-$pid" 2>/dev/null
    # SIG_THEN: a second signal SIG_GAP seconds later, as a runner sends TERM
    # 7.5 s after its INT.
    [ -z "${SIG_THEN:-}" ] || { sleep "${SIG_GAP:-0.5}"; kill -"$SIG_THEN" -- "-$pid" 2>/dev/null; }
    wait "$pid"; rc=$?
    SESSION=$pid
  elif [ -z "${TERM_MID_PACKER:-}" ]; then
    ( cd "$T" && env -u HARDENED_SECURITY_GROUP_ID -u HARDENED_PUBLIC -u HARDENED_ATTACHED_ORG_ID \
        -u HARDENED_SUBNET_ID -u HARDENED_INSTANCE_TYPE -u GH_REPO "${e[@]}" \
        "$R/scripts/hardened-image-build.sh" > "$T/stdout" 2> "$T/stderr" )
    rc=$?
  else
    # As a runner cancels: SIGTERM to the whole process group while packer runs.
    rm -f "$T/packer.started"
    ( cd "$T" && exec setsid env -u HARDENED_SECURITY_GROUP_ID -u HARDENED_PUBLIC -u HARDENED_ATTACHED_ORG_ID \
        -u HARDENED_SUBNET_ID -u HARDENED_INSTANCE_TYPE -u GH_REPO "${e[@]}" \
        PACKER_SLEEP=60 PACKER_STARTED="$T/packer.started" \
        "$R/scripts/hardened-image-build.sh" > "$T/stdout" 2> "$T/stderr" ) &
    local pid=$! n=0
    while [ ! -e "$T/packer.started" ] && [ $n -lt 600 ]; do sleep 0.1; n=$((n+1)); done
    kill -TERM -- "-$pid" 2>/dev/null
    wait "$pid"; rc=$?
  fi
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
check "...as a normal release: a vX.Y.Z tag is not a pre-release" \
  "$(grep '^gh .*release create ' "$T/gh.log" | grep -qv -- '--prerelease\|--latest'; echo $?)"
check "the archive was uploaded, then downloaded back" \
  "$(grep -n 'release upload v2.2.0 .*/solo-v2.2.0.tgz$' "$T/gh.log" | head -1 | cut -d: -f1 > "$T/n1"; \
     grep -n 'release download v2.2.0 .*solo-v2.2.0.tgz' "$T/gh.log" | tail -1 | cut -d: -f1 > "$T/n2"; \
     [ -s "$T/n1" ] && [ "$(cat "$T/n1")" -lt "$(cat "$T/n2")" ]; echo $?)"
check "every gh call names the repository" "$(! grep -vx 'idlefy/vm-platform-aws\|repos/idlefy/vm-platform-aws' "$T/gh.log.repo" | grep -q .; echo $?)"
check "packer init on image/hardened, then a machine-readable build" \
  "$(grep -qx "init $R/image/hardened" "$T/packer.log" && grep -qx -- '-machine-readable' "$T/packer.log" && [ "$(grep '^packer' "$T/order.log" | tr '\n' ' ')" = "packer init packer build " ]; echo $?)"
check "ami_name is today's first" "$(var "ami_name=idlefy-hardened-agent-ubuntu-24.04-amd64-$DATE-01"; echo $?)"
check "build_region is the first region" "$(var build_region=us-east-1; echo $?)"
check "ami_regions is every region, in order" "$(var "ami_regions=$REGIONS_JSON"; echo $?)"
check "the test's region list holds 17 regions" "$([ "${#REGIONS[@]}" = 17 ]; echo $?)"
check "image/hardened/regions builds in us-east-1 and copies to the eight other published regions" \
  "$([ "${REAL_REGIONS[*]}" = "us-east-1 eu-central-1 us-east-2 us-west-2 eu-west-1 eu-west-2 ap-south-1 ap-northeast-1 ap-southeast-1" ]; echo $?)"
check "...and every region it lists is a default-enabled one from this test's list, none left as a comment" \
  "$(for r in "${REAL_REGIONS[@]}"; do printf '%s\n' "${REGIONS[@]}" | grep -qx "$r" || exit 1; done \
     && ! grep -qE '^# *(us|ca|eu|ap|sa)-[a-z]+-[0-9]$' "$ROOT/image/hardened/regions"; echo $?)"
check "instance_type defaults to c7a.xlarge" "$(var instance_type=c7a.xlarge; echo $?)"
check "the security group is passed" "$(var "security_group_id=$SG"; echo $?)"
check "public defaults to true" "$(var public=true; echo $?)"
check "volume is 9 GiB" "$(var volume_size_gb=9; echo $?)"
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
check "no placeholder survives" "$(! grep -qE '__[A-Z0-9_]+__' "$T/ud"; echo $?)"
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
check "the last line execs the solo scrub with the archive's sha256 (bash drops its hold on the script)" \
  "$([ "$(ud | tail -1)" = "exec /usr/local/sbin/dev-vm-image-scrub --profile solo $STORED_SHA" ]; echo $?)"
check "the record is written" "$([ -f "$RECORD" ]; echo $?)"
check "the record has exactly the schema" "$(python3 -I - "$RECORD" "$STORED_SHA" "$SHA" "$URL" "$DATE" "${REGIONS[@]}" <<'PY'
import json, re, sys
p, sha, psha, url, date, *regions = sys.argv[1:]
raw = open(p, encoding="utf-8").read()
d = json.loads(raw)
want = {"format", "image", "name", "owner_id", "architecture", "public", "description", "root_volume_gib",
        "login_user", "platform_tag", "platform_sha", "base_tag", "archive_sha256", "archive_url", "built_at", "amis"}
assert set(d) == want and len(want) == 16, sorted(d)
assert list(d) == sorted(d) and list(d["amis"]) == sorted(d["amis"]), "keys not sorted"
assert raw.endswith("\n")
assert d["format"] == 1 and d["image"] == "ubuntu-24.04-hardened"
assert d["name"] == "idlefy-hardened-agent-ubuntu-24.04-amd64-%s-01" % date
assert d["owner_id"] == "995603458290" and d["architecture"] == "x86_64"
assert d["public"] is True and d["root_volume_gib"] == 9 and d["login_user"] == "ubuntu"
assert d["description"] == "Idlefy hardened image for AI agents; visibility=public", d["description"]
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
check "the account is checked before anything is created" \
  "$(grep -qx 'aws sts get-caller-identity --region us-east-1 --query Account --output text' "$T/aws.log" \
     && a=$(grep -n '^aws sts' "$T/order.log" | cut -d: -f1) && c=$(grep -n '^gh release create' "$T/order.log" | cut -d: -f1) \
     && [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; echo $?)"
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

echo "== NN is one past the highest name in use today =="
P=idlefy-hardened-agent-ubuntu-24.04-amd64-$DATE
nn_is() {  # nn_is NAMES NN
  EXISTING_NAMES="$1" run_build; local rc=$?
  check "{${1:-none}} → -$2" "$([ $rc -eq 0 ] && var "ami_name=$P-$2" && [ -f "$T/out/hardened-ami-$DATE-$2.json" ]; echo $?)"
}
nn_is "" 01
nn_is "$P-02" 03
nn_is "$P-01 $P-02" 03
nn_is "$P-02 $P-01" 03
nn_is "$P-98" 99
nn_is "$P-09" 10
check "the query asks for names" "$(grep -qF -- "--query Images[].Name" "$T/aws.log"; echo $?)"
EXISTING_NAMES="$P-99" run_build
check "{-99} refuses, packer never runs" "$([ $? -ne 0 ] && grep -q '99' "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"
EXISTING_NAMES="$P-01 $P-1x" run_build
check "a malformed name in the answer refuses, naming it" "$([ $? -ne 0 ] && grep -qF "$P-1x" "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"
EXISTING_NAMES="None" run_build
check "an answer that is not names refuses" "$([ $? -ne 0 ] && [ ! -s "$T/packer.log" ]; echo $?)"
NO_TODAY=1 run_build
check "without HARDENED_TODAY the date is today's UTC date" \
  "$([ $? -eq 0 ] && grep -qE '^ami_name=idlefy-hardened-agent-ubuntu-24.04-amd64-[0-9]{8}-01$' "$T/packer.log" \
     && { grep -q "^ami_name=.*-$(date -u +%Y%m%d)-01\$" "$T/packer.log" || grep -q "^ami_name=.*-$(date -u -d '-1 min' +%Y%m%d)-01\$" "$T/packer.log"; }; echo $?)"
TODAY=2026111 run_build; refuses_early_nochef=$?
check "a malformed HARDENED_TODAY refuses" "$([ $refuses_early_nochef -ne 0 ] && grep -q HARDENED_TODAY "$T/stderr" && [ ! -s "$T/chef.log" ]; echo $?)"

echo "== the wrong AWS account refuses before anything is created =="
AWS_ACCOUNT=111122223333 run_build
check "exits non-zero, names both accounts" "$([ $? -ne 0 ] && grep -q 111122223333 "$T/stderr" && grep -q 995603458290 "$T/stderr"; echo $?)"
check "...no release create or upload, no packer" "$(! grep -q 'release create\|release upload' "$T/gh.log" && [ ! -s "$T/packer.log" ]; echo $?)"

echo "== an unreadable AWS account refuses with AWS's own words =="
STS_FAIL=1 run_build
check "exits non-zero, says why, nothing created" \
  "$([ $? -ne 0 ] && grep -q 'ExpiredToken' "$T/stderr" && ! grep -q 'release create\|release upload' "$T/gh.log" && [ ! -s "$T/packer.log" ]; echo $?)"

echo "== HARDENED_TODAY is a test hook: refused without HARDENED_SKIP_TAG_CHECK=1 =="
SKIP_TAG= run_build
check "refuses before chef, naming both hooks" \
  "$([ $? -ne 0 ] && grep -q HARDENED_TODAY "$T/stderr" && grep -q HARDENED_SKIP_TAG_CHECK "$T/stderr" && [ ! -s "$T/chef.log" ] && [ ! -s "$T/aws.log" ]; echo $?)"
SKIP_TAG=yes run_build
check "...and with any value of the other hook but 1" "$([ $? -ne 0 ] && grep -q HARDENED_SKIP_TAG_CHECK "$T/stderr"; echo $?)"

echo "== an asset that downloads back different refuses =="
GH_DOWNLOAD_CORRUPT=1 run_build
check "exits non-zero, packer never runs" "$([ $? -ne 0 ] && grep -q 'solo-v2.2.0.tgz' "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"

echo "== a region missing from the artifact refuses =="
ARTIFACT_REGIONS="us-east-1" run_build
check "exits non-zero, names a missing region" "$([ $? -ne 0 ] && grep -q 'sa-east-1' "$T/stderr"; echo $?)"
check "...no record file" "$(! compgen -G "$T/out/*.json" >/dev/null; echo $?)"
check "...no record upload, no notes edit" "$(! grep -q 'release upload .*\.json\|release edit' "$T/gh.log"; echo $?)"
ARTIFACT_REGIONS="${REGIONS[*]} me-south-1" run_build
check "a region the file does not list refuses too" "$([ $? -ne 0 ] && [ ! -e "$RECORD" ]; echo $?)"
PACKER_RC=1 run_build
check "packer fails → refuses, no record" "$([ $? -ne 0 ] && [ ! -e "$RECORD" ] && ! grep -q 'release edit' "$T/gh.log"; echo $?)"

echo "== a failure after the images were made lists them, read-only =="
LEFT='{"Images": [{"ImageId": "ami-0aaa", "Name": "'"$P-01"'", "State": "available", "Public": true, "Tags": [{"Key": "IdlefyPublishedImage", "Value": "true"}]}]}'
LEFTOVER_us_east_2="$LEFT" LEFTOVER_FAIL=sa-east-1 PACKER_RC=1 run_build; rc=$?
check "packer fails → exit 1, the original status" "$([ $rc -eq 1 ]; echo $?)"
check "...a heading says they may be public and no record names them" \
  "$(grep -qF "Images named $P-01 may exist, and may be PUBLIC; no release record names them." "$T/stderr"; echo $?)"
check "...each region read, by exact name, read-only" \
  "$([ "$(grep -cF -- "--filters Name=name,Values=$P-01 --output json" "$T/aws.log")" = "${#REGIONS[@]}" ] \
     && ! grep -qE '^aws ec2 (deregister|delete|disable|modify)' "$T/aws.log"; echo $?)"
check "...the leftover: region, id, state, public, fence tag" \
  "$(grep -qF 'us-east-2: ami-0aaa  state=available  public=true  IdlefyPublishedImage=true: yes' "$T/stderr"; echo $?)"
check "...a region with none says none" "$(grep -qxF '   us-east-1: none' "$T/stderr"; echo $?)"
check "...a failed describe is printed, not hidden" "$(grep -qF 'sa-east-1: could not list (check by hand): An error occurred (RequestLimitExceeded)' "$T/stderr"; echo $?)"
check "...the old 'serial console holds the log' claim is gone" "$(! grep -qF "the instance's serial console holds the bootstrap log" "$T/stderr"; echo $?)"
check "...the chosen name was written before packer ran" "$([ "$(cat "$T/out/hardened-ami-name")" = "$P-01" ]; echo $?)"
LEFTOVER_us_east_2="$LEFT" TERM_MID_PACKER=1 run_build; rc=$?
check "SIGTERM mid-packer (a cancel) → exit 143" "$([ $rc -eq 143 ]; echo $?)"
check "...and the leftovers are still listed, with real rows" \
  "$(grep -qF 'may be PUBLIC' "$T/stderr" && grep -qF 'us-east-2: ami-0aaa  state=available  public=true' "$T/stderr" \
     && grep -qxF '   us-east-1: none' "$T/stderr" && ! grep -qF 'could not list' "$T/stderr"; echo $?)"
echo "== scripts/hardened-image-leftovers.sh on its own (the workflow's step) =="
lo() { rm -f "$T/aws.log.n"; env PATH="$T/bin:$PATH" AWS_LOG="$T/aws.log" ORDER_LOG="$T/order.log" HARDENED_LEFTOVERS_PAUSE="${PAUSE-0}" "$R/scripts/hardened-image-leftovers.sh" "$@" > "$T/lo.out" 2> "$T/lo.err"; }
LEFTOVER_us_east_2="$LEFT" lo "$P-01"
check "every region read → exit 0, rows on stdout" "$([ $? -eq 0 ] && grep -qF 'us-east-2: ami-0aaa' "$T/lo.out"; echo $?)"
LEFTOVER_FAIL=eu-west-1 lo "$P-01"
check "a region it cannot read → exit 1, named" "$([ $? -eq 1 ] && grep -qF 'eu-west-1: could not list' "$T/lo.out"; echo $?)"
: > "$T/aws.log"; lo "$P-01; rm -rf /"
check "a name outside the pattern → exit 1, no AWS call" "$([ $? -eq 1 ] && [ ! -s "$T/aws.log" ]; echo $?)"

echo "== build instance and key pair: listed read-only, removed only with --clean-build =="
B1=$(grep -v '^[[:space:]]*\(#\|$\)' "$R/image/hardened/regions" | head -n 1)
: > "$T/aws.log"; lo "$P-01"
check "none left → exit 0, says none for both" \
  "$([ $? -eq 0 ] && grep -qxF '   instances: none' "$T/lo.out" && grep -qxF '   packer_* key pairs: none' "$T/lo.out"; echo $?)"
check "...reads the build region by the build's Name tag, never terminated or shutting-down ones" \
  "$(grep -qF "aws ec2 describe-instances --region $B1 --filters Name=tag:Name,Values=idlefy-hardened-image-build Name=instance-state-name,Values=pending,running,stopping,stopped" "$T/aws.log" \
     && grep -qF "aws ec2 describe-key-pairs --region $B1 --filters Name=tag:Name,Values=idlefy-hardened-image-build" "$T/aws.log" \
     && [ "$(grep -c 'describe-instances\|describe-key-pairs' "$T/aws.log")" = 2 ]; echo $?)"
: > "$T/aws.log"; BUILD_INSTANCES="i-0abc:running i-0def:stopped" BUILD_KEYS="packer_6740c0de other-key" lo "$P-01"
check "left ones are listed, nothing removed without --clean-build" \
  "$([ $? -eq 0 ] && grep -qxF '   instance i-0abc  state=running' "$T/lo.out" && grep -qxF '   key pair packer_6740c0de' "$T/lo.out" \
     && ! grep -qF 'other-key' "$T/lo.out" && ! grep -qE 'terminate-instances|delete-key-pair' "$T/aws.log" \
     && grep -qF -- '--clean-build' "$T/lo.out"; echo $?)"
: > "$T/aws.log"; BUILD_INSTANCES="i-0abc:running i-0def:stopped" BUILD_KEYS="packer_6740c0de other-key" lo --clean-build "$P-01"
check "--clean-build terminates exactly those instances and deletes only the packer_* key pair" \
  "$([ $? -eq 0 ] && grep -qF "aws ec2 terminate-instances --region $B1 --instance-ids i-0abc " "$T/aws.log" \
     && grep -qF "aws ec2 terminate-instances --region $B1 --instance-ids i-0def " "$T/aws.log" \
     && grep -qF "aws ec2 delete-key-pair --region $B1 --key-name packer_6740c0de " "$T/aws.log" \
     && [ "$(grep -c 'terminate-instances\|delete-key-pair' "$T/aws.log")" = 3 ] \
     && grep -qxF '   terminated i-0abc' "$T/lo.out" && grep -qxF '   deleted key pair packer_6740c0de' "$T/lo.out"; echo $?)"
check "...and never touches an image" "$(! grep -qE '^aws ec2 (deregister|delete-snapshot|disable|modify)' "$T/aws.log"; echo $?)"
check "...listing instances once when it found some" "$([ "$(grep -c '^aws ec2 describe-instances' "$T/aws.log")" = 1 ]; echo $?)"
check "...removing them before the image listing (the instance costs money; the step may be near its deadline)" \
  "$(t=$(grep -n '^aws ec2 delete-key-pair' "$T/aws.log" | tail -1 | cut -d: -f1); i=$(grep -n '^aws ec2 describe-images' "$T/aws.log" | head -1 | cut -d: -f1); \
     [ -n "$t" ] && [ -n "$i" ] && [ "$t" -lt "$i" ]; echo $?)"
: > "$T/aws.log"; BUILD_INSTANCES="i-0abc:running" BUILD_KEYS="packer_6740c0de" lo --clean-build
check "--clean-build without a name (no name file) → images not listed, build resources removed" \
  "$([ $? -eq 0 ] && ! grep -qF 'describe-images' "$T/aws.log" && grep -qF 'terminate-instances' "$T/aws.log" \
     && grep -qF 'delete-key-pair' "$T/aws.log" && grep -qF 'images are not listed' "$T/lo.out"; echo $?)"
# An instance EC2 accepted just before the runner killed Packer may not be
# listable yet: --clean-build asks again (3 listings), a plain listing once.
: > "$T/aws.log"; BUILD_INSTANCES="i-0abc:running" INSTANCES_LATE=2 lo --clean-build
check "--clean-build: an instance listable only on the third try is terminated" \
  "$([ $? -eq 0 ] && [ "$(grep -c '^aws ec2 describe-instances' "$T/aws.log")" = 3 ] \
     && grep -qF "aws ec2 terminate-instances --region $B1 --instance-ids i-0abc " "$T/aws.log"; echo $?)"
: > "$T/aws.log"; BUILD_INSTANCES="" lo --clean-build
check "--clean-build: still none after 3 listings → says so" \
  "$([ $? -eq 0 ] && [ "$(grep -c '^aws ec2 describe-instances' "$T/aws.log")" = 3 ] && grep -qF 'instances: none (listed 3 times' "$T/lo.out"; echo $?)"
: > "$T/aws.log"; BUILD_INSTANCES="i-0abc:running" INSTANCES_LATE=2 lo
check "a plain listing asks once and reports none" \
  "$([ "$(grep -c '^aws ec2 describe-instances' "$T/aws.log")" = 1 ] && grep -qxF '   instances: none' "$T/lo.out" && ! grep -q terminate "$T/aws.log"; echo $?)"
check "the pause between listings is 10 s unless the test hook sets it" \
  "$(grep -qF 'CLEAN_PAUSE="${HARDENED_LEFTOVERS_PAUSE:-10}"' "$R/scripts/hardened-image-leftovers.sh" && grep -qx 'CLEAN_TRIES=3' "$R/scripts/hardened-image-leftovers.sh"; echo $?)"
BUILD_INSTANCES="i-0abc:running" BUILD_KEYS="packer_6740c0de" TERMINATE_FAIL=1 lo --clean-build
check "a refused terminate → exit 1, named; the key pair is still deleted" \
  "$([ $? -eq 1 ] && grep -qF 'could not terminate i-0abc (do it by hand)' "$T/lo.out" && grep -qxF '   deleted key pair packer_6740c0de' "$T/lo.out"; echo $?)"
: > "$T/aws.log"; INSTANCES_FAIL=1 BUILD_KEYS="packer_6740c0de" lo --clean-build
check "instances it cannot list → exit 1, named, nothing terminated" \
  "$([ $? -eq 1 ] && grep -qF 'instances: could not list' "$T/lo.out" && ! grep -qF 'terminate-instances' "$T/aws.log"; echo $?)"
: > "$T/aws.log"; BUILD_INSTANCES="i-0abc:running" BUILD_KEYS="packer_6740c0de" AWS_ACCOUNT=111122223333 lo --clean-build
check "--clean-build with another account's credentials → exit 1, says so, nothing listed or removed" \
  "$([ $? -eq 1 ] && grep -qF "these credentials are for account '111122223333', not the publisher account 995603458290" "$T/lo.err" \
     && [ "$(grep -c . "$T/aws.log")" = 1 ] && grep -q '^aws sts get-caller-identity' "$T/aws.log"; echo $?)"
: > "$T/aws.log"; BUILD_INSTANCES="i-0abc:running" BUILD_KEYS="packer_6740c0de" STS_FAIL=1 lo --clean-build
check "--clean-build with an unreadable identity → exit 1, says so, nothing removed" \
  "$([ $? -eq 1 ] && grep -qF 'could not read the AWS account' "$T/lo.err" && ! grep -qE 'terminate-instances|delete-key-pair' "$T/aws.log"; echo $?)"
cp "$R/scripts/hardened-guard-check.sh" "$T/guard.orig"
python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("\nACCOUNT_ID=", "\nACCOUNTID=", 1))' "$R/scripts/hardened-guard-check.sh"
: > "$T/aws.log"; BUILD_INSTANCES="i-0abc:running" lo --clean-build
check "--clean-build when the guard's ACCOUNT_ID cannot be read → exit 1, no AWS call" \
  "$([ $? -eq 1 ] && grep -qF 'cannot read the publisher account id' "$T/lo.err" && [ ! -s "$T/aws.log" ]; echo $?)"
cp "$T/guard.orig" "$R/scripts/hardened-guard-check.sh"
check "the leftovers script holds no copy of the account id" "$(! grep -qE '[0-9]{12}' "$R/scripts/hardened-image-leftovers.sh"; echo $?)"
: > "$T/aws.log"; BUILD_INSTANCES="i-0abc:running" lo "$P-01"
check "listing alone reads no identity (read-only, as before)" "$([ $? -eq 0 ] && ! grep -q 'get-caller-identity' "$T/aws.log"; echo $?)"
: > "$T/aws.log"; lo --terminate-everything
check "an unknown option → exit 1, no AWS call" "$([ $? -eq 1 ] && [ ! -s "$T/aws.log" ]; echo $?)"
BUILD_INSTANCES="i-0abc:running" PACKER_RC=1 run_build
check "the driver's own listing after a failure is read-only and shows the instance" \
  "$([ $? -ne 0 ] && grep -qF 'instance i-0abc  state=running' "$T/stderr" && ! grep -qE 'terminate-instances|delete-key-pair' "$T/aws.log"; echo $?)"
LEFTOVER_us_east_1="$LEFT" ARTIFACT_REGIONS="us-east-1" run_build
check "an artifact short of regions → the images are listed" \
  "$([ $? -ne 0 ] && grep -qF 'us-east-1: ami-0aaa' "$T/stderr"; echo $?)"
LEFTOVER_us_east_1="$LEFT" GH_RECORD_UPLOAD_FAIL=1 run_build
check "the record upload fails → the images are listed" \
  "$([ $? -ne 0 ] && grep -qF 'may be PUBLIC' "$T/stderr" && grep -qF 'us-east-1: ami-0aaa' "$T/stderr"; echo $?)"
LEFTOVER_us_east_1="$LEFT" GH_NOTES_FAIL=1 run_build; rc=$?
check "the notes edit fails after the record is up → exit 1, no leftover list" \
  "$([ $rc -eq 1 ] && grep -qF 'release notes were not updated' "$T/stderr" && ! grep -qF 'may be PUBLIC' "$T/stderr"; echo $?)"
check "...and no name file for the workflow's leftovers step to list recorded images by" \
  "$([ ! -e "$T/out/hardened-ami-name" ] && compgen -G "$T/out/hardened-ami-*.json" >/dev/null; echo $?)"
LEFTOVER_us_east_1="$LEFT" GH_RECORD_UPLOAD_FAIL=1 run_build
check "a failed record upload keeps the name file (its images are unrecorded)" "$([ -s "$T/out/hardened-ami-name" ]; echo $?)"
LEFTOVER_us_east_1="$LEFT" run_build
check "a green build lists nothing" "$([ $? -eq 0 ] && ! grep -qF 'may be PUBLIC' "$T/stderr"; echo $?)"

echo "== NN counts every region, and a region it cannot read refuses =="
EXISTING_NAMES_us_east_2="$P-04" run_build
check "-04 only in us-east-2 → -05" "$([ $? -eq 0 ] && var "ami_name=$P-05"; echo $?)"
NAMES_FAIL_REGION=ap-south-1 run_build
check "a failed describe in ap-south-1 refuses, naming it, packer never runs" \
  "$([ $? -ne 0 ] && grep -qF 'ap-south-1' "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"

echo "== the console watcher: a failed bootstrap ends the build, not a 2 h wait =="
CONSOLE_OUTPUT='[  12.3] cloud-init: booting\nBOOTSTRAP FAILED: no image will be taken. Log follows.\napt_package[ripgrep]: No candidate version' \
  HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=30 run_build; rc=$?
check "the banner → non-zero, says the bootstrap failed" \
  "$([ $rc -ne 0 ] && grep -qF 'the bootstrap failed on the build instance' "$T/stderr"; echo $?)"
check "...Packer was interrupted (SIGINT), not left to wait" "$(grep -qx interrupted "$T/packer.log"; echo $?)"
check "...the console's tail is in the log" \
  "$(grep -qF 'BOOTSTRAP FAILED: no image will be taken' "$T/stderr" && grep -qF 'apt_package[ripgrep]: No candidate version' "$T/stderr"; echo $?)"
check "...the tail names the instance" "$(grep -qF '!! i-0123456789abcdef0: the bootstrap failed' "$T/stderr"; echo $?)"
check "...it read the instance Packer named, latest output" \
  "$(grep -q '^aws ec2 get-console-output --region us-east-1 --instance-id i-0123456789abcdef0 --latest ' "$T/aws.log"; echo $?)"
check "...no record" "$([ ! -e "$RECORD" ]; echo $?)"
CONSOLE_OUTPUT='solo converge complete\ndev-vm-image-scrub: internal error: ubuntu is in group sudo; no image will be taken' \
  HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=30 run_build; rc=$?
check "the scrub's refusal ends the build too, and says so" \
  "$([ $rc -ne 0 ] && grep -qx interrupted "$T/packer.log" && grep -qF 'the image scrub refused the image on the build instance' "$T/stderr"; echo $?)"
CONSOLE_OUTPUT='[  12.3] cloud-init: booting\nsolo converge complete' HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=3 run_build; rc=$?
check "no banner → Packer runs to the end, exit 0, a record" \
  "$([ $rc -eq 0 ] && ! grep -qx interrupted "$T/packer.log" && [ -f "$RECORD" ] && grep -q 'get-console-output' "$T/aws.log"; echo $?)"
CONSOLE_OUTPUT='' HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=1 run_build
check "an empty console (a stopped instance) → nothing happens, exit 0" "$([ $? -eq 0 ] && ! grep -qx interrupted "$T/packer.log"; echo $?)"
CONSOLE_FAIL=1 HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=3 run_build; rc=$?
check "console read errors are tolerated: exit 0, a record, one note" \
  "$([ $rc -eq 0 ] && [ -f "$RECORD" ] && [ "$(grep -c 'cannot read the console of i-0123456789abcdef0' "$T/stderr")" = 1 ]; echo $?)"

CONSOLE_OUTPUT='[  12.3] cloud-init[812]: + echo "BOOTSTRAP FAILED: no image will be taken. Log follows."\nsee BOOTSTRAP FAILED: no image will be taken. Log follows. in the docs\n  dev-vm-image-scrub: refusing: quoted\ndev-vm-image-scrub: note: rsyslog not stopped' \
  HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=3 run_build; rc=$?
check "a healthy console that only quotes the markers inside other lines → no interrupt, exit 0" \
  "$([ $rc -eq 0 ] && ! grep -qx interrupted "$T/packer.log" && [ -f "$RECORD" ] && grep -q 'get-console-output' "$T/aws.log"; echo $?)"
CONSOLE_OUTPUT='boot\r\nBOOTSTRAP FAILED: no image will be taken. Log follows.\r\nE: oops\r' HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=30 run_build; rc=$?
check "the banner as a whole line ending in CR LF → interrupted" "$([ $rc -ne 0 ] && grep -qx interrupted "$T/packer.log"; echo $?)"
for msg in "internal error: unknown profile 'solo'" "internal error: expected a revision id, got 'x'" \
           "internal error: not root and DEV_VM_IMAGE_ROOT unset; this runs only on a build instance" \
           "internal error at line 77; no image will be taken" \
           "refusing: status is 'converge-failed x', expected 'ok y'; no image will be taken"; do
  CONSOLE_OUTPUT="solo converge complete\ndev-vm-image-scrub: $msg" HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=30 run_build; rc=$?
  check "the scrub's '$msg' → interrupted, named" \
    "$([ $rc -ne 0 ] && grep -qx interrupted "$T/packer.log" && grep -qF 'the image scrub refused the image' "$T/stderr"; echo $?)"
done
check "every exit-70 message of the scrubs starts 'internal error' or 'refusing'" \
  "$(! grep -hoE 'log "[^"]*"' "$R/image/files/dev-vm-image-scrub" "$R/image/files/dev-vm-image-scrub-solo" \
       | grep -vE '^log "(internal error|refusing)[ :]|^log "note: ' | grep -q .; echo $?)"
check "the banner the watcher matches is the one bootstrap-solo prints, after a newline" \
  "$(grep -A1 -xF '    echo' "$R/image/files/bootstrap-solo" | grep -qxF '    echo "BOOTSTRAP FAILED: no image will be taken. Log follows."' \
     && grep -qF '?BOOTSTRAP FAILED: no image will be taken\\. Log follows\\.\$" ' "$R/scripts/hardened-image-build.sh"; echo $?)"
# An unterminated getty prompt may sit before a marker.
for c in 'ip-10-0-1-5 login: BOOTSTRAP FAILED: no image will be taken. Log follows.' \
         'ip-10-0-1-5 login: dev-vm-image-scrub: refusing: x; no image will be taken' \
         'ip-10-0-1-5 login: \nBOOTSTRAP FAILED: no image will be taken. Log follows.'; do
  CONSOLE_OUTPUT="boot\n$c" HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=30 run_build; rc=$?
  check "a marker after a login prompt ('${c:0:40}…') → interrupted" "$([ $rc -ne 0 ] && grep -qx interrupted "$T/packer.log"; echo $?)"
done
CONSOLE_OUTPUT='ip-10-0-1-5 login: root typed dev-vm-image-scrub: refusing: x\nlogin: BOOTSTRAP FAILED: no image will be taken. Log follows.' \
  HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=3 run_build; rc=$?
check "a marker after other prompt text, or after a bare 'login: ' → no interrupt, exit 0" \
  "$([ $rc -eq 0 ] && ! grep -qx interrupted "$T/packer.log"; echo $?)"
CONSOLE_OUTPUT='BOOTSTRAP FAILED: no image will be taken. Log follows.' PACKER_INT_OK=1 HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=30 run_build; rc=$?
check "Packer takes the interrupt yet exits 0 with a full artifact → the driver still fails, no record" \
  "$([ $rc -ne 0 ] && grep -qx interrupted "$T/packer.log" && [ ! -e "$RECORD" ] \
     && ! grep -q 'release upload .*\.json' "$T/gh.log" && grep -qF 'the bootstrap failed on the build instance' "$T/stderr"; echo $?)"

# packer_gone — every process of the Packer stand-in (wrapper and child) has
# ended.
packer_gone() {
  local p
  [ -s "$T/packer.pids" ] || return 1
  while read -r p; do ! kill -0 "$p" 2>/dev/null || return 1; done < "$T/packer.pids"
}
# before A B FILE — a line equal to A comes before the last line starting B.
before() {
  awk -v a="$1" -v b="$2" '$0 == a && !s { s = NR } index($0, b) == 1 { l = NR } END { exit !(s && l && s < l) }' "$3"
}
# session_gone — no process of the driver's session is left, checked at once.
session_gone() { [ -n "$SESSION" ] && [ -z "$(ps -s "$SESSION" -o pid= 2>/dev/null)" ]; }
CONSOLE_OUTPUT='BOOTSTRAP FAILED: no image will be taken. Log follows.' HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=30 run_build; rc=$?
check "a marker reaches Packer's worker through its SIGINT-swallowing wrapper; both end" \
  "$([ $rc -ne 0 ] && grep -qx interrupted "$T/packer.log" && [ "$(wc -l < "$T/packer.pids")" = 2 ] && packer_gone; echo $?)"

echo "== the console watcher and Packer never outlive the driver =="
for sig in INT TERM; do
  want=$([ $sig = INT ] && echo 130 || echo 143)
  # A watcher asleep in a long poll.
  SESSION=""; HARDENED_CONSOLE_POLL=600 PACKER_HOLD=30 SIG_EARLY=$sig run_build; rc=$?
  check "SIG$sig to the driver's session while Packer runs → exit $want" "$([ $rc -eq $want ]; echo $?)"
  check "...Packer's worker got the interrupt through its wrapper; wrapper and worker ended" \
    "$(grep -qx interrupted "$T/packer.log" && packer_gone; echo $?)"
  check "...Packer was waited for: its clean-up ended before the leftovers were listed" \
    "$(before 'packer cleaned-up' 'aws ec2 describe-instances' "$T/order.log"; echo $?)"
  check "...the pipe Packer writes to survived the signal: its cancel line reached the log" \
    "$(grep -qxF 'Build was cancelled.' "$T/stdout"; echo $?)"
  check "...no process of the session is left, checked at once (the watcher's long sleep too)" "$(session_gone; echo $?)"
  [ -z "$SESSION" ] || pkill -s "$SESSION" 2>/dev/null || true
  # A watcher waiting on a console read that hangs.
  SESSION=""; CONSOLE_HANG=1 HARDENED_CONSOLE_POLL=0.2 PACKER_HOLD=30 SIG_EARLY=$sig SIG_LOG=aws.log SIG_WHEN=get-console-output run_build; rc=$?
  check "SIG$sig while the watcher waits on a hung console read → exit $want, Packer interrupted and gone" \
    "$([ $rc -eq $want ] && grep -qx interrupted "$T/packer.log" && packer_gone; echo $?)"
  check "...no process of the session is left, checked at once (the hung read too)" "$(session_gone; echo $?)"
  [ -z "$SESSION" ] || pkill -s "$SESSION" 2>/dev/null || true
done

# A runner's cancel: INT, then TERM while Packer is still cleaning up.
SESSION=""; HARDENED_CONSOLE_POLL=600 PACKER_HOLD=30 PACKER_CLEANUP=3 SIG_EARLY=INT SIG_THEN=TERM SIG_GAP=1 run_build; rc=$?
check "INT, then TERM during Packer's 3 s clean-up → exit 130 (the first status), not 143" "$([ $rc -eq 130 ]; echo $?)"
check "...Packer's clean-up still ended before the leftovers were listed" \
  "$(before 'packer cleaned-up' 'aws ec2 describe-instances' "$T/order.log" && grep -q '^aws ec2 describe-images' "$T/order.log"; echo $?)"
check "...wrapper, worker and every process of the session are gone" "$(packer_gone && session_gone; echo $?)"
[ -z "$SESSION" ] || pkill -s "$SESSION" 2>/dev/null || true

# A clean-up that never ends: the driver stops waiting after the grace
# period, says so, keeps its status and still lists leftovers; no KILL.
SESSION=""; rm -f "$T/packer.pids"
start=$SECONDS
HARDENED_PACKER_GRACE=2 HARDENED_CONSOLE_POLL=600 PACKER_HOLD=120 PACKER_STUCK=1 SIG_EARLY=INT run_build; rc=$?
took=$((SECONDS - start))
check "a Packer whose clean-up never ends → exit 130 after the 2 s grace (took ${took} s), not a hang" \
  "$([ $rc -eq 130 ] && [ "$took" -lt 30 ] && grep -qx interrupted "$T/packer.log"; echo $?)"
check "...says the clean-up was NOT confirmed and points at --clean-build" \
  "$(grep -qF "Packer's clean-up was NOT confirmed within 2 s" "$T/stderr" && grep -qF 'hardened-image-leftovers.sh --clean-build' "$T/stderr"; echo $?)"
check "...still lists leftovers" \
  "$(grep -q '^aws ec2 describe-instances' "$T/order.log" && grep -qF 'Build resources in' "$T/stderr"; echo $?)"
check "...and never killed Packer: its worker still runs" \
  "$(p=$(sed -n 2p "$T/packer.pids"); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; echo $?)"
while read -r p; do kill -KILL "$p" 2>/dev/null; done < "$T/packer.pids"
[ -z "$SESSION" ] || pkill -s "$SESSION" 2>/dev/null || true

echo "== public=false and an attached org =="
PUBLIC=false ORG=0b7c3c1e-5f0e-4b8e-9a51-3f0c2d1e4a5b run_build; check "exits 0" "$?"
check "packer var public=false" "$(var public=false; echo $?)"
check "record public: false" "$(python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["public"] is not False)' "$RECORD"; echo $?)"
check "record description says visibility=private" \
  "$(python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["description"] != "Idlefy hardened image for AI agents; visibility=private")' "$RECORD"; echo $?)"
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
HARDENED_CONSOLE_POLL=soon run_build; refuses_early $? "a console poll that is not a number refuses" HARDENED_CONSOLE_POLL
for z in 0 0.0 00.000; do
  HARDENED_CONSOLE_POLL=$z run_build; refuses_early $? "a console poll of '$z' (zero: the watcher would spin) refuses" HARDENED_CONSOLE_POLL
  HARDENED_PACKER_GRACE=$z run_build; refuses_early $? "a Packer grace of '$z' refuses" HARDENED_PACKER_GRACE
done
HARDENED_PACKER_GRACE=soon run_build; refuses_early $? "a Packer grace that is not a number refuses" HARDENED_PACKER_GRACE
check "the driver says why a non-Nitro type loses the fast failure path, and that the type is fixed" \
  "$(grep -qF 'only Nitro' "$R/scripts/hardened-image-build.sh" && grep -qF 'type is fixed at c7a.xlarge' "$R/scripts/hardened-image-build.sh"; echo $?)"

echo "== a pre-release tag vX.Y.Z-rc.N: a private test build only =="
# no_cloud_call — nothing reached chef, GitHub or AWS.
no_cloud_call() { [ ! -s "$T/chef.log" ] && [ ! -s "$T/gh.log" ] && [ ! -s "$T/aws.log" ] && [ ! -s "$T/packer.log" ]; }
RC_RECORD="$T/out/hardened-ami-$DATE-01.json"
PLATFORM_TAG=v2.2.0-rc.1 PUBLIC=false GH_RELEASE_MISSING=1 run_build
check "a private build from v2.2.0-rc.1 → exits 0" "$?"
check "...its missing release is created as a pre-release, never Latest" \
  "$(grep -q -- '^gh release create v2.2.0-rc.1 --verify-tag --prerelease --latest=false --title v2.2.0-rc.1 ' "$T/gh.log"; echo $?)"
check "...the archive is solo-v2.2.0-rc.1.tgz on that release" \
  "$(grep -q 'release upload v2.2.0-rc.1 .*/solo-v2.2.0-rc.1.tgz$' "$T/gh.log"; echo $?)"
check "...the record names the rc tag and says private" \
  "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["platform_tag"]=="v2.2.0-rc.1" and d["public"] is False and d["description"].endswith("visibility=private") else 1)' "$RC_RECORD"; echo $?)"
PLATFORM_TAG=v2.2.0-rc.2 PUBLIC=false run_build
check "an rc build whose release exists → exits 0" "$?"
check "...and leaves the release's flags alone: no create, no flag in any edit" \
  "$(! grep -q 'release create' "$T/gh.log" && ! grep '^gh release edit' "$T/gh.log" | grep -q -- '--prerelease\|--latest\|--draft'; echo $?)"
for pub in true default; do
  if [ "$pub" = default ]; then PLATFORM_TAG=v2.2.0-rc.1 run_build; else PLATFORM_TAG=v2.2.0-rc.1 PUBLIC=$pub run_build; fi
  check "a public build ($pub) from v2.2.0-rc.1 refuses, names the pre-release, before any cloud call" \
    "$([ $? -ne 0 ] && grep -q 'pre-release tag: it builds a private image only' "$T/stderr" && no_cloud_call; echo $?)"
done
for bad in v2.2.0-rc v2.2.0-rc.0 v2.2.0-rc.01 v2.2.0-rc.1.2 v2.2.0-beta.1 v2.2.0-rc.1x v2.2.0rc.1 v2.2.0-RC.1; do
  PLATFORM_TAG=$bad PUBLIC=false run_build
  check "PLATFORM_TAG=$bad refuses before any cloud call" \
    "$([ $? -ne 0 ] && grep -q 'is not a vX.Y.Z or vX.Y.Z-rc.N tag' "$T/stderr" && no_cloud_call; echo $?)"
done

echo "== the tag must name PLATFORM_SHA, and the tree must be it =="
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm t && git -C "$R" tag v2.2.0
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
# A real build: no HARDENED_TODAY (it is refused without the skip hook).
NO_TODAY=1 SKIP_TAG= PLATFORM_SHA=$HEAD_SHA run_build; check "the tag's commit, checked out → builds" "$?"
NO_TODAY=1 SKIP_TAG= run_build; refuses_early $? "a PLATFORM_SHA the tag does not name refuses" PLATFORM_SHA
NO_TODAY=1 SKIP_TAG=false run_build; refuses_early $? "HARDENED_SKIP_TAG_CHECK=false still checks the tag" PLATFORM_SHA
NO_TODAY=1 SKIP_TAG=yes run_build; refuses_early $? "...and so does any value but 1" PLATFORM_SHA
NO_TODAY=1 SKIP_TAG= PLATFORM_TAG=v9.9.9 PLATFORM_SHA=$HEAD_SHA run_build; refuses_early $? "a tag that does not exist refuses" v9.9.9
git -C "$R" tag v2.2.0-rc.1
NO_TODAY=1 SKIP_TAG= PLATFORM_TAG=v2.2.0-rc.1 PUBLIC=false PLATFORM_SHA=$HEAD_SHA run_build
check "a real v2.2.0-rc.1 tag on the checked-out commit → a private build passes the tag check" "$?"
cp "$R/image/hardened/regions" "$T/regions.clean"
printf '# edited\n' >> "$R/image/hardened/regions"
NO_TODAY=1 SKIP_TAG= PLATFORM_SHA=$HEAD_SHA run_build
refuses_early $? "a modified tracked file refuses, names it" image/hardened/regions
git -C "$R" add image/hardened/regions
NO_TODAY=1 SKIP_TAG= PLATFORM_SHA=$HEAD_SHA run_build
refuses_early $? "a staged change refuses, names it" image/hardened/regions
NO_TODAY=1 PLATFORM_SHA=$HEAD_SHA run_build
check "HARDENED_SKIP_TAG_CHECK=1 skips the clean-tree check too" "$?"
cp "$T/regions.clean" "$R/image/hardened/regions"; git -C "$R" add image/hardened/regions
for f in image/stray.sh scripts/stray.sh cinc/stray.rb; do
  mkdir -p "$R/${f%/*}"; : > "$R/$f"
  NO_TODAY=1 SKIP_TAG= PLATFORM_SHA=$HEAD_SHA run_build
  refuses_early $? "an untracked $f refuses, names it" "$f"
  rm -f "$R/$f"
done
mkdir -p "$R/dist"; : > "$R/dist/hardened-ami-name"; : > "$R/stray-at-root"
NO_TODAY=1 SKIP_TAG= PLATFORM_SHA=$HEAD_SHA run_build
check "untracked files in dist/ (and outside the build's inputs) are allowed" "$?"
rm -rf "$R/dist" "$R/stray-at-root"
rm -rf "$R/.git"

echo "== the user data is checked before packer runs =="
cp "$R/image/files/bootstrap-solo" "$T/boot.orig"
python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("__ARCHIVE_URL__", "__ARCHIVE_URLX__"))' "$R/image/files/bootstrap-solo"
run_build; check "a missing __ARCHIVE_URL__ refuses, packer never runs" \
  "$([ $? -ne 0 ] && grep -q '__ARCHIVE_URL__' "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"
cp "$T/boot.orig" "$R/image/files/bootstrap-solo"
python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("__ARCHIVE_SHA256__", "__ARCHIVE_SHA256X__"))' "$R/image/files/bootstrap-solo"
run_build; check "a missing __ARCHIVE_SHA256__ refuses, packer never runs" \
  "$([ $? -ne 0 ] && grep -q '__ARCHIVE_SHA256__' "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"
{ cat "$T/boot.orig"; echo "ARCHIVE_URL='__ARCHIVE_URL__'"; } > "$R/image/files/bootstrap-solo"
run_build; check "a placeholder that occurs twice refuses, packer never runs" \
  "$([ $? -ne 0 ] && grep -q '__ARCHIVE_URL__' "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"
{ cat "$T/boot.orig"; echo "X='__OTHER_2__'"; } > "$R/image/files/bootstrap-solo"
run_build; check "any other placeholder, digits included, refuses, packer never runs" \
  "$([ $? -ne 0 ] && grep -q '__OTHER_2__' "$T/stderr" && [ ! -s "$T/packer.log" ]; echo $?)"
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

echo "== the publish workflow leaves time and credentials for the leftovers =="
# What can be asserted statically: the build step's own clock starts after
# the setup steps, whose length no file bounds, so the job keeps at least
# 45 minutes for those plus 15 for the leftovers and record steps (60 in all)
# beyond the build step's timeout; the role session lasts the whole job; the
# leftovers step runs exactly on a failure or a cancel, the record always.
check "job timeout ≥ build step timeout + 45 (setup, guard) + 15 (leftovers, record); role session ≥ job; the steps' if:" \
  "$(python3 -I - "$ROOT/.github/workflows/publish-hardened-image.yml" <<'PY'; echo $?
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["publish"]
steps = {s.get("name") or s.get("id"): s for s in job["steps"]}
build, creds = steps["build"], steps["aws-creds"]
names = [s.get("name") or s.get("id") for s in job["steps"]]
ok = (int(build["timeout-minutes"]) + 45 + 15 <= int(job["timeout-minutes"])
      and int(creds["with"]["role-duration-seconds"]) >= 60 * int(job["timeout-minutes"])
      and names.index("leftovers") > names.index("build") and names.index("record") > names.index("build")
      and str(steps["leftovers"].get("if", "")).strip() == "failure() || cancelled()"
      and str(steps["record"].get("if", "")).strip() == "always()")
sys.exit(0 if ok else 1)
PY
)"

echo "== the publish workflow's resolve step: which tags it builds =="
# The step's own script, run with a stub git whose ls-remote prints $REFS.
python3 -I -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["resolve"]["steps"][0]["run"])' \
  "$ROOT/.github/workflows/publish-hardened-image.yml" > "$T/resolve.sh"
mkdir -p "$T/rbin"
printf '#!/bin/sh\n[ "$1" = ls-remote ] || exit 99\ncat "$REFS"\n' > "$T/rbin/git"; chmod +x "$T/rbin/git"
A=$(printf 'a%.0s' {1..40}); B=$(printf 'b%.0s' {1..40}); C=$(printf 'c%.0s' {1..40}); D=$(printf 'd%.0s' {1..40})
# resolve EVENT REF_NAME PUBLIC — runs the step; its outputs land in $T/resolve.out.
resolve() {
  : > "$T/resolve.out"
  ( cd "$T" && env PATH="$T/rbin:$PATH" REFS="$T/refs" GITHUB_OUTPUT="$T/resolve.out" EVENT="$1" REF_TYPE=tag \
      REF_NAME="$2" RUN_SHA="$D" REPO_URL=https://example.invalid/r PUBLIC="$3" bash "$T/resolve.sh" ) > "$T/resolve.log" 2>&1
}
printf '%s\trefs/tags/v2.1.0\n%s\trefs/tags/v2.2.0-rc.1\n%s\trefs/tags/v2.2.0-rc.2\n%s\trefs/tags/v3.0.0-rc.1\n%s\trefs/tags/base-2.2.0\n' \
  "$A" "$B" "$C" "$C" "$C" > "$T/refs"
resolve schedule "" ""
check "the schedule builds the newest vX.Y.Z and skips every rc tag" \
  "$([ $? -eq 0 ] && grep -qx 'tag=v2.1.0' "$T/resolve.out" && grep -qx "sha=$A" "$T/resolve.out"; echo $?)"
printf '%s\trefs/tags/v2.2.0-rc.1\n' "$B" > "$T/refs"
resolve schedule "" ""
check "...and with only rc tags on origin it builds nothing" "$([ $? -ne 0 ] && [ ! -s "$T/resolve.out" ]; echo $?)"
resolve workflow_dispatch v2.2.0-rc.1 false
check "a dispatch on v2.2.0-rc.1 with public=false resolves it" \
  "$([ $? -eq 0 ] && grep -qx 'tag=v2.2.0-rc.1' "$T/resolve.out" && grep -qx "sha=$D" "$T/resolve.out"; echo $?)"
resolve workflow_dispatch v2.2.0-rc.1 true
check "a dispatch on v2.2.0-rc.1 with public=true is refused" \
  "$([ $? -ne 0 ] && grep -q 'pre-release tag' "$T/resolve.log" && [ ! -s "$T/resolve.out" ]; echo $?)"
resolve workflow_dispatch v2.2.0 true
check "a dispatch on v2.2.0 with public=true resolves it" "$([ $? -eq 0 ] && grep -qx 'tag=v2.2.0' "$T/resolve.out"; echo $?)"
for bad in v2.2.0-rc v2.2.0-rc.0 v2.2.0-rc.01 v2.2.0-rc.1.2 v2.2.0-beta.1 v2.2.0-rc.1x; do
  resolve workflow_dispatch "$bad" false
  check "a dispatch on $bad is refused" "$([ $? -ne 0 ] && grep -q 'not on' "$T/resolve.log" && [ ! -s "$T/resolve.out" ]; echo $?)"
done

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
