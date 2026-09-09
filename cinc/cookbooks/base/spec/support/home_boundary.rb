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

# Matches an execute command that reaches into /home/ubuntu by any of the
# spellings seen in this cookbook: the literal path, $HOME (when HOME is set
# to it), or a ~ubuntu tilde-expansion.
HOME_UBUNTU_COMMAND = %r{/home/ubuntu|\$HOME|~ubuntu\b}.freeze

# execute's whole family: bash/csh/perl/python/ruby are all script resources
# (Chef::Resource::Script subclasses) that shell out exactly like execute does,
# so a root-run `bash 'x' do code '...install into /home/ubuntu...' end` is the
# same boundary violation as a root-run `execute` and must be caught the same
# way.
HOME_COMMAND_RESOURCES = %w(execute bash script csh perl python ruby).freeze

RSpec.shared_examples 'root never writes under /home/ubuntu' do
  it 'has no root-run file resource under /home/ubuntu' do
    offenders = chef_run.resource_collection.all_resources.select do |r|
      HOME_WRITERS.include?(r.declared_type.to_s) && r.path.to_s.match?(%r{\A/home/ubuntu(/|\z)})
    end
    expect(offenders.map(&:to_s)).to eq([])
  end

  it 'runs every execute (and script-family resource) that names /home/ubuntu as ubuntu' do
    # A literal substring match on "/home/ubuntu" misses a root-run execute
    # that reaches the same place via $HOME (with HOME set to it) or a
    # ~ubuntu tilde-expansion — both walk past a plain command.include? check.
    #
    # bash/script/csh/perl/python/ruby are execute's script-family siblings:
    # each shells out to `code`, not `command` (script resources have no
    # `command` property at all), so a root-run `bash` that installs into
    # /home/ubuntu is the same violation wearing a different resource name.
    offenders = chef_run.resource_collection.all_resources.select do |r|
      next false unless HOME_COMMAND_RESOURCES.include?(r.declared_type.to_s) && r.user != 'ubuntu'

      command = r.respond_to?(:code) ? r.code : r.command
      command_hits_home = command.to_s.match?(HOME_UBUNTU_COMMAND)
      env_sets_ubuntu_home = r.environment.is_a?(Hash) && r.environment['HOME'] == '/home/ubuntu'
      command_hits_home || env_sets_ubuntu_home
    end
    expect(offenders.map(&:to_s)).to eq([])
  end

  it 'has no ruby_block named after a home-directory command' do
    # ruby_block bodies are arbitrary Ruby, not a shelled-out command string,
    # so there is no `command`/`code` property here to inspect — a root-run
    # ruby_block that writes into /home/ubuntu from inside its block is a
    # review item, not something this spec can catch. This only catches the
    # (weaker) signal of a resource *name* that says what it does.
    offenders = chef_run.resource_collection.all_resources.select do |r|
      r.declared_type.to_s == 'ruby_block' && r.name.to_s.match?(HOME_UBUNTU_COMMAND)
    end
    expect(offenders.map(&:to_s)).to eq([])
  end

  it 'runs every guard that names /home/ubuntu as ubuntu' do
    # A not_if/only_if guard is itself a command Chef shells out to run. If
    # its string mentions /home/ubuntu but its command_opts do not say
    # user: 'ubuntu', the guard runs as whatever the parent resource's
    # privileges are — root, on these resources — and can be fooled by the
    # same symlink trick the resource action itself is guarded against.
    offenders = []
    chef_run.resource_collection.all_resources.each do |r|
      next unless %w(execute directory file template cookbook_file).include?(r.declared_type.to_s)

      (r.not_if + r.only_if).each do |conditional|
        command = conditional.command
        next unless command.is_a?(String) && command.include?('/home/ubuntu')

        offenders << "#{r} guard #{command.inspect}" unless conditional.command_opts[:user] == 'ubuntu'
      end
    end
    expect(offenders).to eq([])
  end

  it 'runs every ubuntu-user execute (and script-family resource) as the ubuntu group with HOME set to /home/ubuntu' do
    offenders = chef_run.resource_collection.all_resources.select do |r|
      next false unless HOME_COMMAND_RESOURCES.include?(r.declared_type.to_s) && r.user == 'ubuntu'

      r.group != 'ubuntu' || !(r.environment.is_a?(Hash) && r.environment['HOME'] == '/home/ubuntu')
    end
    expect(offenders.map(&:to_s)).to eq([])
  end
end
