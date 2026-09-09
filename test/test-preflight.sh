#!/usr/bin/env bash
# scripts/preflight.sh against shimmed terraform/aws/curl/knife. Nothing here
# touches AWS. Each scenario builds a throwaway tenant tree (vms/ + the
# policyfile), points PATH at the shims, runs preflight, and greps its output.
#
# The terraform shim answers `console` with a canned jsonencode() result — a
# JSON string, double-encoded exactly as the real console prints it.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/vms/.terraform" "$T/cinc/policyfiles" "$T/scripts"
cp "$ROOT/scripts/preflight.sh" "$T/scripts/preflight.sh"
# The migrated-root marker preflight looks for before blaming the configuration.
printf 'variable "log_shipping" { type = bool }\n' > "$T/vms/variables.tf"
# The wiring line preflight greps for in vms/main.tf. Every scenario below
# needs this present to reach the checks it's testing for — the one scenario
# testing its absence writes its own main.tf and restores this afterward.
wired_main_tf() {
  printf 'module "ec2" {\n  log_shipping = var.log_shipping\n}\n' > "$T/vms/main.tf"
}
wired_main_tf

cat > "$T/bin/terraform" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  console)   cat >/dev/null; cat "$PREFLIGHT_FIXTURE" ;;
  providers) exit 0 ;;
  *)         exit 1 ;;
esac
SH
cat > "$T/bin/aws" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$AWS_LOG"
case "$1 $2" in
  "sts get-caller-identity")  exit 0 ;;
  "ssm describe-parameters")  echo SecureString ;;
  "ssm get-parameter")        echo not-a-real-token ;;
  "iam get-policy")           exit 0 ;;
  *)                          exit 1 ;;
esac
SH
cat > "$T/bin/curl"  <<'SH'
#!/usr/bin/env bash
echo 400
SH
cat > "$T/bin/knife" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$T/bin/"*

# fixture <shipping:true|false> <loki:name|null>  → writes the console answer
fixture() {
  python3 - "$1" "$2" > "$T/fixture.json" <<'PY'
import json, sys
shipping = sys.argv[1] == "true"
loki = None if sys.argv[2] == "null" else sys.argv[2]
inner = json.dumps({"regions": ["eu-central-1"], "loki": loki, "shipping": shipping,
                    "cinc": "/t/cinc", "profile": "p", "bundles": {}})
print(json.dumps(inner))
PY
}

run_preflight() {
  : > "$T/aws.log"
  PATH="$T/bin:$PATH" PREFLIGHT_FIXTURE="$T/fixture.json" AWS_LOG="$T/aws.log" \
    "$T/scripts/preflight.sh" > "$T/out" 2>&1
  echo $?
}

PF="$T/cinc/policyfiles/dev-vm.rb"

echo "== half-migrated root: main.tf never passes log_shipping to the module =="
# vms/variables.tf was copied from the new skeleton (console reads
# var.log_shipping fine) but vms/main.tf was not — the module never receives
# the flag, so it runs its own default (true) no matter what the root reports.
# console succeeding is exactly the false-green this check exists to catch.
fixture true /t/loki
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = true
default['base']['loki']['ssm_parameter_name'] = '/t/loki'
default['base']['loki']['url']                = 'https://l.example.com/push'
default['base']['loki']['username']           = '1'
RB
printf 'module "ec2" {\n  # log_shipping missing — half-migrated root\n}\n' > "$T/vms/main.tf"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names vms/main.tf" "$(grep -q 'vms/main.tf does not pass log_shipping' "$T/out"; echo $?)"
wired_main_tf

echo "== the pass-through outside module \"ec2\" does not count =="
# A file-wide match would accept this: the assignment exists, but in `locals`,
# and module "ec2" still runs its own default (true).
fixture false ""
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = false
RB
printf 'locals {\n  log_shipping = var.log_shipping\n}\nmodule "ec2" {\n  environment = "x"\n}\n' > "$T/vms/main.tf"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names vms/main.tf" "$(grep -q 'vms/main.tf does not pass log_shipping' "$T/out"; echo $?)"
wired_main_tf

