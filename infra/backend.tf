# Backend config lives in backend.hcl (gitignored, per-tenant).
# Copy backend.hcl.example to backend.hcl, fill in values, then:
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
