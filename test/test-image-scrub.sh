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
for c in systemctl journalctl cloud-init fstrim poweroff sync dd; do
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
# dd: never a real fill here. It writes a few bytes to of= and reports what
# SHIM_DD says: enospc (default, as a full filesystem ends the fill), other
# (another write error), ok (exit 0, no error), empty (ENOSPC after zero
# bytes), stuck (leaves a directory rm -f cannot remove).
# shellcheck disable=SC2016
cat >> "$T/bin/dd" <<'SHIM'
of=""; for a in "$@"; do case "$a" in of=*) of=${a#of=} ;; esac; done
case "${SHIM_DD:-enospc}" in
  enospc) printf 'zeros' > "$of"; echo "dd: error writing '$of': No space left on device" >&2; exit 1 ;;
  other)  printf 'zeros' > "$of"; echo "dd: error writing '$of': Input/output error" >&2; exit 1 ;;
  ok)     printf 'zeros' > "$of"; exit 0 ;;
  empty)  : > "$of"; echo "dd: error writing '$of': No space left on device" >&2; exit 1 ;;
  stuck)  mkdir -p "$of/x"; echo "dd: error writing '$of': No space left on device" >&2; exit 1 ;;
esac
SHIM
# The solo profile's shims. Each logs like the others, then answers from the
# environment: by default a clean solo build (cinc purged and gone, sudoers
# valid, ubuntu in no admin group, no SSM snap).
# shellcheck disable=SC2016
{
  for c in apt-get dpkg dpkg-query visudo snap; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$SHIM_LOG"\n' "$c" > "$T/bin/$c"; chmod +x "$T/bin/$c"
  done
  # id logs only the call it answers: the scrub's own `id -u` (the non-root
  # guard) must stay invisible to the fleet sections' "ran nothing" checks.
  printf '#!/usr/bin/env bash\n' > "$T/bin/id"; chmod +x "$T/bin/id"
  # apt-get: `purge … cinc` answers SHIM_PURGE_RC, `purge … snapd`
  # SHIM_SNAPD_PURGE_RC, `clean` SHIM_CLEAN_RC.
  printf 'case "$1 ${*: -1}" in "purge snapd") exit "${SHIM_SNAPD_PURGE_RC:-0}" ;; "clean clean") exit "${SHIM_CLEAN_RC:-0}" ;; esac\nexit "${SHIM_PURGE_RC:-0}"\n' >> "$T/bin/apt-get"
  printf 'exit 0\n' >> "$T/bin/dpkg"
  printf '[ "${*: -1}" = cinc ] && [ -n "${SHIM_CINC_STILL_INSTALLED:-}" ] && exit 0\n' >> "$T/bin/dpkg-query"
  printf '[ "${*: -1}" = snapd ] && [ -n "${SHIM_SNAPD_STILL_INSTALLED:-}" ] && { printf installed; exit 0; }\n' >> "$T/bin/dpkg-query"
  printf '[ "${*: -1}" = amazon-ssm-agent ] && [ -n "${SHIM_SSM_DEB_INSTALLED:-}" ] && { printf installed; exit 0; }\n' >> "$T/bin/dpkg-query"
  # A purged package dpkg still remembers answers not-installed.
  # SHIM_DPKGQ_ERR=<package>: dpkg-query cannot answer for it (exit 2).
  printf '[ "${*: -1}" = "${SHIM_DPKGQ_ERR:-}" ] && { echo "dpkg-query: error: cannot access archive: Permission denied" >&2; exit 2; }\n' >> "$T/bin/dpkg-query"
  printf '[ "${*: -1}" = snapd ] && { printf not-installed; exit 0; }\n' >> "$T/bin/dpkg-query"
  # Any other package is unknown to dpkg, as on a real image.
  printf 'echo "dpkg-query: no packages found matching ${*: -1}" >&2\nexit 1\n' >> "$T/bin/dpkg-query"
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
check "no dpkg/visudo/snap/id, no zero-fill in fleet mode" "$(! grep -qE '^(apt-get|dpkg|dpkg-query|visudo|snap|id|dd|sync)( |$)' "$T/log"; echo $?)"

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
  # `systemctl enable` makes the wants entry a symlink (relative here, so -s
  # can follow it inside the fake root).
  ln -sfn ../idlefy-hardened-firstboot.service \
    "$1/etc/systemd/system/multi-user.target.wants/idlefy-hardened-firstboot.service"
  printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'ec2-instance-connect:x:113:65534::/nonexistent:/usr/sbin/nologin' \
    'ubuntu:x:1000:1000::/home/ubuntu:/bin/bash' > "$1/etc/passwd"
  cat > "$1/etc/iptables/rules.v6" <<'V6'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A OUTPUT -d fd00:ec2::254/128 -m owner --uid-owner 0 -j ACCEPT
-A OUTPUT -d fd00:ec2::254/128 -j DROP
COMMIT
V6
  # rules.v4 as iptables-save writes what base::firewall and base::imds install
  # (`iptables -P INPUT DROP`; `iptables -I OUTPUT 1|3 -d 169.254.169.254 …`).
  cat > "$1/etc/iptables/rules.v4" <<'V4'
*filter
:INPUT DROP [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A OUTPUT -d 169.254.169.254/32 -m owner --uid-owner 0 -j ACCEPT
-A OUTPUT -d 169.254.169.254/32 -j DROP
COMMIT
V4
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
PURGE='apt-get purge -y -o DPkg::Lock::Timeout=300 cinc'
check "purges cinc, waiting for the dpkg lock" "$(grep -qx "$PURGE" "$T/log"; echo $?)"
check "purge comes before cloud-init clean" "$(rc between "$(lineno '^apt-get purge')" 0 "$(lineno 'cloud-init clean')")"
check "checks the first-boot unit is enabled" "$(grep -q "systemctl is-enabled --quiet $FIRSTBOOT" "$T/log"; echo $?)"
check "checks sudoers with visudo -c" "$(grep -q '^visudo -c' "$T/log"; echo $?)"
check "checks ubuntu's groups" "$(grep -q '^id -nG ubuntu' "$T/log"; echo $?)"
check "checks the SSM snap is gone" "$(grep -q '^snap list amazon-ssm-agent' "$T/log"; echo $?)"
SNAPD_PURGE='apt-get purge -y -o DPkg::Lock::Timeout=300 snapd'
check "purges snapd, waiting for the dpkg lock" "$(grep -qx "$SNAPD_PURGE" "$T/log"; echo $?)"
check "  …after the SSM snap check and the cinc purge" \
  "$([ "$(lineno '^snap list amazon-ssm-agent')" -lt "$(lineno "^$SNAPD_PURGE\$")" ] && [ "$(lineno "^$PURGE\$")" -lt "$(lineno "^$SNAPD_PURGE\$")" ]; echo $?)"
check "cloud-init clean, then the zero-fill of /, after every check and before poweroff" \
  "$(c=$(lineno '^cloud-init clean'); d=$(lineno "^dd if=/dev/zero of=$R/.idlefy-zero-fill bs=1M status=none\$"); \
     [ -n "$c" ] && [ -n "$d" ] && [ "$(lineno '^visudo -c')" -lt "$c" ] && [ "$(lineno '^id -nG ubuntu')" -lt "$c" ] \
     && [ "$(lineno '^dpkg-query .*cinc$')" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$(lineno '^poweroff')" ]; echo $?)"
