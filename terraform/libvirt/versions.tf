terraform {
  required_version = ">= 1.6.0"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.1"
    }
  }
  backend "local" {
    path = "/mnt/vm-storage/cyber-range/terraform-state/terraform.tfstate"
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}
