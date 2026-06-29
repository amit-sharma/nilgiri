#!/usr/bin/env bash
# reset_host_admin_offline.sh -- recover a Windows range host whose local
# Administrator password is unknown. Force-offs the VM, clears the NTFS dirty
# flag, injects a one-shot LocalSystem boot service into the SYSTEM hive (via
# virt-win-reg) that resets + enables the local Administrator and self-deletes,
# restarts the VM, and waits for WinRM to accept the new password.
#
# NOTE: this edits the *current* disk state, not the clean-eval internal
# snapshot. After recovery + `make m9-seed`, re-bake the baseline
# (`make snapshot-all`) or the next revert will reintroduce the bad credential.
#
# guestfish + virt-win-reg need sudo; virsh does not.
#
# Usage:
#   bash scripts/reset_host_admin_offline.sh <libvirt-domain> <host-ip> '<new-password>'
# Example (secrets.alpha back to its inventory value):
#   bash scripts/reset_host_admin_offline.sh nilgiri-secrets.alpha 10.40.0.30 \
#       'Secrets-Alpha-PxoIOFiRMViSE2OJcq6P!'

set -euo pipefail

DOM="${1:?libvirt domain, e.g. nilgiri-secrets.alpha}"
IP="${2:?host IP, e.g. 10.40.0.30}"
PW="${3:?new Administrator password (single-quote it)}"

DISK="$(virsh domblklist "$DOM" --details | awk '$2=="disk"{print $4; exit}')"
[ -n "$DISK" ] || { echo "ERROR: could not resolve disk for $DOM" >&2; exit 1; }
echo "domain : $DOM"
echo "disk   : $DISK"
echo "ip     : $IP"

# 1) Force-off (no creds, so a graceful WinRM shutdown isn't possible).
if virsh domstate "$DOM" 2>/dev/null | grep -q running; then
    echo "==> force-off $DOM (virsh destroy)"
    virsh destroy "$DOM" >/dev/null
    sleep 3
else
    echo "==> $DOM already off"
fi

# 2) Clear the NTFS dirty flag so the volume mounts read-write. `ntfsfix -d`
#    CLEARS the dirty bit (plain `ntfsfix` SETS it). Run on every partition;
#    non-NTFS ones no-op.
echo "==> clearing NTFS dirty flag (ntfsfix -d) so the volume mounts read-write"
sudo guestfish -a "$DISK" <<EOF || true
run
debug sh "for d in /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4 /dev/sda5 /dev/sda6; do ntfsfix -d -b \$d 2>/dev/null && echo cleared \$d; done; true"
EOF

# 3) Inject a one-shot boot service into the SYSTEM hive (active control set).
#    SCM starts it as LocalSystem at next boot; it resets + enables the local
#    Administrator and self-deletes.
echo "==> determining active ControlSet (HKEY_LOCAL_MACHINE\\SYSTEM\\Select\\Current)"
CUR="$(sudo virt-win-reg "$DISK" 'HKEY_LOCAL_MACHINE\SYSTEM\Select' 2>/dev/null \
        | awk -F'=' '/^"Current"/{gsub(/[^0-9]/,"",$2); print $2}')"
CUR="$((10#${CUR:-1}))"   # force base-10 (strip zero-padding; avoid octal)
CS="ControlSet$(printf '%03d' "$CUR")"
echo "    active control set: $CS"

REG="$(mktemp --suffix=.reg)"
CS="$CS" PW="$PW" REG="$REG" python3 - <<'PY'
import os
cs, pw, path = os.environ["CS"], os.environ["PW"], os.environ["REG"]
cmd = (r"C:\Windows\System32\cmd.exe /c net user Administrator " + pw +
       " & net user Administrator /active:yes & sc delete PwFix")
def reg_esc(s): return s.replace("\\", "\\\\").replace('"', '\\"')
open(path, "w").write(
    "Windows Registry Editor Version 5.00\n\n"
    f"[HKEY_LOCAL_MACHINE\\SYSTEM\\{cs}\\Services\\PwFix]\n"
    '"Type"=dword:00000010\n'
    '"Start"=dword:00000002\n'
    '"ErrorControl"=dword:00000000\n'
    '"ObjectName"="LocalSystem"\n'
    '"DisplayName"="PwFix"\n'
    f'"ImagePath"="{reg_esc(cmd)}"\n'
)
PY
echo "==> inject boot-time password-reset service (sudo virt-win-reg --merge)"
sudo virt-win-reg --merge "$DISK" "$REG"
rm -f "$REG"

# 4) Boot; SCM runs the PwFix service (and it self-deletes after resetting).
echo "==> start $DOM"
virsh start "$DOM" >/dev/null

# 5) Wait for WinRM to accept the new password (firstboot may take a reboot).
echo "==> waiting for WinRM auth as Administrator (up to ~6 min)..."
# pywinrm lives in the repo venv, not system python.
PYBIN="$(cd "$(dirname "$0")/.." && pwd)/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN=python3
PW="$PW" IP="$IP" "$PYBIN" - <<'PY'
import os, time, sys
try:
    import winrm
except ImportError:
    sys.exit("pywinrm not importable; install in the repo venv "
             "(.venv/bin/pip install pywinrm) or retry the probe manually")
IP=os.environ["IP"]; PW=os.environ["PW"]
deadline=time.time()+360; n=0
while time.time()<deadline:
    n+=1
    try:
        s=winrm.Session(f"http://{IP}:5985/wsman", auth=("Administrator",PW),
                        transport="ntlm", read_timeout_sec=25, operation_timeout_sec=15)
        r=s.run_cmd("whoami")
        if r.status_code==0:
            print(f"[{n}] AUTH OK -> {r.std_out.decode().strip()}  (password reset succeeded)")
            sys.exit(0)
        print(f"[{n}] cmd rc={r.status_code}")
    except Exception as e:
        print(f"[{n}] not ready: {str(e).splitlines()[0][:60]}", flush=True)
    time.sleep(20)
sys.exit("TIMED OUT -- the PwFix service may not have run; check the VM console "
         "(virsh screenshot), confirm the active ControlSet, or see errors above")
PY

echo "==> recovered. Next: make m9-seed  (then re-bake: make snapshot-all)"