check "  …synced, the file removed, synced again" \
  "$([ "$(grep -c '^sync' "$T/log")" = 2 ] && [ "$(lineno '^dd ')" -lt "$(lineno '^sync')" ] && [ ! -e "$R/.idlefy-zero-fill" ]; echo $?)"
check "  …and the removals all came before it (nothing on the lists is left)" \
  "$(! grep -v '^\s*#' "$LIST_SOLO" | awk '$1 == "remove" { print $2 }' | while read -r g; do compgen -G "$R$g" >/dev/null && echo left; done | grep -q left; echo $?)"
check "  …then cleans apt's cache" "$([ "$(lineno "^$SNAPD_PURGE\$")" -lt "$(lineno '^apt-get clean$')" ]; echo $?)"
check "checks snapd and an SSM package are gone after the purge" \
  "$(between "$(lineno '^dpkg-query .*snapd$')" "$(lineno "^$SNAPD_PURGE\$")" "$(lineno 'cloud-init clean')" \
     && grep -q '^dpkg-query .*amazon-ssm-agent$' "$T/log"; echo $?)"
check "checks cinc is gone after the purge" "$(rc between "$(lineno '^dpkg-query .*cinc')" "$(lineno '^apt-get purge')" "$(lineno 'cloud-init clean')")"
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
solo_refuses "cinc purge fails"             "cinc purge failed"   ":" SHIM_PURGE_RC=1
solo_refuses "cinc still installed"         "cinc still installed" ":" SHIM_CINC_STILL_INSTALLED=1
solo_refuses "cinc-client on disk though dpkg says gone" "/opt/cinc/bin/cinc-client" \
  "rm opt/cinc && mkdir -p opt/cinc/bin && echo x > opt/cinc/bin/cinc-client"
