# cinc/cookbooks/base/libraries/policy_signers.rb
#
# The keys a VM accepts policy envelopes from. Design:
# docs/design/serverless-policy-delivery.md, "Trust".
#
# The set arrives twice: user_data writes var.policy_signers at first boot,
# and from then on base::cinc_client writes node['base']['policy']['signers'].
# Every check here exists because a mistake in that attribute is not
# recoverable from the bucket: a set that no longer contains the signing key
# makes every VM reject every later envelope, and the only way back is to
# recreate the fleet.
module DevVm
  module PolicySigners
    CONF    = '/etc/dev-vm/policy.conf'.freeze
    SIGNERS = '/etc/dev-vm/policy-signers'.freeze

    # <principal> namespaces="<dev-vm-policy-*>"[,valid-before="<date>"] <type> <key>
    #
    # namespaces= is mandatory: without it a key signs for every purpose, and a
    # staging-only CI key could publish to production. cert-authority is not
    # accepted — it would make every key that CA ever signed a root of trust.
    #
    # Fields are separated by exactly one space, the shape the Terraform
    # validation on var.policy_signers accepts. Ruby's \s would also take a tab,
    # \f or \v, and that is where this check and ssh-keygen's own tokenizer could
    # read one line two different ways.
    NAMESPACE = 'dev-vm-policy-(?:staging|production)'.freeze
    LINE = %r{\A
      (?<principal>[A-Za-z0-9._@-]+)[ ]
      namespaces="(?<namespaces>#{NAMESPACE}(?:,#{NAMESPACE})?)"
      (?:,valid-before="(?<valid_before>[0-9]{8}(?:[0-9]{4}(?:[0-9]{2})?)?Z?)")?[ ]
      (?<type>ssh-ed25519|sk-ssh-ed25519@openssh\.com)[ ]
      (?<key>[A-Za-z0-9+/]+={0,2})
    \z}x.freeze

    # The form dev-vm-policy-fetch and `make push` hash for signers_sha256:
    # trimmed, non-empty, unique, byte-sorted, newline-terminated.
    def self.canonical(lines)
      kept = lines.map { |l| l.to_s.strip }.reject(&:empty?).uniq.sort
      kept.empty? ? '' : "#{kept.join("\n")}\n"
    end

    def self.parse(line)
      m = LINE.match(line.strip)
      raise "malformed signers line: #{line.inspect}" unless m
      { principal: m[:principal], namespaces: m[:namespaces].split(','), key: "#{m[:type]} #{m[:key]}",
        valid_before: m[:valid_before] && expiry(m[:valid_before]) }
    end

    # valid-before as ssh-keygen reads it: YYYYMMDD[HHMM[SS]], UTC with a
    # trailing Z and local time without one, a bare date meaning its midnight.
    def self.expiry(value)
      utc = value.end_with?('Z')
      d = value.delete_suffix('Z').ljust(14, '0')
      parts = [d[0, 4], d[4, 2], d[6, 2], d[8, 2], d[10, 2], d[12, 2]].map(&:to_i)
      utc ? Time.utc(*parts) : Time.local(*parts)
    end

    # Raises unless `wanted` is safe to install over `current`.
    #
    # signed_key: the public key ("<type> <base64>") whose signature
    # dev-vm-policy-fetch verified on this run, or '' when it converges the last
    # good revision with nothing verified. group: the VM's policy group. Both
    # come from the environment dev-vm-policy-fetch hands cinc-client. The key,
    # not the principal: a principal can hold several keys, and keeping the
    # principal is not keeping the key that is known to be in use.
    #
    # A line whose valid-before has passed does not count as keeping a key:
    # ssh-keygen already refuses it, so installing it locks the fleet out as
    # surely as dropping the key would.
    def self.validate!(wanted, current:, signed_key:, group:, now: Time.now)
      raise 'node[base][policy][signers] must be a list of signers lines' unless wanted.is_a?(Array) && wanted.all?(String)
      raise 'node[base][policy][signers] is empty; every VM would reject every envelope' if canonical(wanted).empty?
      raise 'not run by dev-vm-policy-run (DEV_VM_POLICY_GROUP is unset); a local-mode converge must come from it' if group.to_s.empty?
      parsed = canonical(wanted).lines.map { |l| parse(l) }

      if signed_key.to_s.empty?
        return if canonical(wanted) == canonical(current.to_s.lines)
        raise 'refusing to change the signers set on an unverified run (converging the last good revision)'
      end

      namespace = "dev-vm-policy-#{group}"
      kept = parsed.any? do |p|
        p[:key] == signed_key && p[:namespaces].include?(namespace) && (p[:valid_before].nil? || p[:valid_before] > now)
      end
      return if kept

      raise "the new signers set would drop the key that signed this revision, or keep it already expired (#{signed_key.split.first} for #{namespace}); " \
            'add the new key in one revision and remove the old one in a later revision signed by the new key'
    end
  end
end
