# Builds a Windows 11 base disk image for the workstation VMs
# (areuben-ws, operator-ws1).
#
# Requires UEFI + TPM 2.0. swtpm must be running on the host before
# `packer build` -- the Makefile target packer-win11 starts it. ISO is the
# 25H2 Enterprise Evaluation.
#
# Output: $output_dir/win11-base.qcow2 + win11-base_VARS.fd

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
  default = "/mnt/vm-storage/cyber-range/isos/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
}

# Windows 11 25H2 Enterprise Evaluation ISO (build 26200.6584, 2025-09-15).
variable "iso_sha256" {
  type    = string
  default = "a61adeab895ef5a4db436e0a7011c92a2ff17bb0357f58b13bbc4062e535e7b9"
}

variable "admin_password" {
  type      = string
  default   = "Nilgiri-W11!"
  sensitive = true
}

source "qemu" "win11" {
  iso_url      = var.iso_path
  iso_checksum = "sha256:${var.iso_sha256}"

  output_directory = "${var.output_dir}/build-win11"
  disk_size        = "60G"
  format           = "qcow2"
  accelerator      = "kvm"
  machine_type     = "q35"
  cpus             = 4
  memory           = 8192

  # Windows Setup has no virtio-blk driver; IDE is recognized natively.
  disk_interface = "ide"
  net_device     = "e1000"

  # Win11 requires UEFI + Secure Boot + TPM 2.0. The .ms.fd OVMF variant
  # ships with Microsoft secure-boot keys pre-enrolled.
  efi_boot          = true
  efi_firmware_code = "/usr/share/OVMF/OVMF_CODE_4M.ms.fd"
  efi_firmware_vars = "/usr/share/OVMF/OVMF_VARS_4M.ms.fd"

  use_default_display = false
  headless            = true
  vnc_bind_address    = "127.0.0.1"

  # swtpm socket-backed TPM 2.0 device. The Makefile starts swtpm against
  # this socket path before invoking packer.
  qemuargs = [
    ["-cpu", "host"],
    ["-display", "none"],
    ["-chardev", "socket,id=chrtpm,path=/tmp/tpm-packer-win11.sock"],
    ["-tpmdev", "emulator,id=tpm0,chardev=chrtpm"],
    ["-device", "tpm-tis,tpmdev=tpm0"],
  ]

  floppy_files = [
    "answer-files/win11/Autounattend.xml",
    "answer-files/win11/post-install.ps1",
    "scripts/enable-winrm.ps1",
  ]

  # UEFI shows "Press any key to boot from CD" for ~2s. Start typing at
  # t=1s and spam <enter> -- harmless once Setup has taken over.
  boot_wait = "1s"
  boot_command = [
    "<enter><wait1><enter><wait1><enter><wait1>",
    "<enter><wait1><enter><wait1><enter><wait1>",
    "<enter><wait1><enter><wait1><enter><wait1>",
    "<enter>",
  ]

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_timeout  = "2h"
  winrm_use_ssl  = false
  winrm_insecure = true

  # sysprep.ps1 powers the VM off itself; Packer just waits.
  shutdown_command = ""
  shutdown_timeout = "30m"
}

build {
  name    = "win11"
  sources = ["source.qemu.win11"]

  # Re-assert PreventDeviceEncryption and decrypt any volume auto-encryption
  # started: an encrypted C: makes the base image opaque to virt-customize.
  provisioner "powershell" {
    inline = [
      "reg add 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\BitLocker' /v PreventDeviceEncryption /t REG_DWORD /d 1 /f",
      "$ErrorActionPreference = 'SilentlyContinue'",
      "Get-BitLockerVolume | Where-Object { $_.VolumeStatus -ne 'FullyDecrypted' } | ForEach-Object { Disable-BitLocker -MountPoint $_.MountPoint }",
      "New-Item -ItemType Directory -Force -Path C:\\Windows\\Setup\\Scripts | Out-Null",
      "New-Item -ItemType Directory -Force -Path C:\\Windows\\Panther | Out-Null",
    ]
  }

  # Bake the clone-time unattend + WinRM bootstrap in here while WinRM is live
  # and the disk is plaintext; virt-customize can't do it post-build on
  # Win11's encrypted-by-default disk.
  provisioner "file" {
    source      = "answer-files/clone-oobe-unattend-win11.xml"
    destination = "C:/Windows/Panther/unattend.xml"
  }
  provisioner "file" {
    source      = "scripts/enable-winrm.ps1"
    destination = "C:/Windows/Setup/Scripts/enable-winrm.ps1"
  }

  # sysprep last. Defender/WU disabling is deferred to per-clone Ansible.
  provisioner "powershell" {
    script = "scripts/sysprep.ps1"
  }

  post-processor "shell-local" {
    inline = [
      "mv ${var.output_dir}/build-win11/packer-win11 ${var.output_dir}/win11-base.qcow2",
      "mv ${var.output_dir}/build-win11/efivars.fd ${var.output_dir}/win11-base_VARS.fd",
      "rm -rf ${var.output_dir}/build-win11",
    ]
  }
}