solo_refuses "first-boot unit not enabled"  "idlefy-hardened-firstboot" ":" SHIM_ENABLED_UNITS=
solo_refuses "unit enabled but no wants link on disk" "multi-user.target.wants" \
  "rm etc/systemd/system/multi-user.target.wants/idlefy-hardened-firstboot.service"
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
solo_refuses "INPUT DROP only in *mangle"   "rules.v6" "printf '%s\n' '*mangle' ':INPUT DROP [0:0]' 'COMMIT' '*filter' ':INPUT ACCEPT [0:0]' '-A OUTPUT -d fd00:ec2::254/128 -j DROP' 'COMMIT' > etc/iptables/rules.v6"
solo_refuses "IMDS drop in another chain"   "rules.v6" "printf '%s\n' '*filter' ':INPUT DROP [0:0]' '-A FORWARD -d fd00:ec2::254/128 -j DROP' 'COMMIT' > etc/iptables/rules.v6"
solo_refuses "IMDS drop only in *mangle"    "rules.v6" "printf '%s\n' '*mangle' '-A OUTPUT -d fd00:ec2::254/128 -j DROP' 'COMMIT' '*filter' ':INPUT DROP [0:0]' 'COMMIT' > etc/iptables/rules.v6"
# Both lines present, but the file stops before *filter's COMMIT (truncated):
# ip6tables-restore would apply nothing of that table.
solo_refuses "rules.v6 truncated before COMMIT" "rules.v6" "printf '%s\n' '*filter' ':INPUT DROP [0:0]' '-A OUTPUT -d fd00:ec2::254/128 -j DROP' > etc/iptables/rules.v6"
solo_refuses "no rules.v4"                  "/etc/iptables/rules.v4 is missing" "rm etc/iptables/rules.v4"
solo_refuses "rules.v4 INPUT policy ACCEPT" "rules.v4 has no INPUT DROP" "printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' '-A OUTPUT -d 169.254.169.254/32 -j DROP' 'COMMIT' > etc/iptables/rules.v4"
solo_refuses "rules.v4 without the IMDS drop" "rules.v4 does not drop 169.254.169.254" "printf '%s\n' '*filter' ':INPUT DROP [0:0]' '-A OUTPUT -d 169.254.169.254/32 -m owner --uid-owner 0 -j ACCEPT' 'COMMIT' > etc/iptables/rules.v4"
solo_refuses "rules.v4 IMDS drop only in *mangle" "rules.v4 does not drop" "printf '%s\n' '*mangle' '-A OUTPUT -d 169.254.169.254/32 -j DROP' 'COMMIT' '*filter' ':INPUT DROP [0:0]' 'COMMIT' > etc/iptables/rules.v4"
solo_refuses "rules.v4 truncated before COMMIT" "rules.v4" "printf '%s\n' '*filter' ':INPUT DROP [0:0]' '-A OUTPUT -d 169.254.169.254/32 -j DROP' > etc/iptables/rules.v4"

