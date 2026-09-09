---
name: get-started
description: Use when someone has just cloned vm-platform-aws and asks what it is, how to start, or wants their own tenant repository — orients them, checks tools, creates the tenant repository from tenant-skeleton/ and hands off to the tenant-setup skill inside it. Deploys nothing.
---

# Get started with vm-platform-aws

You take a newcomer from "I cloned this" to "I have my own tenant repository,
ready for `tenant-setup`". You create that repository and **stop**. Everything
inside it — `make prepare`, the pin, the six tenant files, the cookbook tag —
belongs to the `tenant-setup` skill that ships in the skeleton, because that
skill decides "already configured?" by looking at those files, and touching
them here would make it think the tenant is done while every value is still a
placeholder.

## 1. Orient

Say this, in your own words, in three short paragraphs, then ask whether they
want a tenant repository created now:

- This repository is a **template**. It publishes a CINC cookbook (`base-X.Y.Z`
  tags) and two Terraform modules with a tenant skeleton (`vX.Y.Z` tags). Nothing
  deploys from here.
- A **tenant** is a private repository generated from `tenant-skeleton/`. It
  holds only configuration: regions, VMs, SSH keys, the CINC server, the
  Grafana stack. Modules and cookbook are pinned artifacts it fetches over
  HTTPS.
- VMs run in the user's own AWS account, hardened by the cookbook on first boot
  and re-converged every 30 minutes. Every VM is tagged `idlefy = "enabled"` so
  Idlefy can start and stop it on the developer's schedule; the platform grants
  Idlefy nothing — the tag is a label, the boundary is Idlefy's own IAM role.

If they only wanted the explanation, stop here.

## 2. Prerequisites check

Run these and report what is missing. Install nothing.

```bash
gh auth status
terraform version        # ≥ 1.5 to deploy; ≥ 1.7 to run the skeleton's own test
aws --version
chef --version           # Cinc Workstation (or Chef Workstation) ≥ 25
git --version
```

The skeleton consumes this platform over HTTPS, so no SSH key to GitHub is
needed. A missing tool is not a blocker for creating the repository; say which
step will need it (`terraform` and `chef` for `tenant-setup`, `aws` for the
first `plan`).

## 3. Collect

One question at a time:

1. GitHub owner and repository name for the tenant (suggest
   `<owner>/<team>-vm-tenant`).
2. Private? Default **yes** — it will hold configuration. Only make it public
   if they say so explicitly.
3. Show the newest platform release so they know what `tenant-setup` will pin,
   but do **not** resolve it here:

```bash
git tag --list 'v*' --sort=-v:refname | head -1
```

If the clone has no tags (a shallow clone), `git fetch --tags` first.

## 4. Create

From the platform clone's parent directory, so the tenant lands beside it:

```bash
cd ..
gh repo create <owner>/<name> --private --clone
cp -r vm-platform-aws/tenant-skeleton/. <name>/
cd <name>
git add -A
git commit -m "chore: tenant from vm-platform-aws <tag>"
git push
```

That is all. Nothing else runs here: no `make prepare`, no `bump-cookbook`,
nothing that touches AWS or a CINC server. The `.example` files are copied as
they are — never write a real value into one.

## 5. Hand off

Print the tenant path and say: open it, run `claude`, and the `tenant-setup`
skill there will resolve the platform pin, collect the AWS profile, Route53
zone, regions, CINC server values and the Loki settings, materialise the
config, and stop before any `apply`.

Also say, once:

- If their AWS account is not connected to Idlefy yet, onboarding is at
  https://idlefy.com; the VMs will carry the `idlefy = "enabled"` tag by
  default either way, and a single VM opts out with
  `tags = { idlefy = "disabled" }` in `instances.auto.tfvars`.
- The runbook for everything after `tenant-setup` is
  https://idlefy.github.io/vm-platform-aws/runbook/.

## Hard limits

These inherit the tenant's own `CLAUDE.md` rules that already apply before a
tenant exists.

- Never run `terraform apply`, `make push`, `make promote`, `make prepare`,
  `ansible-playbook`, or anything that uses AWS credentials.
- Never write a real value into any `.example` file.
- Never read `vault.yml` or `vault.yml.example` contents beyond copying the
  file.
- Never echo a secret's value; report exit status instead.
- Never create the repository public unless the user says so.
