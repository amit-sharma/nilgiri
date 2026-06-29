# Builds a Windows Server 2022 base disk image for the cyber range.
#
# Inputs:
#   - ISO: Microsoft 180-day evaluation ISO for Windows Server 2022 Datacenter.
#     Download from https://www.microsoft.com/en-us/evalcenter/ before running.
#     Drop it at $output_dir/../isos/winserver2022.iso (or override iso_path).
#   - Autounattend.xml under packer/answer-files/winserver2022/
#     (creates Administrator with known password, enables WinRM, joins no domain).
#
# Output: $output_dir/winserver2022-base.qcow2  (sysprepped, generalized)
#
# Time: ~30-45 min on this host. Network needed only during ISO download;
# Packer builds on isolated libvirt network internal_only.

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
  type    = string
  default = "/mnt/vm-storage/cyber-range/isos/SERVER_EVAL_x64FRE_en-us.iso"
}

variable "iso_sha256" {
  type        = string
  description = "SHA-256 of the Win Server 2022 eval ISO. Pinned to the file dropped 2026-05-13."
  default     = "3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325"
}

variable "admin_password" {
  type      = string
  default   = "Nilgiri-WS2022!"
  sensitive = true
}

source "qemu" "winserver2022" {
  iso_url      = var.iso_path
  iso_checksum = "sha256:${var.iso_sha256}"

  output_directory = "${var.output_dir}/build-winserver2022"
  disk_size        = "60G"
  format           = "qcow2"
  accelerator      = "kvm"
  machine_type     = "q35"
  cpus             = 4
  memory           = 8192

  # Windows Setup has no built-in virtio-blk driver, so the install disk is
  # invisible under the Packer default; IDE is recognized natively.
  disk_interface = "ide"
  net_device     = "e1000"

  # UEFI without secure-boot. efi_boot plus the code+vars pair (pflash, not
  # -bios) is what makes qemu accept the OVMF firmware.
  efi_boot          = true
  efi_firmware_code = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  efi_firmware_vars = "/usr/share/OVMF/OVMF_VARS_4M.fd"
  use_default_display = false
  headless            = true
  vnc_bind_address    = "127.0.0.1"

  # Boot via Autounattend.xml on a virtual floppy.
  floppy_files = [
    "answer-files/winserver2022/Autounattend.xml",
    "answer-files/winserver2022/post-install.ps1",
    "scripts/enable-winrm.ps1",
    "scripts/sysprep-unattend.xml",
  ]

  # OVMF shows "Press any key to boot from CD or DVD" for ~2s, then falls
  # through to the EFI Shell. Start typing at t=1s and spam <enter>.
  boot_wait = "1s"
  boot_command = [
    "<enter><wait1><enter><wait1><enter><wait1>",
    "<enter><wait1><enter><wait1><enter><wait1>",
    "<enter><wait1><enter><wait1><enter><wait1>",
    "<enter>",
  ]

  communicator     = "winrm"
  winrm_username   = "Administrator"
  winrm_password   = var.admin_password
  winrm_timeout    = "4h"
  winrm_use_ssl    = false
  winrm_insecure   = true

  # sysprep.ps1 powers the VM off itself (/shutdown); empty shutdown_command
  # tells Packer to just wait.
  shutdown_command = ""
  shutdown_timeout = "30m"

  qemuargs = [
    ["-cpu", "host"],
    ["-display", "none"],
  ]
}

build {
  name    = "winserver2022"
  sources = ["source.qemu.winserver2022"]

  # NO disable-defender/disable-windows-update provisioners here: stopping
  # those services beforehand makes sysprep hang silently after Pnp_Drivers.
  # Defender/WU/OpenSSH are deferred to per-host Ansible roles run after each
  # clone boots.

  provisioner "powershell" {
    script = "scripts/sysprep.ps1"
  }

  post-processor "shell-local" {
    inline = [
      "mv ${var.output_dir}/build-winserver2022/packer-winserver2022 ${var.output_dir}/winserver2022-base.qcow2",
      # Keep the UEFI nvram vars file -- terraform's nvram block needs a
      # per-VM copy of it when cloning the base image.
      "mv ${var.output_dir}/build-winserver2022/efivars.fd ${var.output_dir}/winserver2022-base_VARS.fd",
      "rm -rf ${var.output_dir}/build-winserver2022",
    ]
  }
}