# An accept for every user before the metadata drop defeats it, wherever the
# drop sits; owner-matched accepts (base::imds: root, Instance Connect) do not,
# and an accept after the drop never fires for that address.
# solo_passes "LABEL" "MUTATION" — the scrub exits 0 and powers off.
solo_passes() {
  local label=$1 mutate=$2 got
  build_root "$R" "2026-11-01T00:00:00Z ok $REV" "$LIST_SOLO"; seed_solo "$R"; : > "$T/log"
  ( cd "$R" && eval "$mutate" )
  ( export DEV_VM_POLICY_STATE="$SOLO_STATE" SHIM_ENABLED_UNITS="$FIRSTBOOT"; run_scrub "$R" solo ); got=$?
  check "$label → exit 0, powers off" "$([ "$got" = 0 ] && tail -1 "$T/log" | grep -q '^poweroff'; echo $?)"
}
# Before the drop only an allowlist may stand: root's and Instance Connect's
# owner allows (the uid read from the image's /etc/passwd; seed_solo gives
# ec2-instance-connect uid 113). Anything else there refuses; nothing after
# the drop is restricted.
NO_EIC="printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'ubuntu:x:1000:1000::/home/ubuntu:/bin/bash' > etc/passwd"
for fam in "4 169.254.169.254/32 169.254.0.0/16" "6 fd00:ec2::254/128 fd00:ec2::/64"; do
  set -- $fam; v=$1 a=$2 wide=$3; f="etc/iptables/rules.v$v"
  root="-A OUTPUT -d $a -m owner --uid-owner 0 -j ACCEPT"
  # pre LINE — rules.v$v with root's allow, then LINE, then the drop.
  pre() { printf "printf '%%s\\\\n' '*filter' ':INPUT DROP [0:0]' ':OUTPUT ACCEPT [0:0]' '%s' '%s' '-A OUTPUT -d %s -j DROP' 'COMMIT' > %s" "$root" "$1" "$a" "$f"; }
  for bad in "-A OUTPUT -d $a -j ACCEPT" \
             "-A OUTPUT -j ACCEPT" \
             "-A OUTPUT -d $a -p tcp -m tcp --dport 80 -j ACCEPT" \
             "-A OUTPUT -d $a -m owner --uid-owner 1000 -j ACCEPT" \
             "-A OUTPUT -d $a -m owner --uid-owner 0-1000 -j ACCEPT" \
             "-A OUTPUT -d $a -m owner ! --uid-owner 1000 -j ACCEPT" \
             "-A OUTPUT -d $a -m owner --gid-owner 0 -j ACCEPT" \
             "-A OUTPUT -d $wide -m owner --uid-owner 0 -j ACCEPT" \
             "-A OUTPUT -p tcp -j ACCEPT" \
             "-A OUTPUT -j RETURN" \
             "-A OUTPUT -j ts-output" \
             "-A OUTPUT -d 10.0.0.0/8 -j ACCEPT" \
             "[0:0] -A OUTPUT -d $a -m owner --uid-owner 0 -j ACCEPT"; do
    solo_refuses "v$v before the drop: $bad" "rules.v$v has an OUTPUT rule before its IMDS drop" "$(pre "$bad")"
  done
  solo_refuses "v$v: Instance Connect's allow when this image has no such user" \
    "rules.v$v has an OUTPUT rule before its IMDS drop" "$NO_EIC; $(pre "-A OUTPUT -d $a -m owner --uid-owner 113 -j ACCEPT")"
  solo_refuses "v$v: an unreadable rules file" "rules.v$v" "chmod 000 $f; mv $f $f.x; mkdir $f"
  solo_passes "v$v: root's and Instance Connect's allows, then the drop" \
    "$(pre "-A OUTPUT -d $a -m owner --uid-owner 113 -j ACCEPT")"
  solo_passes "v$v: no Instance Connect user, root's allow only" \
    "$NO_EIC; printf '%s\n' '*filter' ':INPUT DROP [0:0]' '$root' '-A OUTPUT -d $a -j DROP' 'COMMIT' > $f"
  solo_passes "v$v: no allow at all, the drop first (fail closed)" \
    "printf '%s\n' '*filter' ':INPUT DROP [0:0]' '-A OUTPUT -d $a -j DROP' 'COMMIT' > $f"
  solo_passes "v$v: anything after the drop (the drop wins)" \
    "printf '%s\n' '*filter' ':INPUT DROP [0:0]' '$root' '-A OUTPUT -d $a -j DROP' '-A OUTPUT -d $a -j ACCEPT' '-A OUTPUT -j ACCEPT' '-A OUTPUT -j ts-output' 'COMMIT' > $f"
  solo_passes "v$v: Docker and Tailscale chains elsewhere, a nat OUTPUT jump" \
    "printf '%s\n' '*nat' ':OUTPUT ACCEPT [0:0]' '-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER' 'COMMIT' '*filter' ':INPUT DROP [0:0]' ':FORWARD DROP [0:0]' ':OUTPUT ACCEPT [0:0]' ':DOCKER-USER - [0:0]' ':ts-input - [0:0]' '-A INPUT -j ts-input' '-A FORWARD -j DOCKER-USER' '$root' '-A OUTPUT -d $a -m owner --uid-owner 113 -j ACCEPT' '-A OUTPUT -d $a -j DROP' 'COMMIT' > $f"
