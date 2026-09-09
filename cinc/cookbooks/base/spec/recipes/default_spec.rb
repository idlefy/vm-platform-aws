# cinc/cookbooks/base/spec/recipes/default_spec.rb
#
# One converge of the whole run list, asserting the home-directory boundary
# across every recipe at once. Per-recipe specs prove each fix; this one is
# what a recipe added next year fails.
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
