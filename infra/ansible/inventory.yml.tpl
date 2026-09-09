# Populate from Terraform output:
#   terraform -chdir=.. output -json security_vms
# Copy to inventory.yml, replace <CINC_IP>
all:
  hosts:
    cinc:
      ansible_host: <CINC_IP>
      ansible_user: ubuntu
      ansible_become: true
