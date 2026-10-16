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

build_root() {  # build_root DIR STATUS_LINE
  local r=$1 verb path
  rm -rf "$r"; mkdir -p "$r"
  while read -r verb path _; do
    case "$verb" in remove|empty|keep) ;; *) continue ;; esac
    p="$r${path//\*/x}"            # a glob becomes one concrete match
    mkdir -p "$(dirname "$p")"; echo data > "$p"
  done < <(grep -v '^\s*#' "$LIST")
  mkdir -p "$r/var/lib/dev-vm/policy" "$r/etc/dev-vm"
  echo "$2" > "$r/var/lib/dev-vm/policy/status"
}

run_scrub() {  # run_scrub DIR → exit status
  SHIM_LOG="$T/log" PATH="$T/bin:$PATH" DEV_VM_IMAGE_ROOT="$1" "$SCRUB" "$REV" >"$T/out" 2>&1
}

echo "== a green build is scrubbed and powered off =="
R="$T/root"; : > "$T/log"
build_root "$R" "2026-10-16T00:00:00Z ok $REV"
run_scrub "$R"; check "exits 0" "$?"
while read -r verb path _; do
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
for u in user@1000.service snap.amazon-ssm-agent.amazon-ssm-agent.service containerd fail2ban rsyslog falco-modern-bpf tailscaled; do
  stp=$(lineno "systemctl stop $u"); [ -n "$stp" ] || stp=0
  check "stops $u after disable and before cloud-init clean" "$(rc between "$stp" "${dis:-0}" "${cln:-0}")"
done
check "cleans cloud-init with the machine id" "$(grep -q 'cloud-init clean --logs --machine-id' "$T/log"; echo $?)"
check "powers off last" "$(tail -1 "$T/log" | grep -q '^poweroff'; echo $?)"

echo "== it refuses anything but ok for the expected revision =="
for st in "2026-10-16T00:00:00Z converge-failed $REV" \
          "2026-10-16T00:00:00Z ok $(printf 'b%.0s' {1..64})" \
          ""; do
  : > "$T/log"; build_root "$R" "$st"
  run_scrub "$R"; rc=$?
  check "status '${st:-<empty>}' → exit 65" "$(rc [ "$rc" = 65 ])"
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

echo; echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
