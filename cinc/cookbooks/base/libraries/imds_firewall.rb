# Where base::imds puts the IMDS DROP in the OUTPUT chain.
#
# The allows go in at fixed positions (root at 1, Instance Connect at 2), but
# the Instance Connect allow is skipped when that user is missing, and a fixed
# `-I OUTPUT 3` for the DROP then fails with "Index of insertion too big" on a
# chain holding only the root allow — which aborts the converge before the
# DROP exists (measured with real iptables and ip6tables in a network
# namespace). So the DROP goes right after the LAST IMDS owner-allow present,
# however many there are: 3 on a normal host (byte-identical to the old
# command), 2 when the Instance Connect allow is missing, 1 when there is none
# at all (fail closed — nothing reaches IMDS, root included).
#
# drop_position is pure Ruby so `make test` pins the arithmetic without Chef.
module DevVm
  module ImdsFirewall
    # rules_s: `<bin> -S OUTPUT` output. cidr: the rendered destination,
    # `169.254.169.254/32` or `fd00:ec2::254/128`. Returns a 1-based rule number.
    def self.drop_position(rules_s, cidr)
      rules = rules_s.lines.map(&:strip).select { |l| l.start_with?('-A OUTPUT ') }
      allow = /\A-A OUTPUT -d #{Regexp.escape(cidr)} -m owner --uid-owner \d+ -j ACCEPT\z/
      last = rules.rindex { |l| allow.match?(l) }
      last ? last + 2 : 1
    end

    # bin: iptables or ip6tables. addr: the bare address. prefix: 32 or 128.
    def self.drop_command(bin, addr, prefix)
      pos = drop_position(list_output(bin), "#{addr}/#{prefix}")
      "#{bin} -I OUTPUT #{pos} -d #{addr} -j DROP"
    end

    # Raises when the chain cannot be listed: a guessed position is worse than
    # a failed converge, which is loud.
    def self.list_output(bin)
      require 'mixlib/shellout'
      c = Mixlib::ShellOut.new(bin, '-S', 'OUTPUT', timeout: 60)
      c.run_command
      c.error!
      c.stdout
    end
  end
end
