# ============================================================================
# Named AWS permission bundles.
#
# This is the ONLY place external policy ARNs appear. A bundle is granted to a
# VM by listing its name in that VM's `aws_access` in instances.auto.tfvars.
#
# Same-account managed policies only. A managed policy cannot be attached across
# accounts, so cross-account access would need role chaining; the design record
# says why it is not here:
# https://idlefy.github.io/vm-platform-aws/design/per-vm-aws-access/
#
# The policies themselves are owned by whoever owns the resource. We only
# reference them.
#
# `allowed_actions` is REQUIRED and is the ceiling this bundle needs. Every VM's
# permissions boundary allows only the union of allowed_actions across the
# bundles granted to it, so anything a policy grants outside these namespaces is
# denied — including grants its owner added without telling us. Declare services,
# not exact actions: "s3:*" is the right entry for a bundle whose policy grants
# three S3 actions on one prefix. The policy is still what decides.
#
# The literal "*" is rejected at plan time. If a bundle genuinely needs a service
# that looks dangerous, that is a conversation, not a config change.
# ============================================================================

# --- Example ---
#
# access_bundles = {
#   # The common case: one policy, one service.
#   "s3-media-dev" = {
#     description     = "RW on s3://example-media/dev-prefix/* — owned by the team that owns the bucket"
#     policy_arns     = ["arn:aws:iam::111122223333:policy/s3-media-dev"]
#     allowed_actions = ["s3:*"]
#   }
#
#   # A bundle may carry more than one policy, and allowed_actions is the union of
#   # what they need. Note kms: reading an SSE-KMS encrypted object needs
#   # kms:Decrypt, and leaving it out is the single most common way to get an
#   # AccessDenied that names a service you never thought about.
#   "athena-analytics-ro" = {
#     description     = "Read-only Athena + its results bucket — owned by @data"
#     policy_arns     = [
#       "arn:aws:iam::111122223333:policy/athena-query-ro",
#       "arn:aws:iam::111122223333:policy/athena-results-rw",
#     ]
#     allowed_actions = ["athena:*", "glue:Get*", "s3:*", "kms:Decrypt"]
#   }
# }
#
# Then in instances.auto.tfvars, on the VM that should get them:
#
#   aws_access = ["s3-media-dev", "athena-analytics-ro"]
#
# A VM's ceiling is the union of allowed_actions across the bundles it was granted.
# Granting nothing is a valid, and the default, state.

access_bundles = {}
