# Per-VM storage volumes. The VM spec lives in vms.json (also read by
# scripts/define-domains.py).
#
# libvirt *domains* are intentionally NOT managed here: the dmacvicar/libvirt
# provider can't set the qcow2 driver type or disk bus, so domains are
# defined by scripts/define-domains.py via `virsh`. Terraform owns the
# network and storage primitives; the script owns the domains.

locals {
  vm_spec = jsondecode(file("${path.module}/vms.json")).vms

  # Distinct base images referenced by the VM specs.
  base_images = {
    winserver2022 = "${var.base_images_path}/winserver2022-base.qcow2"
    win11         = "${var.base_images_path}/win11-base.qcow2"
    kali          = "${var.base_images_path}/kali-base.qcow2"
  }
}

# Importable base volumes. ignore_changes on source so terraform doesn't
# try to re-import once the volume exists.
resource "libvirt_volume" "base" {
  for_each = local.base_images
  name     = "nilgiri-${each.key}-base.qcow2"
  pool     = var.storage_pool
  source   = each.value
  format   = "qcow2"

  lifecycle {
    ignore_changes = [source]
  }
}

# Per-VM disk: copy-on-write qcow2 clone of the base volume. Lands at
# /mnt/vm-storage/${var.project}-${name}.qcow2 -- the deterministic path
# that define-domains.py references.
resource "libvirt_volume" "vm" {
  for_each       = local.vm_spec
  name           = "${var.project}-${each.key}.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.base[each.value.base].id
  format         = "qcow2"
}

output "vm_disk_paths" {
  description = "Per-VM qcow2 paths, for define-domains.py."
  value       = { for k, v in local.vm_spec : k => "/mnt/vm-storage/${var.project}-${k}.qcow2" }
}