echo "== both on and agreeing =="
fixture true /t/loki
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = true
default['base']['loki']['ssm_parameter_name'] = '/t/loki'
default['base']['loki']['url']                = 'https://l.example.com/push'
default['base']['loki']['username']           = '1'
RB
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "flag section says both say true" "$(grep -q 'both say true' "$T/out"; echo $?)"
check "parameter names agree" "$(grep -q "both name '/t/loki'" "$T/out"; echo $?)"
check "loki token was checked" "$(grep -q 'ssm get-parameter' "$T/aws.log"; echo $?)"

echo "== policyfile omits enabled: cookbook default applies =="
sed -i '/enabled/d' "$PF"
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "says the cookbook default applies" "$(grep -q 'cookbook default true applies' "$T/out"; echo $?)"

echo "== a commented-out enabled line is not a setting =="
printf '# default[%s][%s][%s] = false\n' "'base'" "'loki'" "'enabled'" >> "$PF"
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "still the cookbook default" "$(grep -q 'cookbook default true applies' "$T/out"; echo $?)"

echo "== terraform on, policyfile off: mismatch fails =="
cat > "$PF" <<'RB'
default['base']['loki']['enabled'] = false
RB
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names both values" "$(grep -q 'log_shipping=true.*enabled=false' "$T/out"; echo $?)"

echo "== both off: loki checks are skipped, cinc still checked =="
fixture false null
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "three skipped lines" "$([ "$(grep -c 'log shipping disabled — skipped' "$T/out")" = 3 ]; echo $?)"
check "no loki parameter lookup" "$(! grep -q 'Values=/t/loki' "$T/aws.log"; echo $?)"
check "no token fetch" "$(! grep -q 'ssm get-parameter' "$T/aws.log"; echo $?)"
check "cinc parameter still checked" "$(grep -q 'Values=/t/cinc' "$T/aws.log"; echo $?)"

echo "== both off but the policyfile still carries loki lines: warn, not fail =="
cat > "$PF" <<'RB'
default['base']['loki']['enabled']  = false
default['base']['loki']['url']      = 'https://l.example.com/push'
default['base']['loki']['username'] = '1'
RB
rc=$(run_preflight)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)"
check "warns naming url" "$(grep -q 'leftover.*url' "$T/out"; echo $?)"
check "warns naming username" "$(grep -q 'leftover.*username' "$T/out"; echo $?)"

echo "== terraform off, policyfile on: reverse mismatch names the empty parameter, never calls aws for it =="
fixture false ""
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = true
default['base']['loki']['ssm_parameter_name'] = '/t/loki'
default['base']['loki']['url']                = 'https://l.example.com/push'
default['base']['loki']['username']           = '1'
RB
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names MISMATCH" "$(grep -q 'MISMATCH' "$T/out"; echo $?)"
check "names the missing parameter" "$(grep -q 'MISSING (no loki_ssm_parameter_name' "$T/out"; echo $?)"
check "no get-parameter call for the empty name" "$(! grep -q 'ssm get-parameter' "$T/aws.log"; echo $?)"

echo "== missing policyfile is a named failure =="
fixture true /t/loki
rm -f "$PF"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names the policyfile path" "$(grep -q "$PF" "$T/out"; echo $?)"
cat > "$PF" <<'RB'
default['base']['loki']['enabled']            = true
default['base']['loki']['ssm_parameter_name'] = '/t/loki'
default['base']['loki']['url']                = 'https://l.example.com/push'
default['base']['loki']['username']           = '1'
RB

echo "== unparseable console output is a named failure, not set -u =="
echo '"{\"regions\":[\"eu-central-1\"]' > "$T/fixture.json"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "no unbound variable" "$(! grep -q 'unbound variable' "$T/out"; echo $?)"
check "blames the configuration" "$(grep -q 'configuration itself is at fault' "$T/out"; echo $?)"

echo "== a root that does not declare log_shipping is told so =="
rm "$T/vms/variables.tf"
rc=$(run_preflight)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)"
check "names the skeleton" "$(grep -q 'does not declare log_shipping' "$T/out"; echo $?)"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
