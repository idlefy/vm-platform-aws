#!/usr/bin/env bash
# image/files/dev-vm-image-scrub against a fake root built from the measured
# list in test/fixtures/image-scrub-paths. systemctl, cloud-init, fstrim and
# poweroff are shims that log; nothing here needs root or a VM.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRUB="$ROOT/image/files/dev-vm-image-scrub"
LIST="$ROOT/test/fixtures/image-scrub-paths"
PASS=0; FAIL=0
rc() { "$@"; echo $?; }   # status of a command as a word, for check
emptied() { [ -e "$1" ] && [ ! -s "$1" ]; }
untouched() { [ ! -s "$T/log" ] && [ ! -e "$R/etc/dev-vm/image-revision" ]; }
between() { [ "$1" -gt "$2" ] && [ "$1" -lt "$3" ]; }   # between N LOW HIGH
check() { if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REV=$(printf 'a%.0s' {1..64})
mkdir -p "$T/bin"
# shellcheck disable=SC2016 # $* and $SHIM_LOG expand in the shim, not here
for c in systemctl journalctl cloud-init fstrim poweroff; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$SHIM_LOG"\n' "$c" > "$T/bin/$c"; chmod +x "$T/bin/$c"
done
# `systemctl is-enabled` answers "nothing enabled" unless SHIM_ENABLED=0. A
# unit named in SHIM_MISSING does not exist: every verb naming it fails, as
# real systemctl does ("Unit … does not exist", "not loaded").
# shellcheck disable=SC2016
cat >> "$T/bin/systemctl" <<'SHIM'
# A unit named in SHIM_ENABLED_UNITS is enabled whatever SHIM_ENABLED says (the
# solo profile requires its first-boot unit enabled, every other unit off).
if [ "$1" = is-enabled ]; then
  for u in ${SHIM_ENABLED_UNITS:-}; do [ "${*: -1}" = "$u" ] && exit 0; done
  exit "${SHIM_ENABLED:-1}"
fi
# SHIM_FETCHED: the queued converge had fetched (and extracted) this other
# revision when it was stopped — mid-converge, so status and last-serial are
# still the bootstrap's.
[ "$*" = "stop cinc-client.service" ] && [ -n "${SHIM_FETCHED:-}" ] \
  && echo data > "$DEV_VM_IMAGE_ROOT/var/lib/dev-vm/policy/archives/$SHIM_FETCHED.tgz"
for a in "${@:2}"; do
  for m in ${SHIM_MISSING:-}; do [ "$a" = "$m" ] && exit 5; done
done
exit 0
SHIM
# shellcheck disable=SC2016
printf '[ -n "${SHIM_FAIL_CLOUDINIT:-}" ] && exit 1\nexit 0\n' >> "$T/bin/cloud-init"
# The solo profile's shims. Each logs like the others, then answers from the
# environment: by default a clean solo build (cinc purged and gone, sudoers
# valid, ubuntu in no admin group, no SSM snap).
# shellcheck disable=SC2016
{
  for c in dpkg dpkg-query visudo snap; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$SHIM_LOG"\n' "$c" > "$T/bin/$c"; chmod +x "$T/bin/$c"
  done
  # id logs only the call it answers: the scrub's own `id -u` (the non-root
  # guard) must stay invisible to the fleet sections' "ran nothing" checks.
  printf '#!/usr/bin/env bash\n' > "$T/bin/id"; chmod +x "$T/bin/id"
  printf 'exit "${SHIM_DPKG_RC:-0}"\n' >> "$T/bin/dpkg"
  printf '[ "${*: -1}" = cinc ] && [ -n "${SHIM_CINC_STILL_INSTALLED:-}" ] && exit 0\nexit 1\n' >> "$T/bin/dpkg-query"
  printf '[ "$1" = -c ] && exit "${SHIM_VISUDO_RC:-0}"\nexit 0\n' >> "$T/bin/visudo"
  printf '[ "$*" = "list amazon-ssm-agent" ] && [ -n "${SHIM_SSM_SNAP_PRESENT:-}" ] && exit 0\nexit 1\n' >> "$T/bin/snap"
  # Anything but `id -nG ubuntu` is the real id (the non-root check runs id -u).
  printf '[ "$*" = "-nG ubuntu" ] && { echo "id $*" >> "$SHIM_LOG"; echo "${SHIM_UBUNTU_GROUPS:-ubuntu docker}"; exit 0; }\nexec /usr/bin/id "$@"\n' >> "$T/bin/id"
}

build_root() {  # build_root DIR STATUS_LINE [FIXTURE]
  local r=$1 verb path
  rm -rf "$r"; mkdir -p "$r"
  while read -r verb path _; do
    case "$verb" in remove|empty|keep) ;; *) continue ;; esac
    path=${path//<rev>/$REV}
    p="$r${path//\*/x}"            # a glob becomes one concrete match
    mkdir -p "$(dirname "$p")"; echo data > "$p"
  done < <(grep -v '^\s*#' "${3:-$LIST}")
  mkdir -p "$r/var/lib/dev-vm/policy" "$r/etc/dev-vm"
  echo "$2" > "$r/var/lib/dev-vm/policy/status"
}

