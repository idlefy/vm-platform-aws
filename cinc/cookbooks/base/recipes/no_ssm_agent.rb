# no_ssm_agent: remove the amazon-ssm-agent snap Canonical's Ubuntu AMIs ship.
#
# Law A1: after launch nothing on the box takes instructions from Idlefy — and
# SSM is exactly such a channel (Run Command, Session Manager) for whoever
# holds the right IAM in the account. The hardened image carries no in-guest
# agent.
#
# Included only by base::solo, so the fleet keeps the snap: nothing else in the
# cookbook removes it.
execute 'remove-amazon-ssm-agent-snap' do
  command 'snap remove --purge amazon-ssm-agent'
  only_if 'snap list amazon-ssm-agent'
end
