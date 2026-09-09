# Shared example: root never writes under /home/ubuntu.
#
# Chef's directory provider has no symlink handling, and file/template check
# only the last path component, so a developer-planted symlink turns any
# root-run resource in their home into a chown/chmod of a path root owns
# (reproduced with cinc-apply, see docs/design/first-external-review.md §1).
# The boundary that holds is privilege: anything that must exist under the
# developer's home is created by the developer's uid. This example is what a
# future recipe fails.
HOME_WRITERS = %w(directory file template cookbook_file link remote_file).freeze

RSpec.shared_examples 'root never writes under /home/ubuntu' do
  it 'has no root-run file resource under /home/ubuntu' do
    offenders = chef_run.resource_collection.all_resources.select do |r|
      HOME_WRITERS.include?(r.declared_type.to_s) && r.path.to_s.start_with?('/home/ubuntu/')
    end
    expect(offenders.map(&:to_s)).to eq([])
  end

  it 'runs every execute that names /home/ubuntu as ubuntu' do
    offenders = chef_run.resource_collection.all_resources.select do |r|
      r.declared_type.to_s == 'execute' && r.command.to_s.include?('/home/ubuntu') && r.user != 'ubuntu'
    end
    expect(offenders.map(&:to_s)).to eq([])
  end
end
