name 'dev-vm'
run_list 'base::default'

cookbook 'base', git: 'https://github.com/idlefy/vm-platform-aws.git', tag: 'base-REPLACE_ME', rel: 'cinc/cookbooks/base'

# Log shipping to Grafana Cloud Loki. Twin of `log_shipping` in
# vms/tenant.auto.tfvars — `make preflight` fails if they disagree.
# false ⇒ set `enabled` to false and delete the three lines below it; the recipe tears Alloy down.
default['base']['loki']['enabled']            = true
default['base']['loki']['ssm_parameter_name'] = '/developer-vms/observability/loki-token'
default['base']['loki']['url']                = 'REPLACE_ME'
default['base']['loki']['username']           = 'REPLACE_ME'
default['base']['traefik']['acme_email']      = 'REPLACE_ME'
default['base']['traefik']['domain_root']     = 'REPLACE_ME'