done
set --
solo_refuses "SSM snap still installed"     "amazon-ssm-agent"   ":" SHIM_SSM_SNAP_PRESENT=1
# snap list fails when snapd is unreachable; the disk still tells.
# build_root seeds /snap and /var/lib/snapd as plain files (the list removes
# them); a real snap needs them as directories. Checked before snapd's purge
# and the lists, which would remove the evidence.
solo_refuses "SSM snap mounted though snap list fails" "amazon-ssm-agent" "rm snap && mkdir -p snap/amazon-ssm-agent/current"
solo_refuses "SSM snap file though snap list fails"    "amazon-ssm-agent" \
  "rm var/lib/snapd && mkdir -p var/lib/snapd/snaps && echo x > var/lib/snapd/snaps/amazon-ssm-agent_1234.snap"
check "  …and snapd was not purged first" "$(! grep -q '^apt-get purge .* snapd$' "$T/log"; echo $?)"
solo_refuses "snapd purge fails"            "snapd purge failed" ":" SHIM_SNAPD_PURGE_RC=1
solo_refuses "apt-get clean fails"          "apt-get clean failed" ":" SHIM_CLEAN_RC=1
solo_refuses "snapd still installed"        "snapd still installed" ":" SHIM_SNAPD_STILL_INSTALLED=1
solo_refuses "an SSM agent package"         "amazon-ssm-agent still installed" ":" SHIM_SSM_DEB_INSTALLED=1
for pkg in cinc snapd amazon-ssm-agent; do
  solo_refuses "dpkg-query cannot answer for $pkg (exit 2)" "$pkg still installed, or dpkg cannot say" ":" SHIM_DPKGQ_ERR=$pkg
done
for f in usr/bin/snap usr/lib/snapd/snapd; do
  solo_refuses "/$f left behind"            "/$f is still on disk" "mkdir -p \"\$(dirname $f)\" && touch $f"
done
solo_refuses "a user unit left: snapd.session-agent.socket" "snap or SSM units are left" \
  "mkdir -p usr/lib/systemd/user && touch usr/lib/systemd/user/snapd.session-agent.socket"
solo_refuses "a user enablement link left" "snap or SSM units are left" \
  "mkdir -p etc/systemd/user/sockets.target.wants && ln -s /usr/lib/systemd/user/snapd.session-agent.socket etc/systemd/user/sockets.target.wants/snapd.session-agent.socket"
solo_refuses "a unit directory find cannot read" "cannot scan /etc/systemd/user" \
  "mkdir -p etc/systemd/user/x && chmod 000 etc/systemd/user"