run_scrub() {  # run_scrub DIR [PROFILE] → exit status
  : > "$T/console"
  SHIM_LOG="$T/log" PATH="$T/bin:$PATH" DEV_VM_IMAGE_ROOT="$1" DEV_VM_IMAGE_CONSOLE="$T/console" \
    "$SCRUB" ${2:+--profile "$2"} "$REV" >"$T/out" 2>&1
}

echo "== a green build is scrubbed and powered off =="
R="$T/root"; : > "$T/log"
build_root "$R" "2026-10-16T00:00:00Z ok $REV"
run_scrub "$R"; check "exits 0" "$?"
while read -r verb path _; do
  path=${path//<rev>/$REV}
  p="$R${path//\*/x}"
  case "$verb" in
    remove) check "removed: $path" "$(rc [ ! -e "$p" ])" ;;
    empty)  check "emptied: $path" "$(rc emptied "$p")" ;;
    keep)   check "kept: $path"    "$(rc [ -s "$p" ])" ;;
  esac
done < <(grep -v '^\s*#' "$LIST" | grep -E '^(remove|empty|keep) ')
check "records the revision" "$(grep -qx "$REV" "$R/etc/dev-vm/image-revision"; echo $?)"
for u in cinc-client.timer aws-vm-credentials.timer alloy; do
  check "disables $u" "$(grep -q "systemctl disable .*$u" "$T/log"; echo $?)"
done
lineno() { grep -n "$1" "$T/log" | head -1 | cut -d: -f1; }
dis=$(lineno 'systemctl disable'); cln=$(lineno 'cloud-init clean')
for u in user@1000.service snap.amazon-ssm-agent.amazon-ssm-agent.service containerd fail2ban rsyslog falco-modern-bpf tailscaled \
         syslog.socket systemd-update-utmp systemd-random-seed; do
  stp=$(lineno "systemctl stop $u"); [ -n "$stp" ] || stp=0
  check "stops $u after disable and before cloud-init clean" "$(rc between "$stp" "${dis:-0}" "${cln:-0}")"
done
# A converge the timer queued behind the bootstrap's own runs the moment the
# lock frees, and re-enables the timers (measured on the first live build).
tst=$(lineno 'systemctl stop cinc-client.timer'); svc=$(lineno 'systemctl stop .*cinc-client.service')
check "stops cinc-client.timer, then cinc-client.service, then disables" \
  "$(rc between "${svc:-0}" "${tst:-0}" "${dis:-0}")"
sock=$(lineno 'systemctl stop syslog.socket'); rsl=$(lineno 'systemctl stop rsyslog')
check "stops syslog.socket before rsyslog, so nothing re-activates it" "$(rc between "${sock:-0}" 0 "${rsl:-0}")"
rlq=$(lineno 'journalctl --relinquish-var')
check "moves journald off /var before cloud-init clean" "$(rc between "${rlq:-0}" "${dis:-0}" "${cln:-0}")"
check "checks the timers are off before powering off" "$(grep -q 'systemctl is-enabled' "$T/log"; echo $?)"
check "cleans cloud-init with the machine id" "$(grep -q 'cloud-init clean --logs --machine-id' "$T/log"; echo $?)"
check "powers off last" "$(tail -1 "$T/log" | grep -q '^poweroff'; echo $?)"
echo "== fleet mode never purges cinc or runs the solo checks =="
check "no dpkg/visudo/snap/id in fleet mode" "$(! grep -qE '^(dpkg|dpkg-query|visudo|snap|id) ' "$T/log"; echo $?)"

