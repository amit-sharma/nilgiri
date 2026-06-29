#!/usr/bin/env python3
"""Define the cyber-range libvirt domains via virsh.

VM list source of truth: terraform/libvirt/vms.json. Per-VM disk qcow2 files
are at /mnt/vm-storage/nilgiri-<name>.qcow2. Static IPs are pinned via DHCP
host reservations on the libvirt networks (deterministic MAC per VM).

Usage:
  define-domains.py [--start] [--undefine] [VM ...]
    (no VM args) operate on all VMs in vms.json
    --start      start each domain after defining
    --undefine   destroy + undefine instead of defining
"""

from __future__ import annotations
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
VMS_JSON = REPO / "terraform" / "libvirt" / "vms.json"
PROJECT = "nilgiri"
DISK_DIR = "/mnt/vm-storage"
IMAGES_DIR = "/mnt/vm-storage/cyber-range/images"

BASE_PROFILE = {
    "kali": {
        "uefi": False,
        "disk_bus": "virtio",
        "disk_dev": "vda",
        "nic_model": "virtio",
        "tpm": False,
    },
    "winserver2022": {
        "uefi": True,
        "ovmf_code": "/usr/share/OVMF/OVMF_CODE_4M.fd",
        "vars_template": f"{IMAGES_DIR}/winserver2022-base_VARS.fd",
        "disk_bus": "sata",
        "disk_dev": "sda",
        "nic_model": "e1000",
        "tpm": False,
    },
    "win11": {
        "uefi": True,
        "ovmf_code": "/usr/share/OVMF/OVMF_CODE_4M.ms.fd",
        "vars_template": f"{IMAGES_DIR}/win11-base_VARS.fd",
        "disk_bus": "sata",
        "disk_dev": "sda",
        "nic_model": "e1000",
        "tpm": True,
    },
}


def mac_for(name: str, suffix: str = "") -> str:
    """Deterministic MAC in the QEMU OUI (52:54:00) from the VM name (+ suffix per NIC)."""
    h = hashlib.md5(f"{name}{suffix}".encode()).hexdigest()
    return f"52:54:00:{h[0:2]}:{h[2:4]}:{h[4:6]}"


def interfaces_for(name: str, spec: dict) -> list[dict]:
    """Flatten {net, ip} + optional extra_nets into one list of NIC dicts."""
    nics = [{"net": spec["net"], "ip": spec["ip"], "mac": mac_for(name)}]
    for extra in spec.get("extra_nets", []):
        nics.append({
            "net": extra["net"],
            "ip": extra["ip"],
            "mac": mac_for(name, suffix=f"/{extra['net']}"),
        })
    return nics


def run(cmd: list[str], check: bool = True, quiet: bool = False) -> subprocess.CompletedProcess:
    if not quiet:
        print(f"  $ {' '.join(cmd)}")
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def domain_xml(name: str, spec: dict) -> str:
    prof = BASE_PROFILE[spec["base"]]
    dom = f"{PROJECT}-{name}"
    disk_path = f"{DISK_DIR}/{PROJECT}-{name}.qcow2"
    mem_kib = spec["memory_mb"] * 1024

    # Explicit loader+nvram form (per-VM writable nvram seeded from the VARS
    # template); format='qcow2' is required for internal snapshots of pflash VMs.
    if prof["uefi"]:
        nvram_path = f"{IMAGES_DIR}/{PROJECT}-{name}_VARS.fd"
        os_block = f"""  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash' format='raw'>{prof['ovmf_code']}</loader>
    <nvram template='{prof['vars_template']}' format='qcow2'>{nvram_path}</nvram>
    <boot dev='hd'/>
  </os>"""
    else:
        os_block = """  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>"""

    # vTPM (Win11 only).
    tpm_block = ""
    if prof["tpm"]:
        tpm_block = """    <tpm model='tpm-tis'>
      <backend type='emulator' version='2.0'/>
    </tpm>
"""

    disk_addr = ""

    # One <interface> per NIC; order is primary first, then extras in vms.json
    # order (matters for guest-side NIC enumeration eth0, eth1, ...).
    iface_xml = "\n".join(
        f"""    <interface type='network'>
      <source network='{PROJECT}-{nic['net']}'/>
      <mac address='{nic['mac']}'/>
      <model type='{prof['nic_model']}'/>
    </interface>"""
        for nic in interfaces_for(name, spec)
    )

    return f"""<domain type='kvm'>
  <name>{dom}</name>
  <memory unit='KiB'>{mem_kib}</memory>
  <currentMemory unit='KiB'>{mem_kib}</currentMemory>
  <vcpu placement='static'>{spec['cores']}</vcpu>
{os_block}
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='{disk_path}'/>
      <target dev='{prof['disk_dev']}' bus='{prof['disk_bus']}'/>
{disk_addr}    </disk>
{iface_xml}
{tpm_block}    <serial type='pty'><target type='isa-serial' port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <input type='tablet' bus='usb'/>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
    <video><model type='qxl'/></video>
    <memballoon model='virtio'/>
  </devices>
</domain>
"""