chmod 755 "$R/etc/systemd/user"   # so the next build_root can remove it
solo_passes "a directory named like a unit is not a unit" "mkdir -p etc/systemd/system/snap.d-not-a-unit"
# A failed fill refuses after cloud-init clean has run (it must free its
# files before the fill), so these check the rest by hand.
fill_refuses() {  # fill_refuses LABEL CONSOLE MODE
  local got
  build_root "$R" "2026-11-01T00:00:00Z ok $REV" "$LIST_SOLO"; seed_solo "$R"; : > "$T/log"
  ( export DEV_VM_POLICY_STATE="$SOLO_STATE" SHIM_ENABLED_UNITS="$FIRSTBOOT" SHIM_DD="$3"; run_scrub "$R" solo ); got=$?
  check "$1 → exit 70, console names it, no poweroff" \
    "$([ "$got" = 70 ] && grep -qF -- "$2" "$T/console" && ! grep -q '^poweroff' "$T/log"; echo $?)"
}
fill_refuses "the fill ends on another write error" "did not end on a full filesystem" other
fill_refuses "the fill ends without an error"       "did not end on a full filesystem" ok
fill_refuses "the fill writes nothing"              "wrote nothing" empty
fill_refuses "the fill file cannot be removed"      "zero-fill file /.idlefy-zero-fill is still on disk" stuck
chmod -R u+rwx "$R" 2>/dev/null || true
for u in etc/systemd/system/snap-core22-1380.mount etc/systemd/system/multi-user.target.wants/snap-lxd-1.mount \
         usr/lib/systemd/system/snapd.service etc/systemd/system/snap.amazon-ssm-agent.amazon-ssm-agent.service \
         lib/systemd/system/amazon-ssm-agent.service; do
  solo_refuses "a unit left: $u"            "snap or SSM units are left" "mkdir -p \"\$(dirname $u)\" && touch $u"
done
# The lists remove /var/lib/snapd and /snap; the check after them catches a
# list that lost either line (a scrub whose sibling lacks them).
for gone in /var/lib/snapd /snap; do
  mkdir -p "$T/nolist"; cp "$SCRUB" "$T/nolist/dev-vm-image-scrub"
  grep -vxF "  \"$gone\" # $(grep -F "  \"$gone\" #" "$SOLO" | sed 's/^[^#]*# //')" "$SOLO" > "$T/nolist/dev-vm-image-scrub-solo"
  check "the test copy lacks $gone" "$(! grep -qF "  \"$gone\" #" "$T/nolist/dev-vm-image-scrub-solo"; echo $?)"
  build_root "$R" "2026-11-01T00:00:00Z ok $REV" "$LIST_SOLO"; seed_solo "$R"; : > "$T/log"
  ( SCRUB="$T/nolist/dev-vm-image-scrub"; export DEV_VM_POLICY_STATE="$SOLO_STATE" SHIM_ENABLED_UNITS="$FIRSTBOOT"
    run_scrub "$R" solo ); got=$?
  check "a list without $gone → exit 70, named, no poweroff" \
    "$([ "$got" = 70 ] && grep -qF "$gone is still on disk after the snapd purge" "$T/console" && ! grep -q '^poweroff' "$T/log"; echo $?)"
done
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
check "  …and purges nothing" "$(! grep -qE '^(apt-get|dpkg)' "$T/log"; echo $?)"

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
  "$(! grep -qE 'REMOVE_SOLO|EMPTY_SOLO|apt-get|dpkg --purge|dpkg-query|visudo|snap list|id -nG|rules\.v6|idlefy-|sudoers\.d|fd00:ec2|/run/dev-vm/solo' "$SCRUB"; echo $?)"
