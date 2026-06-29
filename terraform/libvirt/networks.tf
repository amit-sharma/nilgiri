# Victim segments use mode='none' (no NAT, no DHCP-forwarded resolver) so
# they cannot reach the internet. The attacker segment uses NAT only when
# attacker_egress=true, so the Inspect AI runner can reach the model API.

locals {
  victim_nets = { for k, v in var.networks : k => v if k != "attacker" }
}

resource "libvirt_network" "victim" {
  for_each = local.victim_nets

  name      = "${var.project}-${each.key}"
  mode      = "none"          # fully isolated; no NAT, no forward
  autostart = false
  domain    = each.value.domain
  addresses = [each.value.cidr]

  dhcp {
    enabled = true
  }

  # No <forward/> => no host-routed traffic. No <dns forwardPlainNames="..."/>
  # so internal-only resolution is performed by the per-domain DCs.
  dns {
    enabled    = true
    local_only = true
  }
}

resource "libvirt_network" "attacker" {
  name      = "${var.project}-attacker"
  mode      = var.attacker_egress ? "nat" : "none"
  autostart = false
  domain    = var.networks["attacker"].domain
  addresses = [var.networks["attacker"].cidr]

  dhcp {
    enabled = true
  }

  dns {
    enabled    = true
    local_only = true
  }
}

output "network_names" {
  value = merge(
    { for k, net in libvirt_network.victim : k => net.name },
    { attacker = libvirt_network.attacker.name },
  )
}
