# The vm-storage pool already exists on the host (managed out-of-band).
# We reference it by name; we do not (re)define it here to avoid
# clobbering other VMs that share it.
data "libvirt_node_info" "host" {}

# Per-VM disk volumes are created in vms.tf using `pool = var.storage_pool`.
# Base images built by Packer land under var.base_images_path and are
# imported as "base volumes" that per-VM disks copy-on-write from.
