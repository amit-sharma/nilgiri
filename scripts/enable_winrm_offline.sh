#!/usr/bin/env bash
# enable_winrm_offline.sh -- re-enable WinRM (5985) on a Windows range host
# offline (same mechanism as scripts/reset_host_admin_offline.sh): force-off,
# clear the NTFS dirty flag, inject a one-shot LocalSystem boot service via
# virt-win-reg that enables PSRemoting + opens 5985 for all profiles, then
# self-deletes.
#
# NOTE: edits the *current* disk state, not the clean-eval internal snapshot.
# Re-bake (make snapshot-all) afterwards if you want it to survive reverts.
#
# guestfish + virt-win-reg need sudo; virsh does not.
#
# Usage:
#   bash scripts/enable_winrm_offline.sh <libvirt-domain> <host-ip> [<poll-user> <poll-pass>]
# Example (dc1.alpha; verify auth with the alpha.local DA cred):
#   bash scripts/enable_winrm_offline.sh nilgiri-dc1.alpha 10.40.0.10 \
#       Administrator 'Alpha-DC-igcay25I4HehHawGFKfu!'

set -euo pipefail

DOM="${1:?libvirt domain, e.g. nilgiri-dc1.alpha}"
IP="${2:?host IP, e.g. 10.40.0.10}"
POLL_USER="${3:-}"
POLL_PASS="${4:-}"

DISK="$(virsh domblklist "$DOM" --details | awk '$2=="disk"{print $4; exit}')"
[ -n "$DISK" ] || { echo "ERROR: could not resolve disk for $DOM" >&2; exit 1; }
echo "domain : $DOM"
echo "disk   : $DISK"
echo "ip     : $IP"

# 1) Force-off (WinRM is down, so no graceful WinRM shutdown is possible).
if virsh domstate "$DOM" 2>/dev/null | grep -q running; then
    echo "==> force-off $DOM (virsh destroy)"
    virsh destroy "$DOM" >/dev/null
    sleep 3
else
    echo "==> $DOM already off"
fi

# 2) Clear the NTFS dirty flag so the volume mounts read-write (ntfsfix -d
#    CLEARS the dirty bit; plain ntfsfix sets it). See reset_host_admin_offline.
echo "==> clearing NTFS dirty flag (ntfsfix -d) so the volume mounts read-write"
sudo guestfish -a "$DISK" <<EOF || true
run
debug sh "for d in /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4 /dev/sda5 /dev/sda6; do ntfsfix -d -b \$d 2>/dev/null && echo cleared \$d; done; true"
EOF

# 3) Inject a one-shot boot service (WinRMFix) that enables PSRemoting + opens
#    5985 for all profiles, then deletes itself. The PowerShell is passed as a
#    base64 (UTF-16LE) -EncodedCommand so nothing needs escaping in the
#    registry ImagePath. Target the active control set.
echo "==> determining active ControlSet (HKEY_LOCAL_MACHINE\\SYSTEM\\Select\\Current)"
CUR="$(sudo virt-win-reg "$DISK" 'HKEY_LOCAL_MACHINE\SYSTEM\Select' 2>/dev/null \
        | awk -F'=' '/^"Current"/{gsub(/[^0-9]/,"",$2); print $2}')"
CUR="$((10#${CUR:-1}))"
CS="ControlSet$(printf '%03d' "$CUR")"
echo "    active control set: $CS"

REG="$(mktemp --suffix=.reg)"
CS="$CS" REG="$REG" python3 - <<'PY'
import os, base64
cs, path = os.environ["CS"], os.environ["REG"]
ps = (
    "$ErrorActionPreference='SilentlyContinue';"
    # Self-delete FIRST (the WinRM work below outlasts SCM's start timeout, so a
    # trailing delete would never run); the WinRM work is idempotent regardless.
    "Remove-Item 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\WinRMFix' -Recurse -Force;"
    "Enable-PSRemoting -Force -SkipNetworkProfileCheck;"
    "Set-Service WinRM -StartupType Automatic;"
    "Start-Service WinRM;"
    "Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -Enabled True -Profile Any -RemoteAddress Any;"
    "New-NetFirewallRule -DisplayName 'WinRM 5985 AllProfiles' -Name 'WinRM-5985-AllProfiles' "
    "-Direction Inbound -LocalPort 5985 -Protocol TCP -Action Allow -Profile Any"
)
enc = base64.b64encode(ps.encode("utf-16-le")).decode()
cmd = (r"C:\Windows\System32\cmd.exe /c powershell -NoProfile -ExecutionPolicy Bypass "
       f"-EncodedCommand {enc}")
def reg_esc(s): return s.replace("\\", "\\\\").replace('"', '\\"')
open(path, "w").write(
    "Windows Registry Editor Version 5.00\n\n"
    f"[HKEY_LOCAL_MACHINE\\SYSTEM\\{cs}\\Services\\WinRMFix]\n"
    '"Type"=dword:00000010\n'
    '"Start"=dword:00000002\n'
    '"ErrorControl"=dword:00000000\n'
    '"ObjectName"="LocalSystem"\n'
    '"DisplayName"="WinRMFix"\n'
    f'"ImagePath"="{reg_esc(cmd)}"\n'
)
PY
echo "==> inject boot-time WinRM-enable service (sudo virt-win-reg --merge)"
sudo virt-win-reg --merge "$DISK" "$REG"
rm -f "$REG"

# 4) Boot; SCM runs WinRMFix (enables WinRM, then self-deletes).
echo "==> start $DOM"
virsh start "$DOM" >/dev/null

# 5) Wait for 5985 to open (and optionally verify auth).
echo "==> waiting for WinRM (5985) to come up (up to ~6 min)..."
PYBIN="$(cd "$(dirname "$0")/.." && pwd)/.venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN=python3
IP="$IP" POLL_USER="$POLL_USER" POLL_PASS="$POLL_PASS" "$PYBIN" - <<'PY'
import os, time, sys, socket
IP=os.environ["IP"]; U=os.environ.get("POLL_USER",""); P=os.environ.get("POLL_PASS","")
deadline=time.time()+360; n=0
def port_open():
    try:
        s=socket.create_connection((IP,5985),timeout=4); s.close(); return True
    except Exception: return False
while time.time()<deadline:
    n+=1
    if port_open():
        print(f"[{n}] 5985 OPEN")
        if U and P:
            try:
                import winrm
                s=winrm.Session(f"http://{IP}:5985/wsman", auth=(U,P), transport="ntlm",
                                read_timeout_sec=25, operation_timeout_sec=15)
                r=s.run_cmd("whoami")
                if r.status_code==0:
                    print(f"    AUTH OK -> {r.std_out.decode().strip()}  (WinRM restored)")
                    sys.exit(0)
                print(f"    port open but cmd rc={r.status_code}")
            except Exception as e:
                print(f"    port open, auth not ready: {str(e).splitlines()[0][:60]}", flush=True)
        else:
            print("    (no poll creds given; port-open is success)"); sys.exit(0)
    else:
        print(f"[{n}] 5985 still closed", flush=True)
    time.sleep(20)
sys.exit("TIMED OUT -- WinRMFix may not have run; check the VM console / ControlSet")
PY

echo "==> done. If this was for a re-snapshot, vms-stop can now cleanly stop $DOM."
