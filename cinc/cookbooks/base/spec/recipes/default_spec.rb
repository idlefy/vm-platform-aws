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
    # base::nvidia_docker returns at compile time unless /dev/nvidia0 exists, so
    # on a GPU-less runner none of its resources would enter the collection and
    # the boundary would not be checked there. Pretend the device exists.
    allow(::File).to receive(:exist?).and_call_original
    allow(::File).to receive(:exist?).with('/dev/nvidia0').and_return(true)
    # base::aws_access resolves the ubuntu uid/gid via shell_out('id -u ubuntu')
    # / shell_out('id -g ubuntu') at compile time and returns early — leaving
    # only a `log` resource in the collection — when either is empty. On a
    # runner with no ubuntu user (this one) that early return would hide the
    # whole recipe from the boundary check, so give those two calls a uid/gid
    # to resolve; every other shell_out (traefik/docker's own `id -u ubuntu`,
    # imds.rb's ec2-instance-connect lookup, etc.) still runs for real. Stubbed
    # by dispatching on the command rather than stacking `.with` on top of
    # `.and_call_original` — the latter recurses into itself under
    # allow_any_instance_of and blows the stack.
    real_shell_out = Chef::Mixin::ShellOut.instance_method(:shell_out)
    allow_any_instance_of(Chef::Mixin::ShellOut).to receive(:shell_out) do |instance, *args|
      case args.first
      when 'id -u ubuntu', 'id -g ubuntu'
        double(stdout: "1000\n", stderr: '', exitstatus: 0, error?: false)
      else
        real_shell_out.bind(instance).call(*args)
      end
    end
    # Guards never remove a resource from the collection — they only decide
    # whether its action runs — so any answer works; give them all the same one
    # so no string guard raises CommandNotStubbed.
    stub_command(/.*/).and_return(false)
  end

  it_behaves_like 'root never writes under /home/ubuntu'
end
