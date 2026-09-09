# The fleet-wide guards, tested where they are computed.
#
# No mock_provider and no provider block: this module declares no resources.
#
# Note the tolist() in every equality assertion. Measured: comparing an output
# of type list(string) against a bracket literal fails with "LHS and RHS values
# are of different types" — the literal is a tuple. An assertion written without
# it fails on a correct module, which is how a working guard gets deleted.

variables {
  regions       = ["eu-central-1", "us-east-1"]
  instances     = {}
  ssh_key_pairs = {}
}

run "a_clean_fleet_reports_nothing" {
  command = plan
  variables {
    instances = {
      "eu-central-1" = {
        "alice" = { instance_type = "t3.micro", volume_size_gb = 20, fqdn = "a.test.invalid", key_name = "k", aws_access = ["b"], tags = {} }
      }
      "us-east-1" = {
        "bob" = { instance_type = "t3.small", volume_size_gb = 30, fqdn = "d.test.invalid", key_name = "k" }
      }
    }
    ssh_key_pairs = {
      "eu-central-1" = { "k" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST dev@test" }
    }
  }
  assert {
    condition     = length(output.duplicate_vm_names) == 0
    error_message = "a fleet with distinct names reported duplicates: ${jsonencode(output.duplicate_vm_names)}"
  }
  assert {
    condition     = length(output.orphan_region_keys) == 0
    error_message = "a fleet using only configured regions reported orphans: ${jsonencode(output.orphan_region_keys)}"
  }
}

# This run carries the full per-VM object shape on purpose: it is what proves
# map(map(object({}))) accepts the real thing rather than only a stripped fixture.

run "a_name_in_two_regions_is_reported" {
  command = plan
  variables {
    instances = {
      "eu-central-1" = { "dup" = { instance_type = "t3.micro", volume_size_gb = 20, fqdn = "a.test.invalid", key_name = "k" } }
      "us-east-1"    = { "dup" = { instance_type = "t3.small", volume_size_gb = 30, fqdn = "b.test.invalid", key_name = "k" } }
    }
  }
  assert {
    condition     = output.duplicate_vm_names == tolist(["dup"])
    error_message = "expected [dup], got ${jsonencode(output.duplicate_vm_names)}"
  }
}

# --- both routes into the orphan guard -------------------------------------
# The instances route has a second line of defence (the VM never appears, which
# someone eventually notices). The ssh_key_pairs route has none, and had no test.

run "an_orphan_region_in_instances_is_reported" {
  command = plan
  variables {
    instances = {
      "ap-south-1" = { "dev" = { instance_type = "t3.micro", volume_size_gb = 20, fqdn = "d.test.invalid", key_name = "k" } }
    }
  }
  assert {
    condition     = output.orphan_region_keys == tolist(["ap-south-1"])
    error_message = "expected [ap-south-1], got ${jsonencode(output.orphan_region_keys)}"
  }
}

run "an_orphan_region_in_ssh_key_pairs_alone_is_reported" {
  command = plan
  variables {
    ssh_key_pairs = { "ap-south-1" = { "dev" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST dev@test" } }
  }
  assert {
    condition     = output.orphan_region_keys == tolist(["ap-south-1"])
    error_message = "expected [ap-south-1], got ${jsonencode(output.orphan_region_keys)} — the ssh_key_pairs half of the guard is not wired"
  }
}

# A guard that reports everything would pass every run above. This one must not.

run "a_configured_region_is_never_an_orphan" {
  command = plan
  variables {
    instances     = { "us-east-1" = { "dev" = { instance_type = "t3.micro", volume_size_gb = 20, fqdn = "d.test.invalid", key_name = "k" } } }
    ssh_key_pairs = { "us-east-1" = { "k" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST dev@test" } }
  }
  assert {
    condition     = length(output.orphan_region_keys) == 0
    error_message = "a configured region was reported as an orphan: ${jsonencode(output.orphan_region_keys)}"
  }
}