def dhcp_reservation(name: str, spec: dict) -> None:
    """Pin each NIC's static IP via DHCP host reservations on its network.

    Sweeps any stale entry matching this NIC's IP or name first. Non-primary
    NICs use a suffixed host name to avoid colliding with the primary.
    """
    for idx, nic in enumerate(interfaces_for(name, spec)):
        net = f"{PROJECT}-{nic['net']}"
        host_name = name if idx == 0 else f"{name}-{nic['net']}"
        for sweep in (f"<host ip='{nic['ip']}'/>", f"<host name='{host_name}'/>"):
            run(["virsh", "net-update", net, "delete", "ip-dhcp-host", sweep,
                 "--live", "--config"], check=False, quiet=True)
        host_xml = f"<host mac='{nic['mac']}' name='{host_name}' ip='{nic['ip']}'/>"
        res = run(["virsh", "net-update", net, "add", "ip-dhcp-host", host_xml,
                   "--live", "--config"], check=False)
        if res.returncode != 0:
            print(f"  ! net-update add failed on {net}: {res.stderr.strip()}", file=sys.stderr)


def define_vm(name: str, spec: dict, start: bool) -> None:
    print(f"[{name}] base={spec['base']} net={spec['net']} ip={spec['ip']}")
    dom = f"{PROJECT}-{name}"
    dhcp_reservation(name, spec)
    # Idempotent: tear down any prior definition first. --snapshots-metadata is
    # needed to undefine a domain that has snapshots; the qcow2-internal snapshot
    # data survives, but re-take snapshots after a script-driven recreate.
    run(["virsh", "destroy", dom], check=False, quiet=True)
    run(["virsh", "undefine", "--nvram", "--snapshots-metadata", dom],
        check=False, quiet=True)
    xml = domain_xml(name, spec)
    xml_path = Path(f"/tmp/{PROJECT}-{name}.xml")
    xml_path.write_text(xml)
    run(["virsh", "define", str(xml_path)])
    if start:
        run(["virsh", "start", dom], check=False)


def undefine_vm(name: str, spec: dict) -> None:
    dom = f"{PROJECT}-{name}"
    print(f"[{name}] destroy + undefine")
    run(["virsh", "destroy", dom], check=False, quiet=True)
    # --nvram so the per-VM UEFI vars file is removed too.
    run(["virsh", "undefine", "--nvram", dom], check=False)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("vms", nargs="*", help="VM names (default: all in vms.json)")
    ap.add_argument("--start", action="store_true", help="start each domain after defining")
    ap.add_argument("--undefine", action="store_true", help="destroy + undefine instead")
    args = ap.parse_args()

    spec = json.loads(VMS_JSON.read_text())["vms"]
    targets = args.vms or list(spec.keys())
    unknown = [v for v in targets if v not in spec]
    if unknown:
        print(f"unknown VM(s): {unknown}", file=sys.stderr)
        return 1

    for name in targets:
        if args.undefine:
            undefine_vm(name, spec[name])
        else:
            define_vm(name, spec[name], args.start)
    return 0


if __name__ == "__main__":
    sys.exit(main())
