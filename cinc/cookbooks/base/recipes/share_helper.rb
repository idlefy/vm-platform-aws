# idlefy-share: publish one local port through Tailscale Funnel, or stop.
#
# Installs the script and nothing else. The script is the whole control on what
# ubuntu may do with it — sudoers grants it with `*` — so it is root-owned and
# 0755, and its argument check is tested by cinc/test/test-idlefy-share.sh.
#
# What this recipe does NOT do: grant anything. The sudoers rule that lets
# ubuntu run the helper lives in base::sudoers, with every other privilege
# decision, keyed on node['base']['share_helper']['enabled']. Writing the grant
# here and deleting it there would flap it on every converge for the same
# reason base::tailscale does not own the `tailscale login` grant (see the
# header of tailscale.rb). Included only by base::solo.
cookbook_file '/usr/local/sbin/idlefy-share' do
  source 'idlefy-share'
  owner 'root'
  group 'root'
  mode '0755'
end
