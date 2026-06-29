#!/usr/bin/env python3
"""Move srv02 (fs-charlie) from oscar.local to charlie.local in config.json.

Run from ad/NILGIRI-V1/. Idempotent.
"""
import json
import sys
from pathlib import Path

cfg_path = Path(__file__).resolve().parents[1] / "data" / "config.json"
cfg = json.loads(cfg_path.read_text())

srv = cfg["lab"]["hosts"]["srv02"]

if srv["domain"] == "charlie.local":
    print("srv02 already on charlie.local; nothing to do.")
    sys.exit(0)

srv["domain"] = "charlie.local"
srv["path"] = "DC=charlie,DC=local"

# Swap the netbios prefix on local_groups members: oscar\<user> -> charlie\<user>.
for grp, members in srv.get("local_groups", {}).items():
    srv["local_groups"][grp] = [m.replace("oscar\\", "charlie\\") for m in members]

# Intentional misconfig: keep OSCAR\<user> references in the MSSQL sysadmins/
# impersonation map intact -- they create cross-domain MSSQL logins. Only fix
# the SPN that names the host's FQDN.
mssql = srv.get("mssql")
if mssql:
    for u in cfg["lab"]["domains"]["oscar.local"]["users"].values():
        u["spns"] = [s.replace("fs-charlie.oscar.local", "fs-charlie.charlie.local")
                     for s in u.get("spns", [])]

# Update sql_svc SPNs to point at charlie domain
oscar_users = cfg["lab"]["domains"]["oscar.local"]["users"]
if "sql_svc" in oscar_users:
    oscar_users["sql_svc"]["spns"] = [
        "MSSQLSvc/fs-charlie.charlie.local:1433",
        "MSSQLSvc/fs-charlie.charlie.local",
    ]

cfg_path.write_text(json.dumps(cfg, indent=4) + "\n")
print(f"Updated {cfg_path}: srv02 now on charlie.local")
