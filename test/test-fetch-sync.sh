#!/usr/bin/env bash
# dev-vm-policy-fetch has two copies, and this proves they are one file.
#
#   vms/modules/ec2/files/dev-vm-policy-fetch            user_data installs it at
#                                                        first boot, before any
#                                                        converge can deliver it
#   cinc/cookbooks/base/files/default/dev-vm-policy-fetch base::cinc_client replaces
#                                                        it on running VMs
#
# boundary-check keeps the module from reading cinc/, so the two cannot share a
# source file. A difference means new VMs and running VMs verify policy with
# different code, and the suite (test-policy-fetch.sh) exercises only one of
# them. The comparison is byte-identity, for the reason test-skeleton-sync.sh
# gives. It runs in both release gates, since either tag can ship a copy.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/vms/modules/ec2/files/dev-vm-policy-fetch"
B="$ROOT/cinc/cookbooks/base/files/default/dev-vm-policy-fetch"

for f in "$A" "$B"; do
  [ -f "$f" ] || { echo "  FAIL ${f#"$ROOT"/} is missing"; exit 1; }
done
if cmp -s "$A" "$B"; then
  echo "  ok   the module and cookbook copies of dev-vm-policy-fetch are identical"
  exit 0
fi
echo "  FAIL the module and cookbook copies of dev-vm-policy-fetch differ:"
diff -u "$A" "$B" | head -40
exit 1
