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
    NAMESPACE = 'dev-vm-policy-(?:staging|production)'.freeze
    LINE = %r{\A
      (?<principal>[A-Za-z0-9._@-]+)\s
      namespaces="(?<namespaces>#{NAMESPACE}(?:,#{NAMESPACE})?)"
      (?:,valid-before="\d{8}(?:\d{4}(?:\d{2})?)?Z?")?\s
      (?<type>ssh-ed25519|sk-ssh-ed25519@openssh\.com)\s
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
      { principal: m[:principal], namespaces: m[:namespaces].split(','), key: "#{m[:type]} #{m[:key]}" }
    end

    # Raises unless `wanted` is safe to install over `current`.
    #
    # signed_by: the principal whose signature dev-vm-policy-fetch verified on
    # this run, or '' when it converges the last good revision with nothing
    # verified. group: the VM's policy group. Both come from the environment
    # dev-vm-policy-fetch hands cinc-client.
    def self.validate!(wanted, current:, signed_by:, group:)
      raise 'node[base][policy][signers] must be a list of signers lines' unless wanted.is_a?(Array) && wanted.all? { |l| l.is_a?(String) }
      raise 'node[base][policy][signers] is empty; every VM would reject every envelope' if canonical(wanted).empty?
      raise 'not run by dev-vm-policy-run (DEV_VM_POLICY_GROUP is unset); a local-mode converge must come from it' if group.to_s.empty?
      parsed = canonical(wanted).lines.map { |l| parse(l) }

      if signed_by.to_s.empty?
        return if canonical(wanted) == canonical(current.to_s.lines)
        raise 'refusing to change the signers set on an unverified run (converging the last good revision)'
      end

      namespace = "dev-vm-policy-#{group}"
      signer_keys = current.to_s.lines.filter_map do |l|
        next if l.strip.empty?
        c = parse(l)
        c[:key] if c[:principal] == signed_by && c[:namespaces].include?(namespace)
      end
      kept = parsed.any? { |p| signer_keys.include?(p[:key]) && p[:namespaces].include?(namespace) }
      return if kept

      raise "the new signers set would drop the key that signed this revision (#{signed_by} for #{namespace}); " \
            'add the new key in one revision and remove the old one in a later revision signed by the new key'
    end
  end
end
