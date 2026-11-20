# Is a snap installed? Used by base::no_ssm_agent.
#
# The answer must never be "no" because snapd could not be asked. A shell
# guard such as `snap wait system seed.loaded && snap list amazon-ssm-agent`
# exits non-zero both when the snap is absent and when snapd fails, and Chef
# reads every non-zero guard as "skip" — so a snapd error silently kept the
# agent on the image. Here a failed seeding wait or a failed `snap list`
# raises (Mixlib::ShellOut::ShellCommandFailed, with snapd's stderr), which
# fails the converge; only a successful listing that lacks the name is "no".
#
# `snap list` with no argument, not `snap list <name>`: the latter exits 1 for
# "no matching snaps installed" exactly as it does for "cannot communicate with
# server", and telling them apart would mean matching a message.
#
# installed_in? is pure Ruby so `make test` pins the parsing without Chef.
module DevVm
  module Snap
    SEED_TIMEOUT = 600 # seconds; `timeout` ends the wait, ShellOut's ceiling is a backstop

    def self.installed?(name)
      run!('timeout', SEED_TIMEOUT.to_s, 'snap', 'wait', 'system', 'seed.loaded')
      installed_in?(run!('snap', 'list'), name)
    end

    # list_output: `snap list` stdout — a `Name …` header and one row per snap,
    # or nothing at all when no snap is installed (snapd says so on stderr).
    def self.installed_in?(list_output, name)
      list_output.lines.map { |l| l.split.first }.compact.reject { |n| n == 'Name' }.include?(name)
    end

    def self.run!(*argv)
      require 'mixlib/shellout'
      c = Mixlib::ShellOut.new(*argv, timeout: SEED_TIMEOUT + 60, environment: { 'LC_ALL' => 'C' })
      c.run_command
      c.error!
      c.stdout
    end
  end
end
