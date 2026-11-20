#!/usr/bin/env bash
# packer fmt + validate on image/hardened/, with dummy inputs. No AWS: validate
# does not call the API. Also pins the decisions Idlefy's public hardened image
# must not drift from: unencrypted and public, no instance profile, a fixed
# security group, never connecting, IMDSv2 with no tag reading, the fence tag.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/image/hardened"
T="$DIR/hardened.pkr.hcl"
PASS=0; FAIL=0
check() { if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }
command -v packer >/dev/null || { echo "packer not on PATH"; exit 2; }

check "template exists" "$([ -f "$T" ] && echo 0 || echo 1)"
check "packer fmt -check" "$(packer fmt -check "$T" >/dev/null 2>&1; echo $?)"
UD="$(mktemp)"; S="$(mktemp)"; trap 'rm -f "$UD" "$S"' EXIT; printf '#!/bin/bash\n' | gzip > "$UD"
INIT="$(cd "$DIR" 2>/dev/null && packer init . 2>&1)" || { echo "packer init failed:"; echo "$INIT"; }
check "packer validate" "$(cd "$DIR" 2>/dev/null && packer validate \
  -var build_region=us-east-1 -var 'ami_regions=["us-east-1","eu-central-1"]' \
  -var ami_name=idlefy-hardened-agent-ubuntu-24.04-amd64-20261101-01 \
  -var user_data_file="$UD" -var platform_tag=v2.2.0 \
  -var platform_sha="$(printf 'c%.0s' {1..40})" -var base_tag=base-2.1.0 \
  -var archive_sha256="$(printf 'a%.0s' {1..64})" -var public=true \
  -var attached_org_id= -var security_group_id=sg-0f0f0f0f0f0f0f0f0 . >/dev/null 2>&1; echo $?)"

# Every grep below reads the template with its comments stripped: the header
# explains why there is no instance profile and no timestamp, and must not
# satisfy (or trip) the checks that pin those decisions.
grep -v '^[[:space:]]*#' "$T" > "$S" 2>/dev/null
check "root disk is not encrypted" "$(grep -q 'encrypted *= *false' "$S" && ! grep -q 'encrypted *= *true' "$S"; echo $?)"
check "the boot image is not re-encrypted" "$(grep -q 'encrypt_boot *= *false' "$S"; echo $?)"
check "public when asked" "$(grep -q 'ami_groups *= *var.public ? \["all"\] : null' "$S"; echo $?)"
check "no instance profile of any kind" "$(! grep -q 'iam_instance_profile\|temporary_iam_instance_profile' "$S"; echo $?)"
check "never connects, waits for self-stop" "$(grep -q 'communicator *= *"none"' "$S" && grep -q 'disable_stop_instance *= *true' "$S"; echo $?)"
check "IMDSv2, hop 1, no tag reading" "$(grep -q 'http_tokens *= *"required"' "$S" && grep -q 'http_put_response_hop_limit *= *1$' "$S" && ! grep -q 'instance_metadata_tags.*enabled' "$S"; echo $?)"
check "the name is an input, not a timestamp" "$(grep -q 'ami_name *= *var.ami_name' "$S" && ! grep -q 'timestamp()' "$S"; echo $?)"
check "Canonical noble amd64 source" "$(grep -q '099720109477' "$S" && grep -qF 'ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' "$S"; echo $?)"
check "the fence tag" "$(grep -q 'IdlefyPublishedImage *= *"true"' "$S"; echo $?)"
check "no PolicyGroup run tag" "$(! grep -q PolicyGroup "$S"; echo $?)"
# block NAME — the lines of the first `NAME = {` or `NAME {` block of the
# comment-stripped template, up to its first closing brace (none is nested).
block() { awk -v n="$1" '$0 ~ "^[[:space:]]*" n "[[:space:]]*(=[[:space:]]*)?[{]" { on = 1; next } on && /^[[:space:]]*[}]/ { exit } on' "$S"; }
check "the build instance is tagged for the IAM fence" "$(block run_tags | grep -q 'Name *= *"idlefy-hardened-image-build"'; echo $?)"
check "...and so is its volume" "$(block run_volume_tags | grep -q 'Name *= *"idlefy-hardened-image-build"'; echo $?)"
check "the AMI and its snapshots carry the provenance tags" "$(grep -q '^[[:space:]]*tags *= *local.tags$' "$S" && grep -q '^[[:space:]]*snapshot_tags *= *local.tags$' "$S"; echo $?)"
check "the description carries the visibility, on every copy; the record writes the same string" \
  "$(grep -qF 'ami_description    = "Idlefy hardened image for AI agents; visibility=${var.public ? "public" : "private"}"' "$S" \
     && grep -qF '"description": "Idlefy hardened image for AI agents; visibility=%s"' "$ROOT/scripts/hardened-image-build.sh" \
     && grep -qF '"Idlefy hardened image for AI agents; visibility=(public|private)"' "$ROOT/scripts/hardened-image-retire.sh"; echo $?)"
check "only # comments (the strip above knows no other kind)" "$(! grep -q '//\|/[*]' "$S"; echo $?)"
check "ami_name is validated against the published pattern" "$(block 'validation' | grep -qF 'can(regex("^idlefy-hardened-agent-ubuntu-24\\.04-amd64-[0-9]{8}-[0-9]{2}$", var.ami_name))'; echo $?)"
check "a fixed security group, never a temporary one" "$(grep -q 'security_group_ids *= *\[var.security_group_id\]' "$S" && ! grep -q temporary_security_group "$S"; echo $?)"
check "its own directory" "$([ ! -e "$ROOT/image/hardened.pkr.hcl" ] && [ "$(ls "$DIR"/*.pkr.hcl 2>/dev/null | wc -l)" = 1 ] && [ "$(ls "$ROOT"/image/*.pkr.hcl | wc -l)" = 1 ] && echo 0 || echo 1)"
check "regions file: build region first, one region per line, no duplicates" "$(R="$(grep -v '^[[:space:]]*\(#\|$\)' "$DIR/regions" 2>/dev/null)" \
  && [ "$(printf '%s\n' "$R" | head -1)" = us-east-1 ] \
  && ! printf '%s\n' "$R" | grep -qvE '^[a-z]{2}-[a-z]+-[0-9]$' \
  && [ -z "$(printf '%s\n' "$R" | sort | uniq -d)" ] && echo 0 || echo 1)"
echo; echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