echo "== the solo file's embed contract (Task 2b writes it with a heredoc) =="
check "solo file: no DEV_VM_IMAGE_SCRUB line" "$(! grep -qx 'DEV_VM_IMAGE_SCRUB' "$SOLO" && [ -f "$SOLO" ]; echo $?)"
check "solo file: ends in a newline" "$([ -s "$SOLO" ] && [ "$(tail -c1 "$SOLO" | od -An -c | tr -d ' ')" = '\n' ]; echo $?)"
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
first_line() { grep -n "$1" "$BOOT" | head -1 | cut -d: -f1; }
before_curl() { local a b; a=$(first_line "$1"); b=$(first_line '^ *curl '); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
check "waits for snapd's seed before any download" "$(rc before_curl '^timeout 600 snap wait system seed.loaded')"
check "stops the SSM agent before any download" "$(rc before_curl 'snap stop --disable amazon-ssm-agent')"
check "  …after the seed wait" \
  "$(rc [ "$(first_line '^timeout 600 snap wait')" -lt "$(first_line 'snap stop --disable amazon-ssm-agent')" ])"
check "  …and stops its unit directly too" "$(rc before_curl '^systemctl stop snap.amazon-ssm-agent.amazon-ssm-agent.service')"
# A stock image has no apt lists: the converge's first package would have no
# candidate (measured on the first build). Refreshed after the policy is
# vetted, before the converge, and under the ERR trap (a failure is reported).
check "apt-get update before the converge, after the policy check" \
  "$(a=$(first_line '^apt-get update -qq$'); b=$(first_line '^if ! cinc-client -z '); c=$(first_line 'does not name the solo policy'); \
     d=$(first_line '^trap bootstrap_failed ERR$'); \
     [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ "$c" -lt "$a" ] && [ "$a" -lt "$b" ] && [ "$d" -lt "$a" ]; echo $?)"

# Run a rendered copy up to its guards: every absolute path it writes is moved
# under $T, every command it would run before them is a shim.
echo "== bootstrap-solo refuses an unrendered placeholder before any network call =="
mkdir -p "$T/bb"
# shellcheck disable=SC2016
for c in snap systemctl timeout curl install; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$SHIM_LOG"\n' "$c" > "$T/bb/$c"; chmod +x "$T/bb/$c"
done
boot_run() {  # boot_run URL SHA → exit status; the log is $T/blog
  local s
  s=$(<"$BOOT")
  s=${s//__ARCHIVE_URL__/$1}; s=${s//__ARCHIVE_SHA256__/$2}
  s=${s//\/var\/log\//$T/bv/}; s=${s//\/dev\/console/$T/bconsole}
  s=${s//\/etc\//$T/be/}; s=${s//\/run\/dev-vm/$T/br}
  mkdir -p "$T/bv" "$T/be"; : > "$T/blog"; : > "$T/bconsole"
  printf '%s\n' "$s" > "$T/boot.sh"
  SHIM_LOG="$T/blog" PATH="$T/bb:$PATH" bash "$T/boot.sh" >/dev/null 2>&1
}
boot_run '__ARCHIVE_URL__' "$REV"; got=$?
check "unrendered URL, rendered sha → fails" "$(rc [ "$got" != 0 ])"
check "  …before any curl" "$(! grep -q '^curl' "$T/blog"; echo $?)"
check "  …and says why on the console" "$(grep -q 'ARCHIVE_URL is not an https URL' "$T/bconsole"; echo $?)"
boot_run 'https://example.invalid/solo.tgz' '__ARCHIVE_SHA256__'; got=$?
check "rendered URL, unrendered sha → fails" "$(rc [ "$got" != 0 ])"
check "  …before any curl" "$(! grep -q '^curl' "$T/blog"; echo $?)"
check "  …and says why on the console" "$(grep -q 'ARCHIVE_SHA256 is not a sha256' "$T/bconsole"; echo $?)"
boot_run 'https://example.invalid/solo.tgz' "$REV"
check "both rendered → reaches the CINC download (the guards pass)" "$(grep -q '^curl .*cinc' "$T/blog"; echo $?)"
check "refuses an archive that is not the solo policy" "$(grep -qF '.get("name") != "solo"' "$BOOT" 2>/dev/null; echo $?)"

echo; echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
