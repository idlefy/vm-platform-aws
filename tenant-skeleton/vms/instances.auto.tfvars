# ============================================================================
# VM instances and SSH keys per region.
#
# This file is auto-loaded by Terraform (.auto.tfvars) and IS checked into git
# — it's the team's running ledger of who has a VM where.
#
# Per-tenant globals (Route53, AWS profile, CINC URL) live in tenant.auto.tfvars
# (gitignored). VPC/subnets/SG/regions are in config.tf.
# ============================================================================

# --- Example: all available instance options ---
#
# instances = {
#   "<region>" = {
#     "<vm-name>" = {
#       instance_type  = "m7a.xlarge"                        # Required: EC2 instance type
#       volume_size_gb = 100                                 # Required: root EBS volume size in GB
#       az             = "<region>a"                         # Optional: AZ, defaults to region's default_az
#       fqdn           = "name.ec2.<region>.<your-domain>"   # Required: DNS A-record in your Route53 zone
#       key_name       = "username"                          # Required: SSH key pair name (must exist in ssh_key_pairs below)
#       ami_id         = "ami-xxx"                           # Optional: override AMI, defaults to latest Ubuntu 24.04 LTS
#                                                            #   Set this to hold a VM on an older release; running VMs
#                                                            #   ignore AMI changes (lifecycle.ignore_changes) and are
#                                                            #   never recreated by a new default.
#       policy_group   = "production"                        # Optional: CINC policy group, defaults to "production"
#                                                            #   Set to "staging" for a test VM so it converges against
#                                                            #   what `make push` published, before `make promote` puts
#                                                            #   that revision on the whole fleet. Only read at first
#                                                            #   boot — changing it later needs a rebuild.
#       policy_name    = "dev-vm"                            # Optional: CINC policyfile name, defaults to "dev-vm"
#                                                            #   One policyfile per VM (CINC design — not composable like roles).
#                                                            #   Available policies: dev-vm
#                                                            #   To add a new policy: create cinc/policyfiles/<name>.rb, then make push + promote
#       aws_access     = ["s3-media-dev"]                    # Optional: AWS permission bundles, defaults to []
#                                                            #   Names must exist in access_bundles.auto.tfvars
#                                                            #   Grants same-account managed policies to this VM's
#                                                            #   identity role, and sets that role's permissions
#                                                            #   boundary to the services those bundles declared.
#                                                            #   Cross-account access is not supported; the design
#                                                            #   record says why:
#                                                            #   https://idlefy.github.io/vm-platform-aws/design/per-vm-aws-access/
#       tags = {
#         Owner = "username"                                 # Tag for ownership tracking
#         # idlefy = "disabled"                              # opt this one VM out of Idlefy
#       }
#     }
#   }
# }

instances = {
  "us-east-1"  = {}
  "eu-north-1" = {}
}

ssh_key_pairs = {
  "us-east-1"  = {}
  "eu-north-1" = {}
}
