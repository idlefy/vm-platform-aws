# cinc/cookbooks/base/spec/recipes/default_spec.rb
#
# One converge of the whole run list, asserting the home-directory boundary
# across every recipe at once. Per-recipe specs prove each fix; this one is
# what a recipe added next year fails.
#
# KNOWN FAILURE (not introduced by this spec, left for the controller to
# rule on): the fourth shared example — "runs every ubuntu-user execute as
# the ubuntu group with HOME set to /home/ubuntu" — fails on
# execute[install-werf] in recipes/werf.rb. That resource sets
# `user 'ubuntu'` and `environment 'HOME' => '/home/ubuntu'` but never sets
# `group 'ubuntu'`, so Chef's resource default group applies instead.
# recipes/werf.rb was not part of Tasks 2-4 (claude_code.rb, docker.rb,
# traefik.rb) and is out of this task's scope (the brief names only this
# file), so it is left unmodified. Once fixed, this comment and its example
# can be dropped from the concern list.
require 'chefspec'
require_relative '../../libraries/imds'
require_relative '../support/home_boundary'

describe 'base::default' do
  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04') do |node|
      node.override['base']['traefik']['acme_email']  = 'admin@example.com'
      node.override['base']['traefik']['domain_root'] = 'example.com'
      node.override['base']['loki']['url']      = 'https://logs.example.grafana.net/loki/api/v1/push'
      node.override['base']['loki']['username'] = '12345'
      node.override['base']['loki']['ssm_parameter_name'] = '/test/loki-token'
      node.automatic['ec2']['public_ipv4'] = '203.0.113.5'
      node.automatic['hostname'] = 'devbox'
    end.converge(described_recipe)
  end

  before do
    allow(DevVm::Imds).to receive(:region).and_return('eu-central-1')
    # Guards are irrelevant to the boundary; answer them all the same way so the
    # resource collection is complete. false = "run it", which keeps every
    # execute in the collection with its command and user intact.
    stub_command(/.*/).and_return(false)
  end

  it_behaves_like 'root never writes under /home/ubuntu'
end
