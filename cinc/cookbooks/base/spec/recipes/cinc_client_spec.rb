# cinc/cookbooks/base/spec/recipes/cinc_client_spec.rb
#
# base::cinc_client after the CINC server: local-mode converges driven by
# dev-vm-policy-run, the signers set the VM trusts, and the in-place swap of
# the delivery script. Design: docs/design/serverless-policy-delivery.md.
require 'chefspec'
require_relative '../support/home_boundary'

OPS_KEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMkEu+CUWYGvccB0PoBw6SX1d6kJOSy2vALB7cAntO+E'.freeze
NEW_KEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHeXdokG5/UykwcY+ubcpI2IdGsX15YbncQcVjJQUkLP'.freeze
OPS_LINE = %(ops namespaces="dev-vm-policy-staging,dev-vm-policy-production" #{OPS_KEY}).freeze
NEW_LINE = %(new namespaces="dev-vm-policy-staging,dev-vm-policy-production" #{NEW_KEY}).freeze
CI_LINE  = %(ci namespaces="dev-vm-policy-staging" #{NEW_KEY}).freeze

FETCH     = '/usr/local/sbin/dev-vm-policy-fetch'.freeze
SELFTEST  = '/usr/share/dev-vm/policy-fetch-selftest'.freeze
SIGNERS_F = '/etc/dev-vm/policy-signers'.freeze
CONF_F    = '/etc/dev-vm/policy.conf'.freeze

describe 'base::cinc_client' do
  let(:signers) { [OPS_LINE] }
  let(:current_signers) { "#{OPS_LINE}\n" }
  let(:signed_by) { 'ops' }
  let(:signed_key) { OPS_KEY }
  let(:group) { 'production' }
  let(:conf_present) { true }

  let(:chef_run) do
    ChefSpec::SoloRunner.new(platform: 'ubuntu', version: '24.04') do |node|
      node.override['base']['policy']['signers'] = signers
    end.converge(described_recipe)
  end

  before do
    allow(::File).to receive(:exist?).and_call_original
    allow(::File).to receive(:exist?).with(CONF_F).and_return(conf_present)
    allow(::File).to receive(:exist?).with(SIGNERS_F).and_return(!current_signers.nil?)
    allow(::File).to receive(:read).and_call_original
    allow(::File).to receive(:read).with(SIGNERS_F).and_return(current_signers.to_s)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('DEV_VM_POLICY_SIGNED_BY').and_return(signed_by)
    allow(ENV).to receive(:[]).with('DEV_VM_POLICY_SIGNED_KEY').and_return(signed_key)
    allow(ENV).to receive(:[]).with('DEV_VM_POLICY_GROUP').and_return(group)
    stub_command(/cmp -s/).and_return(false)
  end

  it_behaves_like 'root never writes under /home/ubuntu'

  describe 'the unit' do
    it 'starts the launcher, not a server-mode client' do
      expect(chef_run).to render_file('/etc/systemd/system/cinc-client.service')
        .with_content(%r{^ExecStart=/usr/local/sbin/dev-vm-policy-run$})
      expect(chef_run).to_not render_file('/etc/systemd/system/cinc-client.service')
        .with_content(%r{ExecStart=/usr/bin/cinc-client})
    end

    # The dashboard's error panel filters syslog_identifier=~"alloy|cinc-client";
    # without this the converge output would leave it.
    it 'keeps the cinc-client syslog identifier' do
      expect(chef_run).to render_file('/etc/systemd/system/cinc-client.service')
        .with_content(/^SyslogIdentifier=cinc-client$/)
    end

    it 'still upgrades the client first, and tolerates that failing' do
      expect(chef_run).to render_file('/etc/systemd/system/cinc-client.service')
        .with_content(%r{^ExecStartPre=-/usr/local/sbin/cinc-client-upgrade$})
    end

    # Only user_data writes the launcher. If the cookbook owned it, a broken
    # revision could break the one thing that falls back from a broken revision.
    it 'never manages the launcher' do
      paths = chef_run.resource_collection.all_resources.map { |r| r.respond_to?(:path) ? r.path.to_s : r.name.to_s }
      expect(paths).to_not include('/usr/local/sbin/dev-vm-policy-run')
    end
  end

  describe 'the delivery script' do
    it 'stages a new version beside the one in use' do
      expect(chef_run).to create_cookbook_file("#{FETCH}.new").with(
        source: 'dev-vm-policy-fetch', owner: 'root', group: 'root', mode: '0700'
      )
    end

    it 'ships the self-test fixture, root only' do
      expect(chef_run).to create_remote_directory(SELFTEST).with(
        source: 'policy-fetch-selftest', owner: 'root', group: 'root', mode: '0700', files_mode: '0700', purge: true
      )
    end

    # mv, never an in-place write: the running bash keeps reading the inode it
    # opened, and the swap happens only after the new version passed --self-test.
    it 'swaps it in only after the new version passes its self-test, keeping .prev' do
      resource = chef_run.execute('install dev-vm-policy-fetch')
      expect(resource.command).to match(/\A#{Regexp.escape("#{FETCH}.new --self-test #{SELFTEST}")} && /)
      expect(resource.command).to include("cp -p #{FETCH} #{FETCH}.prev")
      expect(resource.command).to end_with("mv #{FETCH}.new #{FETCH}")
      expect(resource.not_if.first.command).to eq("cmp -s #{FETCH}.new #{FETCH}")
    end

    # Measured on a live VM, 2026-10-16: a script that could not run fell back
    # to .prev, the converge repaired it, and the repair copied the broken
    # script over .prev, so the fallback was gone for next time. Only a version
    # the launcher could run is kept.
    context 'run in a sandbox' do
      def install(current)
        Dir.mktmpdir do |dir|
          f = "#{dir}/fetch"
          File.write("#{f}.prev", "#!/bin/bash\necho prev\n")
          File.write("#{f}.new", "#!/bin/bash\necho new\n")
          File.write(f, current)
          [f, "#{f}.prev", "#{f}.new"].each { |p| File.chmod(0o700, p) }
          cmd = chef_run.execute('install dev-vm-policy-fetch').command
                        .sub("#{FETCH}.new --self-test #{SELFTEST}", 'true')
                        .gsub(FETCH, f)
          expect(system('bash', '-c', cmd)).to be(true)
          [File.read(f), File.read("#{f}.prev")]
        end
      end

      it 'keeps a runnable current version as .prev' do
        expect(install("#!/bin/bash\necho current\n")).to eq(["#!/bin/bash\necho new\n", "#!/bin/bash\necho current\n"])
      end

      it 'never keeps a version that does not parse as .prev' do
        expect(install("#!/bin/bash\nif then fi\n")).to eq(["#!/bin/bash\necho new\n", "#!/bin/bash\necho prev\n"])
      end
    end
  end

  describe 'the signers set' do
    it 'writes the canonical set, root-owned and world-readable' do
      expect(chef_run).to create_file(SIGNERS_F).with(
        content: "#{OPS_LINE}\n", owner: 'root', group: 'root', mode: '0644'
      )
    end

    context 'when a rotation adds a key and keeps the signer' do
      let(:signers) { [NEW_LINE, OPS_LINE, OPS_LINE] }

      it 'writes it sorted and de-duplicated, the form signers_sha256 hashes' do
        expect(chef_run).to create_file(SIGNERS_F).with(content: "#{NEW_LINE}\n#{OPS_LINE}\n")
      end
    end

    context 'when the set drops the key that signed this revision' do
      let(:signers) { [NEW_LINE] }

      it 'refuses to converge' do
        expect { chef_run }.to raise_error(RuntimeError, /drop the key that signed/)
      end
    end

    # A principal can hold several keys. Keeping the principal is not keeping
    # the key that signed, and only that key is known to be in use.
    context 'when the set keeps the principal but drops the key that signed' do
      let(:current_signers) { "#{OPS_LINE}\n#{OPS_LINE.sub(OPS_KEY, NEW_KEY)}\n" }
      let(:signers) { [OPS_LINE.sub(OPS_KEY, NEW_KEY)] }

      it 'refuses to converge' do
        expect { chef_run }.to raise_error(RuntimeError, /drop the key that signed/)
      end
    end

    context 'when the signer keeps its key but loses the group namespace' do
      let(:signers) { [%(ops namespaces="dev-vm-policy-staging" #{OPS_KEY})] }

      it 'refuses to converge' do
        expect { chef_run }.to raise_error(RuntimeError, /drop the key that signed/)
      end
    end

    context 'when the set is empty' do
      let(:signers) { [] }

      it 'refuses to converge' do
        expect { chef_run }.to raise_error(RuntimeError, /\[signers\] is empty/)
      end
    end

    context 'with a cert-authority line' do
      let(:signers) { [OPS_LINE, %(@cert-authority * #{NEW_KEY})] }

      it 'refuses it' do
        expect { chef_run }.to raise_error(RuntimeError, /malformed signers line/)
      end
    end

    # Fields are separated by single spaces, exactly what the Terraform
    # validation accepts. Any other whitespace is where a Ruby regex and
    # ssh-keygen's own tokenizer could read one line two ways.
    context 'with a field separated by something other than one space' do
      let(:signers) { [OPS_LINE, NEW_LINE.sub(' ssh-ed25519', "\tssh-ed25519")] }

      it 'refuses it' do
        expect { chef_run }.to raise_error(RuntimeError, /malformed signers line/)
      end
    end

    context 'with a vertical tab between fields' do
      let(:signers) { [OPS_LINE, NEW_LINE.sub(' namespaces', "\vnamespaces")] }

      it 'refuses it' do
        expect { chef_run }.to raise_error(RuntimeError, /malformed signers line/)
      end
    end

    context 'with a line that does not restrict namespaces' do
      let(:signers) { [OPS_LINE, "new #{NEW_KEY}"] }

      it 'refuses it' do
        expect { chef_run }.to raise_error(RuntimeError, /malformed signers line/)
      end
    end

    # Dates relative to now: a fixed date here would turn this test red the day
    # it passed.
    context 'with an expiry' do
      let(:signers) { [%(ops namespaces="dev-vm-policy-staging,dev-vm-policy-production",valid-before="#{(Time.now.utc + 86_400 * 365).strftime('%Y%m%d')}Z" #{OPS_KEY})] }

      it 'accepts it' do
        expect { chef_run }.to_not raise_error
      end
    end

    # ssh-keygen honours valid-before, so a line that keeps the signing key but
    # has already expired drops it in all but name, and every later envelope is
    # rejected. Found by review, 2026-10-16.
    context 'when the signing key is kept but has already expired' do
      let(:signers) { [%(ops namespaces="dev-vm-policy-staging,dev-vm-policy-production",valid-before="#{(Time.now.utc - 3600).strftime('%Y%m%d%H%M')}Z" #{OPS_KEY})] }

      it 'refuses to converge' do
        expect { chef_run }.to raise_error(RuntimeError, /drop the key that signed/)
      end
    end

    context 'when the signing key is expired on one line and valid on another' do
      let(:signers) do
        [%(ops namespaces="dev-vm-policy-staging,dev-vm-policy-production",valid-before="20200101" #{OPS_KEY}),
         %(ops2 namespaces="dev-vm-policy-staging,dev-vm-policy-production" #{OPS_KEY})]
      end

      it 'accepts it' do
        expect { chef_run }.to_not raise_error
      end
    end

    context 'when converging the last good revision, nothing verified this run' do
      let(:signed_by) { '' }
      let(:signed_key) { '' }

      it 'keeps the set it has' do
        expect { chef_run }.to_not raise_error
      end

      context 'and the attribute says something else' do
        let(:signers) { [OPS_LINE, CI_LINE] }

        it 'refuses to change trust on an unverified run' do
          expect { chef_run }.to raise_error(RuntimeError, /unverified/)
        end
      end
    end

    context 'when not run by dev-vm-policy-run' do
      let(:group) { nil }

      it 'refuses to converge' do
        expect { chef_run }.to raise_error(RuntimeError, /dev-vm-policy-run/)
      end
    end
  end

  # A 1.x VM has a server-mode client.rb and no policy.conf. Converging this
  # cookbook there would rewrite its unit to a launcher it does not have.
  context 'on a VM built for a CINC server' do
    let(:conf_present) { false }

    it 'refuses to converge' do
      expect { chef_run }.to raise_error(RuntimeError, %r{/etc/dev-vm/policy.conf})
    end
  end
end
