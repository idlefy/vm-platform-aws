# hardened_firstboot: keep ubuntu sudo-less on every NEW instance from this
# image — the AI agent runs as ubuntu and must not be root.
#
# Why this exists (design review C1): cloud-init recreates the default user on
# every new instance, sudo rule included (/etc/sudoers.d/90-cloud-init-users,
# NOPASSWD:ALL). On the fleet that rule is removed by base::sudoers, but only
# during a converge — and this image has no bootstrap and no converge after
# launch (law A1). Core's render_cloud_init sends only keys, never a `users:`
# block, so cloud-init falls back to system_info.default_user from the image.
#
# Two halves, because either alone is one mistake from root:
#   1. /etc/cloud/cloud.cfg.d/90-idlefy-hardened.cfg makes the default user
#      sudo-less at the source. cloud.cfg.d is merged in lexical order, so
#      this file sorts before 90_dpkg.cfg ('-' < '_'); 90_dpkg.cfg sets only
#      datasource_list and cannot undo default_user.
#   2. idlefy-hardened-firstboot.service, a root oneshot after cloud-init and
#      before ssh, deletes the sudoers fragments and strips sudo/admin/adm/lxd
#      from ubuntu on every boot, and logs whether it had anything to do.
#
# Enabled, not started: on the build instance cloud-init has already run and
# base::sudoers has already cleaned up; the image needs the unit on its next
# boots. The image scrub must not stop or disable it — it is for the
# customer's boots.
file '/etc/cloud/cloud.cfg.d/90-idlefy-hardened.cfg' do
  owner 'root'
  group 'root'
  mode '0644'
  content <<~CFG
    # Managed by CINC — base::hardened_firstboot. Do not edit on the VM.
    # cloud-init recreates the default user on every NEW instance from this
    # image, including its sudo rule. This makes that user sudo-less at the
    # source; idlefy-hardened-firstboot.service strips anything that slips past.
    system_info:
      default_user:
        name: ubuntu
        lock_passwd: true
        gecos: Ubuntu
        groups: [cdrom, dialout, plugdev]
        sudo: false
        shell: /bin/bash
  CFG
end

cookbook_file '/usr/local/sbin/idlefy-hardened-firstboot' do
  source 'idlefy-hardened-firstboot'
  owner 'root'
  group 'root'
  mode '0755'
end

systemd_unit 'idlefy-hardened-firstboot.service' do
  content <<~UNIT
    [Unit]
    Description=Strip the sudo cloud-init re-grants to ubuntu (Idlefy hardened image)
    After=cloud-init.service cloud-init-network.service
    Before=ssh.service systemd-user-sessions.service
    DefaultDependencies=no
    Conflicts=shutdown.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/local/sbin/idlefy-hardened-firstboot

    [Install]
    WantedBy=multi-user.target
  UNIT
  action [:create, :enable]
end
