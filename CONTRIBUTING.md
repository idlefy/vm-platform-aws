# Contributing

Thanks for looking. This repository is a template that publishes two artifacts
and deploys nothing, so a contribution is a change to one of them — the CINC
cookbook under `cinc/cookbooks/base/`, or the Terraform modules and tenant
skeleton under `vms/modules/` and `tenant-skeleton/`.

[`CLAUDE.md`](CLAUDE.md) is the working guide: how the two artifacts are
consumed, the traps that have actually bitten this platform, and the hard rules.
Read it before a first change — most of it is evidence you would otherwise have
to re-measure.

## Run the gates before you open the pull request

```bash
make boundary-check                                    # modules stay inside themselves
( cd vms/modules/ec2          && terraform test )      # 26 runs
( cd vms/modules/fleet-guards && terraform test )      # 5 runs
make smoke                                             # the skeleton against this tree
for t in test/test-release-gate.sh test/test-resolve-pin.sh test/test-boundary-check.sh \
         test/test-placeholder-check.sh test/test-prepare.sh test/test-pin-to-worktree.sh \
         test/test-preflight.sh test/test-skeleton-sync.sh test/test-get-started-skill.sh; do "$t"; done
( cd cinc && make lint && make test && make test-broker && make test-loki-token )
make test-pin-check                                    # root target; needs chef
mkdocs build --strict
```

None of it touches AWS: every `terraform test` uses `mock_provider`, the broker
and Loki-token tests stub `aws` on `PATH`, and the pin tests build their own
bare repository in a temp directory. You need Terraform (≥1.7 for the tests,
which use `mock_provider`), CINC Workstation for the `cinc` targets and
`test-pin-check`, and `mkdocs-material` for the docs build.

`.github/workflows/ci.yml` runs the same list on every pull request, split by
stream; `.github/workflows/docs.yml` runs the docs build. The three lists — this
one, `CLAUDE.md`'s and CI's — are kept in step by hand, so if you add a test,
add it to all three.

CodeRabbit reviews every pull request against `main` automatically
(`.coderabbit.yaml`). Treat its comments as a first reader, not a gate.

## One pull request per stream

The two artifacts are versioned independently, and a release cuts one tag at a
time against one set of gates:

| Stream | Publishes | Gates | Lockstep |
|---|---|---|---|
| `base-X.Y.Z` | `cinc/cookbooks/base/**` | `cookstyle`, `chefspec`, `test-broker`, `test-loki-token` | `metadata.rb` must say `X.Y.Z`, byte for byte |
| `vX.Y.Z` | `vms/modules/**` + `tenant-skeleton/**` | `boundary-check`, `test-skeleton-sync`, `smoke` | none — the module carries no version string |

A pull request that changes both is a pull request that cannot be released as
one thing. Split it, unless the change genuinely spans the two — in which case
say so in the description, because it will need two tags in a defined order.

A few consequences worth knowing before you start:

- **A cookbook change includes its `metadata.rb` version bump.** That version is
  what a tenant reads out of its lock to know what it is running, and
  `make release` refuses a `base-X.Y.Z` tag whose suffix does not match it.
- **A module input change includes `tenant-skeleton/`, in the same commit.** The
  module interface is a contract; `make smoke` is what turns that from a hope
  into a rule.
- **`scripts/` and `tenant-skeleton/scripts/` are byte-identical** for
  `resolve-pin.sh`, `pin-check.sh`, `preflight.sh`, `add-region.sh` and
  `placeholder-check.sh`. Edit the one under `scripts/`, then
  `cp scripts/<f> tenant-skeleton/scripts/<f>`. `test-skeleton-sync.sh` checks it.

## Tags are cut by `make release`, and only by `make release`

```bash
make release TAG=base-X.Y.Z
make release TAG=vX.Y.Z
git push origin <tag>
```

The target refuses a dirty tree, refuses a `HEAD` that consumers cannot reach,
prints the SHA before the gates run, and tags *that* SHA rather than whatever
`HEAD` becomes afterwards. A tag cut by hand certifies a tree nobody gated, and
a tenant that pins it has no way to tell. This is not a maintainer convenience —
`pin-check` in every tenant compares its lock against what the tag resolves to
now, so a tag that moved is reported to all of them as a mismatch.

Cutting a release is a maintainer action. Contributors do not need to.

## What makes a change easy to accept

The documentation in this repository has a house style, and it is the same one
that applies to code comments: say what was measured, when, and what it
contradicted. A claim about behaviour is worth more with the command that
produced it than with an adjective. Where a control exists because something
failed silently, the failure is the interesting half.

If you are proposing a new Falco rule, read the header of
`cinc/cookbooks/base/files/default/falco-dev-vm-rules.yaml` first: it records
the ideas already rejected and why, and the bar is that the rule must be made to
fire on a staging VM before it is believed.