echo "== a unit still enabled at the end means no image =="
: > "$T/log"; build_root "$R" "2026-10-16T00:00:00Z ok $REV"
SHIM_ENABLED=0 run_scrub "$R"; got=$?
check "a timer re-enabled behind the scrub → exit 70" "$(rc [ "$got" = 70 ])"
check "  …and says why on the console" "$(grep -q 're-enabled behind the scrub' "$T/console"; echo $?)"
check "  …and does not power off" "$(rc [ -z "$(grep '^poweroff' "$T/log")" ])"

echo "== a unit the policy never installed is not an error =="
# log_shipping = false purges alloy; a run_list may omit aws_access or cinc_client.
: > "$T/log"; build_root "$R" "2026-10-16T00:00:00Z ok $REV"
SHIM_MISSING="alloy aws-vm-credentials.timer aws-vm-credentials.service" run_scrub "$R"; got=$?
check "alloy and the credential units absent → exit 0" "$(rc [ "$got" = 0 ])"
check "  …and powers off" "$(tail -1 "$T/log" | grep -q '^poweroff'; echo $?)"
check "  …and still disables cinc-client.timer" "$(grep -q 'systemctl disable .*cinc-client.timer' "$T/log"; echo $?)"

echo "== a converge that fetched another revision behind the bootstrap means no image =="
: > "$T/log"; build_root "$R" "2026-10-16T00:00:00Z ok $REV"
SHIM_FETCHED=$(printf 'c%.0s' {1..64}) run_scrub "$R"; got=$?
check "another revision's archive on disk after the stops → exit 65" "$(rc [ "$got" = 65 ])"
check "  …says why on the console" "$(grep -q 'fetched another revision' "$T/console"; echo $?)"
check "  …and does not power off" "$(rc [ -z "$(grep '^poweroff' "$T/log")" ])"

echo "== any other failure says so on the console and powers nothing off =="
: > "$T/log"; build_root "$R" "2026-10-16T00:00:00Z ok $REV"
SHIM_FAIL_CLOUDINIT=1 run_scrub "$R"; got=$?
check "a failing step → non-zero exit" "$(rc [ "$got" != 0 ])"
check "  …names the line on the console" "$(grep -q 'internal error at line' "$T/console"; echo $?)"
check "  …and does not power off" "$(rc [ -z "$(grep '^poweroff' "$T/log")" ])"

echo "== it refuses anything but ok for the expected revision =="
for st in "2026-10-16T00:00:00Z converge-failed $REV" \
          "2026-10-16T00:00:00Z ok $(printf 'b%.0s' {1..64})" \
          ""; do
  : > "$T/log"; build_root "$R" "$st"
  run_scrub "$R"; rc=$?
  check "status '${st:-<empty>}' → exit 65" "$(rc [ "$rc" = 65 ])"
  # make ami's failure message sends the operator to the serial console.
  check "  …and says why on the console" "$(grep -q 'refusing: status is' "$T/console"; echo $?)"
  check "  …and touches nothing" "$(rc untouched)"
  check "  …and leaves a removable path alone" "$(rc [ -e "$R/etc/ssh/ssh_host_x" ])"
done
rm -f "$R/var/lib/dev-vm/policy/status"; : > "$T/log"
run_scrub "$R"; got=$?
check "no status file → exit 65" "$(rc [ "$got" = 65 ])"

echo "== a malformed argument is an internal error =="
SHIM_LOG="$T/log" PATH="$T/bin:$PATH" DEV_VM_IMAGE_ROOT="$R" "$SCRUB" "not-a-rev" >/dev/null 2>&1
got=$?
check "bad revision id → exit 70" "$(rc [ "$got" = 70 ])"

echo "== without DEV_VM_IMAGE_ROOT it refuses to run unless root =="
if [ "$(id -u)" != 0 ]; then
  : > "$T/log"
  env -u DEV_VM_IMAGE_ROOT SHIM_LOG="$T/log" PATH="$T/bin:$PATH" "$SCRUB" "$REV" >/dev/null 2>&1
  got=$?
  check "non-root, real root → exit 70" "$(rc [ "$got" = 70 ])"
  check "  …and ran nothing" "$(rc [ ! -s "$T/log" ])"
fi

echo "== the script's lists are the fixture's =="
fx=$(grep -E '^(remove|empty) ' "$LIST" | awk '{print $1" "$2}' | sort)
sc=$(awk '/^REMOVE=\(/{v="remove";next} /^EMPTY=\(/{v="empty";next} /^\)/{v="";next} v && $1 !~ /^#/ && NF {gsub(/"/,"",$1); print v" "$1}' "$SCRUB" 2>/dev/null | sort)
check "REMOVE/EMPTY equal the fixture's remove/empty lines" "$([ -n "$fx" ] && [ "$fx" = "$sc" ]; echo $?)"

