# The validation predicate is a security boundary: the region string reaches
# templates/aws-access.env.erb UNQUOTED, and the root broker sources that file
# on every timer tick. An IMDS error body containing $() would be root command
# execution — this spec pins the shape check that stops it.
require_relative '../libraries/imds'
require 'mixlib/shellout'

describe DevVm::Imds do
  describe '.valid_region?' do
    %w(us-east-1 eu-central-1 eu-north-1 us-west-2 ap-southeast-2).each do |r|
      it "accepts #{r}" do
        expect(described_class.valid_region?(r)).to be true
      end
    end

    [
      ['', 'the empty string'],
      [nil, 'nil'],
      ['<html><body>404 - Not Found</body></html>', 'an HTTP error body'],
      ['$(rm -rf /)', 'a command-substitution payload'],
      ['`id`', 'a backtick payload'],
      ["us-east-1\nX=y", 'an embedded newline'],
      ['us east 1', 'whitespace'],
      ['useast1', 'a hyphenless token'],
    ].each do |value, label|
      it "rejects #{label}" do
        expect(described_class.valid_region?(value)).to be false
      end
    end
  end

  describe '.region' do
    let(:node) { double('node') }

    def shellout_double(stdout: '', error: false)
      instance_double(Mixlib::ShellOut, run_command: nil, error?: error, stdout: stdout)
    end

    context 'when ohai already populated the placement AZ' do
      it 'returns the region and never shells out' do
        allow(node).to receive(:attribute?).with('ec2').and_return(true)
        allow(node).to receive(:[]).with('ec2').and_return('placement_availability_zone' => 'us-east-1a')
        expect(Mixlib::ShellOut).not_to receive(:new)
        expect(described_class.region(node)).to eq('us-east-1')
      end
    end

    context 'when ohai has no ec2 data (falls back to IMDS)' do
      before do
        allow(node).to receive(:attribute?).with('ec2').and_return(false)
      end

      it 'returns the region from a successful token-then-metadata fetch' do
        token_call = shellout_double(stdout: "imds-token\n")
        az_call = shellout_double(stdout: "us-west-2a\n")
        allow(Mixlib::ShellOut).to receive(:new) do |cmd, _opts|
          cmd.include?('/latest/api/token') ? token_call : az_call
        end
        expect(described_class.region(node)).to eq('us-west-2')
      end

      it "falls closed ('') when IMDS answers with an unshaped value" do
        token_call = shellout_double(stdout: "imds-token\n")
        az_call = shellout_double(stdout: '<html><body>404 - Not Found</body></html>')
        allow(Mixlib::ShellOut).to receive(:new) do |cmd, _opts|
          cmd.include?('/latest/api/token') ? token_call : az_call
        end
        expect(described_class.region(node)).to eq('')
      end

      it "falls closed ('') when the shell-out raises" do
        allow(Mixlib::ShellOut).to receive(:new).and_raise(Mixlib::ShellOut::CommandTimeout, 'timed out')
        expect(described_class.region(node)).to eq('')
      end
    end
  end
end
