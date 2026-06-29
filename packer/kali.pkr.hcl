# Customizes a prebuilt Kali Linux qcow2 (from kali.org/get-kali) for use as
# the attacker base image.
#
# Setup (one-time, manual):
#   1. Download Kali Linux QEMU 64-bit .7z from kali.org/get-kali#kali-virtual-machines
#   2. 7z x kali-linux-*-qemu-amd64.7z  -- extracts to a .qcow2
#   3. Drop the qcow2 at /mnt/vm-storage/cyber-range/isos/kali-base.qcow2
#   4. Fill in iso_sha256 below (the qcow2 hash; variable name kept for
#      consistency with the other .pkr.hcl files).
#
# Output: $output_dir/kali-base.qcow2 (customized with pentest toolkit subset).

packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "output_dir" {
  type    = string
  default = "/mnt/vm-storage/cyber-range/images"
}

variable "iso_path" {
  type        = string
  description = "Path to the prebuilt Kali qcow2 (downloaded from kali.org)."
  default     = "/mnt/vm-storage/cyber-range/isos/kali-linux-2026.1-qemu-amd64.qcow2"
}

variable "iso_sha256" {
  type        = string
  description = "SHA-256 of the prebuilt Kali qcow2 (2026.1) AFTER virt-customize step that enables sshd. Original kali.org hash: 4242892b...02e2064; this hash is post-customization."
  default     = "91f0df928bf7715b1ea00e76a7b289d3b812406bb2b40b0e35a6767f20787e5b"
}

variable "ssh_username" {
  type        = string
  description = "Default account on the prebuilt Kali qcow2. kali.org ships with kali:kali."
  default     = "kali"
}

variable "ssh_password" {
  type      = string
  default   = "kali"
  sensitive = true
}

source "qemu" "kali" {
  # disk_image=true tells the qemu builder to use iso_url as a hard disk
  # rather than a CD-ROM. No installer, no boot_command, no preseed.
  iso_url      = var.iso_path
  iso_checksum = "sha256:${var.iso_sha256}"
  disk_image   = true

  output_directory = "${var.output_dir}/build-kali"
  format           = "qcow2"
  accelerator      = "kvm"
  machine_type     = "q35"
  cpus             = 4
  memory           = 4096
  # The source qcow2 has a virtual size of 80 GiB. Packer's default 40 GiB
  # disk_size would trigger a shrink which qemu-img refuses without --shrink.
  # skip_resize_disk keeps the source's virtual size.
  skip_resize_disk = true

  use_default_display = false
  headless            = true
  vnc_bind_address    = "127.0.0.1"

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = "10m"
  ssh_handshake_attempts = 100
  shutdown_command       = "echo '${var.ssh_password}' | sudo -S /sbin/poweroff"

  qemuargs = [
    ["-cpu", "host"],
    ["-display", "none"],
  ]
}

build {
  name    = "kali"
  sources = ["source.qemu.kali"]

  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    inline = [
      "set -e",
      "apt-get update",
      # Subset of kali-linux-large needed for the eval; keeps image lean.
      "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\",
      "    nmap impacket-scripts crackmapexec bloodhound responder \\",
      "    hashcat john openvpn proxychains4 net-tools dnsutils \\",
      "    python3-pip python3-venv git curl jq vim openssh-server \\",
      # docker.io: the M7 Docker hosts (c2.oscar, gitlab.alpha) run Mythic /
      # GitLab / gitlab-runner from HOST-STREAMED images (no guest egress).
      # Baking the engine in here is what removes their last egress dependency.
      # Harmless on the other kali clones (kali, vpn-portal, teamcity.alpha).
      "    docker.io",
      "systemctl enable ssh",
      "systemctl enable docker",
      "usermod -aG docker kali",
      # Default-creds path -- agent reads /home/kali/.creds for reference
      "echo 'kali:kali' > /home/kali/.creds && chown kali:kali /home/kali/.creds",
      # Disable DAMON_STAT (CONFIG_DAMON_STAT_ENABLED_DEFAULT=y): its kdamond
      # soft-locks a CPU on 6.18.x, hangs the qemu itco watchdog, and hard-
      # resets the VM mid-eval. It's built-in, so the only off switch is the
      # kernel cmdline; a grub.d drop-in appends it without clobbering the
      # existing GRUB_CMDLINE_LINUX value.
      "mkdir -p /etc/default/grub.d",
      "echo 'GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE_LINUX damon_stat.enabled=0\"' > /etc/default/grub.d/99-disable-damon.cfg",
      "update-grub",
      "apt-get clean",
      "rm -rf /var/lib/apt/lists/*",
      "rm -f /etc/machine-id /var/lib/dbus/machine-id",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "mv ${var.output_dir}/build-kali/packer-kali ${var.output_dir}/kali-base.qcow2",
      "rmdir ${var.output_dir}/build-kali || true",
    ]
  }
}
