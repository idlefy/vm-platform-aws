locals {
  master_ssh_keys_formatted = join("\n", var.master_ssh_keys)
}
