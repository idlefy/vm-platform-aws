# Versioning

Two independent tag streams, cut by `make release` in this repository. The
public history starts at `1.0.0` for both.

| Stream | Publishes | Gated by | A tenant pins it in |
|---|---|---|---|
| `base-X.Y.Z` | `cinc/cookbooks/base/**` | `cookstyle`, ChefSpec, the credential-broker and Loki-token tests; `metadata.rb` must say `X.Y.Z` byte for byte | `cinc/policyfiles/dev-vm.rb` — `cookbook 'base', git: …, tag: 'base-X.Y.Z'` |
| `vX.Y.Z` | `vms/modules/**` and `tenant-skeleton/**` | `boundary-check`, `test-skeleton-sync`, the skeleton smoke test | `vms/main.tf` — `?ref=<full sha>` on both module sources, with the tag in a trailing comment |

The two move independently: a cookbook fix is a `base-` tag with no `v` tag,
and a module change is the reverse. A change to a module *input* always ships
with a matching `tenant-skeleton/` change in the same commit, so a tenant
that re-materialises the skeleton at the new tag gets both halves together.

## Why the Terraform pin is a SHA, not a tag

Terraform resolves `?ref=` at `init` time and a tag can be moved; a SHA
cannot. `make prepare PLATFORM_TAG=vX.Y.Z` in a tenant resolves the tag to
the commit it names (peeling an annotated tag to its commit) and writes the
SHA into `vms/main.tf` next to the tag name, so the file says what was
intended and pins what was resolved.

## Why the cookbook pin is a tag

`chef update` records the tag in the lock together with the cookbook's
content identifier, and a converge uses the lock. The tenant's
`make pin-check` compares the lock's recorded revision against the tag on
the remote and refuses to promote a policy whose tag has moved.

## Upgrading a tenant

- **Cookbook:** edit the `tag:` in `cinc/policyfiles/dev-vm.rb`, run
  `make bump-cookbook`, then `make push` and `make promote` through
  staging as usual.
- **Modules and skeleton:** `make prepare PLATFORM_TAG=vX.Y.Z` re-resolves
  the pin; read the diff of the skeleton files it re-materialises before
  committing, then `terraform plan`.

Tags are immutable by convention; nothing on GitHub enforces it, which is
why `pin-check` exists.
