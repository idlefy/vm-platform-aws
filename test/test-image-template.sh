#!/usr/bin/env bash
# packer fmt + validate on image/, with dummy inputs. No AWS: validate does not
# call the API. Also pins the decisions the template must not drift from.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/image/dev-vm.pkr.hcl"
PASS=0; FAIL=0
check() { if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }
command -v packer >/dev/null || { echo "packer not on PATH"; exit 2; }

check "template exists" "$([ -f "$T" ] && echo 0 || echo 1)"
check "packer fmt -check" "$(packer fmt -check "$T" >/dev/null 2>&1; echo $?)"
UD="$(mktemp)"; trap 'rm -f "$UD"' EXIT; printf '#!/bin/bash\n' | gzip > "$UD"
INIT="$(cd "$ROOT/image" && packer init . 2>&1)" || { echo "packer init failed:"; echo "$INIT"; }
check "packer validate" "$(cd "$ROOT/image" && packer validate \
  -var aws_profile=x -var build_region=eu-central-1 -var 'ami_regions=["eu-central-1","us-east-1"]' \
  -var user_data_file="$UD" -var policy_bucket=b -var policy_prefix=p -var policy_name=dev-vm \
  -var revision_id="$(printf 'a%.0s' {1..64})" -var platform_sha="$(printf 'c%.0s' {1..40})" \
  -var cookbook_version=2.0.1 . >/dev/null 2>&1; echo $?)"
check "builds only from production" "$(grep -q 'PolicyGroup *= *"production"' "$T"; echo $?)"
check "never connects to the instance" "$(grep -q 'communicator *= *"none"' "$T" && grep -q 'disable_stop_instance *= *true' "$T"; echo $?)"
check "IMDS tags on, tokens required" "$(grep -q 'instance_metadata_tags *= *"enabled"' "$T" && grep -q 'http_tokens *= *"required"' "$T"; echo $?)"
# Exact set, not absence: the build's profile may read the bucket and decrypt, nothing else.
ACTIONS="$(grep -v '^[[:space:]]*#' "$T" | grep -E '^[[:space:]]*Action[[:space:]]*=' | sed 's/^[[:space:]]*//' | sort)"
WANT="$(printf '%s\n' 'Action   = ["kms:Decrypt"]' 'Action   = ["s3:GetObject"]')"
check "build profile actions are exactly s3:GetObject and kms:Decrypt" "$([ "$ACTIONS" = "$WANT" ] && [ "$(printf '%s\n' "$ACTIONS" | wc -l)" -eq 2 ] && echo 0 || echo 1)"
check "the module's source image" "$(grep -q '099720109477' "$T" && grep -qF 'ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' "$T"; echo $?)"
echo; echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
