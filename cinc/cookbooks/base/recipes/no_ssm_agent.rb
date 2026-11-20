# no_ssm_agent: remove the amazon-ssm-agent snap Canonical's Ubuntu AMIs ship.
#
# Law A1: after launch nothing on the box takes instructions from Idlefy — and
# SSM is exactly such a channel (Run Command, Session Manager) for whoever
# holds the right IAM in the account. The hardened image carries no in-guest
# agent.
#
# The guard is DevVm::Snap.installed? (libraries/snap.rb), not a shell string.
# A shell guard reads "snapd failed" as "not installed" and skips the removal
# silently, leaving the agent on the image. installed? first waits for snapd
# seeding (an image build can converge before seeding finishes, when the snap
# is not listed yet), bounded by `timeout 600`, and raises when the wait or the
# listing fails — so either fails the converge. Only a successful listing
# without the snap is a no-op.
#
# After the removal the snap must be gone; if snapd still lists it, the
# converge fails.
#
# Included only by base::solo, so the fleet keeps the snap: nothing else in the
# cookbook removes it.
execute 'remove-amazon-ssm-agent-snap' do
  command 'snap remove --purge amazon-ssm-agent'
  only_if { DevVm::Snap.installed?('amazon-ssm-agent') }
  notifies :run, 'ruby_block[assert-amazon-ssm-agent-removed]', :immediately
end

ruby_block 'assert-amazon-ssm-agent-removed' do
  block do
    if DevVm::Snap.installed?('amazon-ssm-agent')
      raise 'base::no_ssm_agent: amazon-ssm-agent is still installed after snap remove --purge'
    end
  end
  action :nothing
end
