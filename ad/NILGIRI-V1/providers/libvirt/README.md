# NILGIRI-V1 libvirt provider

Unlike the upstream GOAD providers (proxmox/aws/azure/vmware/ludus), the
libvirt infrastructure for NILGIRI-V1 is *not* fully managed inside
this directory. Instead:

- **Networks + VM domains + volumes** are managed by the top-level
  [terraform/libvirt/](../../../../terraform/libvirt/) stack. That stack
  provisions 10 VMs total; the 3 GOAD VMs (`dc1.charlie`, `dc1.oscar`,
  `fs.charlie`) are a subset. The other 7 (`vpn-portal`, `wiki.charlie`,
  `areuben-ws`, `web.oscar`, `db.oscar`, `operator-ws1`, `kali`) are not
  GOAD's responsibility -- they're our application-layer hosts wired up
  by our own Ansible roles.

- **AD provisioning** (domain controllers, OUs, users, ACLs, vulns,
  scripts) still runs from GOAD's `ansible/` playbooks against the
  inventory in this directory.

Why split it: GOAD's terraform-provider model assumes one provider owns
all infra. We want a richer topology, so we let our own terraform own
the substrate and use GOAD purely as the AD provisioning engine.

## Files in this directory

- `inventory` -- Ansible inventory mapping GOAD's host nicknames (`dc01`,
  `dc02`, `srv02`) to libvirt IPs in our 10.20.0/24 (charlie) and
  10.30.0/24 (oscar) networks. Loaded by GOAD's `goad.py` when provider
  is set to "libvirt".
- `windows.tf` -- A stub explaining that VM provisioning is delegated
  upstream. Present for parity with other GOAD providers.

## Mapping table

| GOAD nick | hostname            | role          | IP          | net     | base image    |
|-----------|---------------------|---------------|-------------|---------|---------------|
| dc01      | dc1.charlie.local   | charlie DC    | 10.20.0.10  | charlie | winserver2022 |
| dc02      | dc1.oscar.local     | oscar DC      | 10.30.0.10  | oscar   | winserver2022 |
| srv02     | fs.charlie.local    | charlie FS    | 10.20.0.20  | charlie | winserver2022 |