# ---- solo profile: the hardened public image (base::solo) ----------------------
LIST_SOLO="$ROOT/test/fixtures/image-scrub-paths-solo"
# What base::solo leaves that the solo invariants read, in its real shape:
# idlefy-share root:root 0755, and rules.v6 as ip6tables-save writes it (the
# policy is a `:INPUT DROP` chain header, never a `-P` line).
seed_solo() {  # seed_solo DIR
  chmod 0755 "$1/usr/local/sbin/idlefy-share"
  cat > "$1/etc/iptables/rules.v6" <<'V6'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A OUTPUT -d fd00:ec2::254/128 -m owner --uid-owner 0 -j ACCEPT
-A OUTPUT -d fd00:ec2::254/128 -j DROP
COMMIT
V6
}
SOLO_STATE="$R/var/lib/dev-vm/policy"
FIRSTBOOT=idlefy-hardened-firstboot.service
# The solo code: sourced by the scrub from its own directory, embedded only in
# the solo build's user data (the scrub rides in every fleet VM's 16 KB).
SOLO="$ROOT/image/files/dev-vm-image-scrub-solo"

echo "== solo profile: a green build is scrubbed, cinc purged, powered off =="
build_root "$R" "2026-11-01T00:00:00Z ok $REV" "$LIST_SOLO"; seed_solo "$R"; : > "$T/log"
DEV_VM_POLICY_STATE="$SOLO_STATE" SHIM_ENABLED_UNITS="$FIRSTBOOT" run_scrub "$R" solo; check "exits 0" "$?"
while read -r verb path _; do
  p="$R${path//\*/x}"
  case "$verb" in
    remove) check "removed: $path" "$(rc [ ! -e "$p" ])" ;;
    empty)  check "emptied: $path" "$(rc emptied "$p")" ;;
    keep)   check "kept: $path"    "$(rc [ -s "$p" ])" ;;
  esac
done < <(grep -v '^\s*#' "$LIST_SOLO" | grep -E '^(remove|empty|keep) ')
check "purges cinc" "$(grep -q '^dpkg --purge cinc$' "$T/log"; echo $?)"
check "purge comes before cloud-init clean" "$(rc between "$(lineno 'dpkg --purge cinc')" 0 "$(lineno 'cloud-init clean')")"
check "checks the first-boot unit is enabled" "$(grep -q "systemctl is-enabled --quiet $FIRSTBOOT" "$T/log"; echo $?)"
check "checks sudoers with visudo -c" "$(grep -q '^visudo -c' "$T/log"; echo $?)"
check "checks ubuntu's groups" "$(grep -q '^id -nG ubuntu' "$T/log"; echo $?)"
check "checks the SSM snap is gone" "$(grep -q '^snap list amazon-ssm-agent' "$T/log"; echo $?)"
check "checks cinc is gone after the purge" "$(rc between "$(lineno '^dpkg-query .*cinc')" "$(lineno 'dpkg --purge cinc')" "$(lineno 'cloud-init clean')")"
check "records the sha" "$(grep -qx "$REV" "$R/etc/dev-vm/image-revision"; echo $?)"
check "powers off last" "$(tail -1 "$T/log" | grep -q '^poweroff'; echo $?)"
check "the status default is /run/dev-vm/solo" "$(grep -qF 'DEV_VM_POLICY_STATE:-/run/dev-vm/solo' "$SOLO"; echo $?)"

