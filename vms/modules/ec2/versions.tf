terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"

      # v6 or newer is required, not merely preferred: every regional resource in
      # this module sets its own `region` argument, which v6 introduced. On v5
      # that argument does not exist and each resource silently lands in whatever
      # region the caller's single provider block names — one region for the
      # whole fleet, with a clean plan and no warning.
      #
      # This constraint used to live only in the calling root. That was adequate
      # while the only root was in this repository; it is not adequate for a
      # published module, whose callers we do not control.
      version = "~> 6.0"
    }
  }
}
