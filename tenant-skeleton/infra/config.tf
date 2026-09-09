locals {
  environment = "dev"

  instances = {
    cinc = {
      instance_type  = "c7a.large"
      volume_size_gb = 50
      key_name       = keys(var.ssh_key_pairs)[0]
      fqdn           = var.cinc_server_fqdn
      ufw_ports      = ["22/tcp", "80/tcp", "443/tcp"]
      tags           = { Purpose = "Security", Service = "CINC" }
      security_group_rules = {
        ssh = {
          type     = "ingress", from_port = 22, to_port = 22
          protocol = "tcp", cidr_blocks = ["0.0.0.0/0"], description = "SSH"
        }
        http = {
          type     = "ingress", from_port = 80, to_port = 80
          protocol = "tcp", cidr_blocks = ["0.0.0.0/0"], description = "HTTP (certbot)"
        }
        https = {
          type     = "ingress", from_port = 443, to_port = 443
          protocol = "tcp", cidr_blocks = ["0.0.0.0/0"], description = "CINC API"
        }
      }
    }
  }
}
