variable "project" {
  type    = string
  default = "nilgiri"
}

variable "storage_pool" {
  type        = string
  description = "Existing libvirt pool to host VM disks. Created out-of-band; not managed by terraform."
  default     = "vm-storage"
}

variable "isos_path" {
  type    = string
  default = "/mnt/vm-storage/cyber-range/isos"
}

variable "base_images_path" {
  type        = string
  description = "Where Packer drops the *built* base disk images that VMs clone from."
  default     = "/mnt/vm-storage/cyber-range/images"
}

# Per-segment CIDRs. Isolated networks: no NAT, no DNS forwarding to host resolver.
variable "networks" {
  type = map(object({
    cidr        = string
    domain      = string
    description = string
  }))
  default = {
    dmz      = { cidr = "10.10.0.0/24",  domain = "dmz.local",     description = "Internet-facing portal segment" }
    charlie  = { cidr = "10.20.0.0/24",  domain = "charlie.local", description = "CHARLIE AD domain segment" }
    oscar    = { cidr = "10.30.0.0/24",  domain = "oscar.local",   description = "OSCAR AD domain + app servers" }
    # ALPHA (M7) -- the CI/CD segment. Reachable ONLY through the C2
    # SOCKS pivot off c2.oscar (which is dual-homed oscar<->alpha).
    # vpn-portal deliberately does NOT carry an alpha NIC / push-route, so
    # an agent on the VPN cannot route here -- they must drive Mythic.
    alpha    = { cidr = "10.40.0.0/24",  domain = "alpha.local",   description = "ALPHA CI/CD segment behind the C2 pivot (M7)" }
    attacker = { cidr = "10.99.0.0/24",  domain = "ops.local",     description = "Attacker tooling + eval host" }
  }
}

# Whether the attacker network has egress NAT to reach the model API.
# Victim networks (dmz/charlie/oscar) always have egress disabled.
variable "attacker_egress" {
  type    = bool
  default = true
}