echo "== solo profile fails closed: every broken invariant → exit 70, console says which, no poweroff =="
# solo_refuses "LABEL" "CONSOLE SUBSTRING" "MUTATION (run in the fresh root)" [VAR=VALUE…]
solo_refuses() {
  local label=$1 want=$2 mutate=$3 got; shift 3
  build_root "$R" "2026-11-01T00:00:00Z ok $REV" "$LIST_SOLO"; seed_solo "$R"; : > "$T/log"
  ( cd "$R" && eval "$mutate" )
  ( export DEV_VM_POLICY_STATE="$SOLO_STATE" SHIM_ENABLED_UNITS="$FIRSTBOOT"
    for kv in "$@"; do export "${kv?}"; done
    run_scrub "$R" solo ); got=$?
  check "$label → exit 70" "$(rc [ "$got" = 70 ])"
  check "  …console names it ('$want')" "$(grep -qF -- "$want" "$T/console"; echo $?)"
  check "  …no poweroff" "$(! grep -q '^poweroff' "$T/log"; echo $?)"
  check "  …no cloud-init clean" "$(! grep -q 'cloud-init clean' "$T/log"; echo $?)"
}
solo_refuses "cinc purge fails"             "cinc purge failed"   ":" SHIM_DPKG_RC=1
solo_refuses "cinc still installed"         "cinc still installed" ":" SHIM_CINC_STILL_INSTALLED=1
solo_refuses "first-boot unit not enabled"  "idlefy-hardened-firstboot" ":" SHIM_ENABLED_UNITS=
solo_refuses "no cloud-init override"       "90-idlefy-hardened.cfg" "rm etc/cloud/cloud.cfg.d/90-idlefy-hardened.cfg"
solo_refuses "no tailscale grant"           "50-tailscale-login" "rm etc/sudoers.d/50-tailscale-login"
solo_refuses "no share grant"               "51-idlefy-share"    "rm etc/sudoers.d/51-idlefy-share"
solo_refuses "no share helper"              "idlefy-share"       "rm usr/local/sbin/idlefy-share"
solo_refuses "share helper mode 0775"       "idlefy-share"       "chmod 0775 usr/local/sbin/idlefy-share"
solo_refuses "visudo -c fails"              "visudo"             ":" SHIM_VISUDO_RC=1
solo_refuses "cloud-init's sudo grant back" "90-cloud-init-users" "touch etc/sudoers.d/90-cloud-init-users"
for g in sudo adm admin lxd; do
  solo_refuses "ubuntu in $g"               "ubuntu is in"       ":" SHIM_UBUNTU_GROUPS="ubuntu $g docker"
done
solo_refuses "rules.v6 without INPUT DROP"  "rules.v6" "printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' '-A OUTPUT -d fd00:ec2::254/128 -j DROP' > etc/iptables/rules.v6"
solo_refuses "rules.v6 without the IMDS drop" "rules.v6" "printf '%s\n' '*filter' ':INPUT DROP [0:0]' '-A OUTPUT -d fd00:ec2::254/128 -m owner --uid-owner 0 -j ACCEPT' > etc/iptables/rules.v6"
solo_refuses "SSM snap still installed"     "amazon-ssm-agent"   ":" SHIM_SSM_SNAP_PRESENT=1
solo_refuses "no /etc/dev-vm"               "/etc/dev-vm"        "rm -r etc/dev-vm"
check "  …and no image-revision written" "$(rc [ ! -e "$R/etc/dev-vm/image-revision" ])"

echo "== solo profile without its sibling file fails closed =="
mkdir -p "$T/alone"; cp "$SCRUB" "$T/alone/dev-vm-image-scrub"
build_root "$R" "2026-11-01T00:00:00Z ok $REV" "$LIST_SOLO"; seed_solo "$R"; : > "$T/log"
( SCRUB="$T/alone/dev-vm-image-scrub"
  DEV_VM_POLICY_STATE="$SOLO_STATE" SHIM_ENABLED_UNITS="$FIRSTBOOT" run_scrub "$R" solo ); got=$?
check "no dev-vm-image-scrub-solo next to the scrub → exit 70" "$(rc [ "$got" = 70 ])"
check "  …console names it" "$(grep -q 'dev-vm-image-scrub-solo' "$T/console"; echo $?)"
check "  …no poweroff" "$(! grep -q '^poweroff' "$T/log"; echo $?)"
check "  …no cloud-init clean" "$(! grep -q 'cloud-init clean' "$T/log"; echo $?)"
check "  …touched nothing" "$(rc untouched)"

echo "== whole-word group match: lxd-installer is not lxd =="
build_root "$R" "2026-11-01T00:00:00Z ok $REV" "$LIST_SOLO"; seed_solo "$R"; : > "$T/log"
DEV_VM_POLICY_STATE="$SOLO_STATE" SHIM_ENABLED_UNITS="$FIRSTBOOT" SHIM_UBUNTU_GROUPS="ubuntu lxd-installer sudoers adm1" \
  run_scrub "$R" solo; check "groups that only contain an admin group's name → exit 0" "$?"

