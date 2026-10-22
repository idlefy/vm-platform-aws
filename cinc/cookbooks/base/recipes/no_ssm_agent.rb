# no_ssm_agent: remove the amazon-ssm-agent snap Canonical's Ubuntu AMIs ship.
#
# Law A1: after launch nothing on the box takes instructions from Idlefy — and
# SSM is exactly such a channel (Run Command, Session Manager) for whoever
# holds the right IAM in the account. The hardened image carries no in-guest
# agent.
#
# `snap wait system seed.loaded` first: an image build can converge before
# snapd has finished seeding, and a remove then fails.
#
# Included only by base::solo, so the fleet keeps the snap: nothing else in the
# cookbook removes it.
execute 'remove-amazon-ssm-agent-snap' do
  command 'snap wait system seed.loaded && snap remove --purge amazon-ssm-agent'
  only_if 'snap list amazon-ssm-agent'
end
