# Shared IMDSv2 region lookup — ohai first, hardened curl fallback.
#
# One implementation because there were two: alloy.rb carried the hardened
# curls (-fsS --connect-timeout 2 --max-time 5; its old comment explains each
# flag and is preserved in spirit here) while aws_access.rb carried bare
# `curl -s`, which (a) hangs a blackholed IMDS into Mixlib::ShellOut's 600 s
# CommandTimeout at COMPILE time, aborting the whole run before any recipe
# converges, and (b) lets an HTTP error body through as the "region" —
# unquoted, into a file the root broker sources every 15 minutes.
#
# The validation is the security boundary: nothing unshaped ever reaches a
# template. valid_region? is pure Ruby so `make test` pins it without Chef.
#
# Callers keep their own empty-result semantics (alloy's 'unknown' sentinel,
# aws_access's warn-and-skip). Do not unify them here — alloy.rb documents at
# length why a sentinel is right for the region label and wrong for public_ip,
# and the same reasoning separates the two callers.
module DevVm
  module Imds
    REGION_SHAPE = /\A[a-z]{2,}(-[a-z]+)+-\d+\z/.freeze
    # A Local Zone AZ stripped of its trailing letter does NOT match this
    # shape (e.g. us-west-2-lax-1) and is rejected like any other bad value.

    def self.valid_region?(value)
      !value.nil? && !value.empty? && REGION_SHAPE.match?(value)
    end

    # Region string or '' — never raises, never returns an unvalidated value.
    def self.region(node)
      az =
        if node.attribute?('ec2') && node['ec2']['placement_availability_zone']
          node['ec2']['placement_availability_zone'].to_s
        else
          fetch_az_from_imds
        end
      region = az.sub(/[a-z]$/, '')
      valid_region?(region) ? region : ''
    end

    def self.fetch_az_from_imds
      token = run('curl -fsS --connect-timeout 2 --max-time 5 ' \
                  '-X PUT http://169.254.169.254/latest/api/token ' \
                  '-H "X-aws-ec2-metadata-token-ttl-seconds: 60"')
      return '' if token.empty?
      run('curl -fsS --connect-timeout 2 --max-time 5 ' \
          "-H 'X-aws-ec2-metadata-token: #{token}' " \
          'http://169.254.169.254/latest/meta-data/placement/availability-zone')
    end
    private_class_method :fetch_az_from_imds

    def self.run(cmd)
      # Mixlib::ShellOut directly — a bare libraries/*.rb module has no recipe
      # DSL. Required lazily so a plain rspec run of valid_region? needs no
      # Chef gems. The explicit timeout is Mixlib's own ceiling; curl's flags
      # bound the network wait well below it.
      require 'mixlib/shellout'
      c = Mixlib::ShellOut.new(cmd, timeout: 15)
      c.run_command
      c.error? ? '' : c.stdout.strip
    rescue StandardError
      ''
    end
    private_class_method :run
  end
end