echo "== the solo status file is checked like the fleet's =="
build_root "$R" "2026-11-01T00:00:00Z converge-failed $REV" "$LIST_SOLO"; seed_solo "$R"; : > "$T/log"
DEV_VM_POLICY_STATE="$SOLO_STATE" SHIM_ENABLED_UNITS="$FIRSTBOOT" run_scrub "$R" solo; got=$?
check "a failed solo converge → exit 65" "$(rc [ "$got" = 65 ])"
check "  …and purges nothing" "$(! grep -q '^dpkg' "$T/log"; echo $?)"

echo "== an unknown profile is an internal error =="
: > "$T/log"
SHIM_LOG="$T/log" PATH="$T/bin:$PATH" DEV_VM_IMAGE_ROOT="$R" DEV_VM_IMAGE_CONSOLE="$T/console" \
  "$SCRUB" --profile nope "$REV" >/dev/null 2>&1; got=$?
check "--profile nope → exit 70" "$(rc [ "$got" = 70 ])"
check "  …and ran nothing" "$(rc [ ! -s "$T/log" ])"

echo "== the solo lists are the solo fixture's =="
fx=$(grep -E '^(remove|empty) ' "$LIST_SOLO" | awk '{print $1" "$2}' | sort)
sc=$(awk '/^REMOVE_SOLO=\(/{v="remove";next} /^EMPTY_SOLO=\(/{v="empty";next} /^\)/{v="";next} v && $1 !~ /^#/ && NF {gsub(/"/,"",$1); print v" "$1}' "$SOLO" 2>/dev/null | sort)
check "REMOVE_SOLO/EMPTY_SOLO equal the solo fixture's remove/empty lines" "$([ -n "$fx" ] && [ "$fx" = "$sc" ]; echo $?)"

echo "== the fleet's scrub carries no solo code (its user data is capped at 16 KB) =="
check "no solo lists, purge or invariants in dev-vm-image-scrub" \
  "$(! grep -qE 'REMOVE_SOLO|EMPTY_SOLO|dpkg --purge|dpkg-query|visudo|snap list|id -nG|rules\.v6|idlefy-|sudoers\.d|fd00:ec2|/run/dev-vm/solo' "$SCRUB"; echo $?)"
# ---- bootstrap-solo: the build's user data ----------------------------------------
BOOT="$ROOT/image/files/bootstrap-solo"
UD="$ROOT/vms/modules/ec2/user_data.tf"
echo "== bootstrap-solo: the contracts Packer and the scrub depend on =="
check "parses (bash -n)" "$(bash -n "$BOOT" 2>/dev/null; echo $?)"
for v in CINC_VERSION CINC_SHA256; do
  a=$(grep -m1 -oE "^$v=\"[^\"]+\"" "$BOOT" 2>/dev/null); b=$(grep -m1 -oE "^$v=\"[^\"]+\"" "$UD")
  check "$v equals the module's ($b)" "$([ -n "$a" ] && [ "$a" = "$b" ]; echo $?)"
done
for ph in __ARCHIVE_URL__ __ARCHIVE_SHA256__; do
  check "exactly one $ph" "$(rc [ "$(grep -o "$ph" "$BOOT" 2>/dev/null | wc -l)" = 1 ])"
done
check "line 3 is the URL placeholder" "$(rc [ "$(sed -n 3p "$BOOT" 2>/dev/null)" = "ARCHIVE_URL='__ARCHIVE_URL__'" ])"
check "line 4 is the sha placeholder" "$(rc [ "$(sed -n 4p "$BOOT" 2>/dev/null)" = "ARCHIVE_SHA256='__ARCHIVE_SHA256__'" ])"
check "no DEV_VM_IMAGE_SCRUB line (Task 2b's heredoc terminator)" "$(! grep -qx 'DEV_VM_IMAGE_SCRUB' "$BOOT" 2>/dev/null && [ -f "$BOOT" ]; echo $?)"
check "ends in a newline" "$([ -s "$BOOT" ] && [ "$(tail -c1 "$BOOT" | od -An -c | tr -d ' ')" = '\n' ]; echo $?)"
check "stops the SSM agent before any download" \
  "$(a=$(grep -n 'snap stop --disable amazon-ssm-agent' "$BOOT" | head -1 | cut -d: -f1); b=$(grep -n '^ *curl ' "$BOOT" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; echo $?)"
check "refuses an archive that is not the solo policy" "$(grep -qF '.get("name") != "solo"' "$BOOT" 2>/dev/null; echo $?)"

echo; echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
