#!/usr/bin/env bash
# m5_bake_installers.sh -- download SQL Server Express offline installer + SQL
# command-line tools on the libvirt host, then virt-customize them into
# db.oscar's COW volume (db.oscar has no internet egress). After this:
#   db.oscar: C:\Windows\Setup\mssql\{SQLEXPR_x64_ENU.exe, sqlcmd.msi}
#
# The ansible/sqli_webapp role installs SQL Server from there. Idempotent via a
# per-VM marker under $STATE_DIR; pass --force to re-bake.

set -euo pipefail

STAGING="/mnt/vm-storage/cyber-range/staging/m5"
STATE_DIR="/mnt/vm-storage/cyber-range/staging/m5/.state"
DB_VOL="/mnt/vm-storage/nilgiri-db.oscar.qcow2"
DB_DOM="nilgiri-db.oscar"
DC_VOL="/mnt/vm-storage/nilgiri-dc1.oscar.qcow2"
DC_DOM="nilgiri-dc1.oscar"

# URLs -- pinned for reproducibility. Override via env var if any 404.
# SQL Server 2019 Express offline installer (self-contained; the 2022 packaging
# phones home at install time, which the isolated victim can't do).
SQLEXPR_URL="${SQLEXPR_URL:-https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLEXPR_x64_ENU.exe}"
# sqlcmd.msi -- SQL command line tools (sqlcmd, bcp); used to seed SearchDb.
SQLCMD_URL="${SQLCMD_URL:-https://go.microsoft.com/fwlink/?linkid=2257938}"
# msodbcsql.msi -- ODBC driver 18, required by sqlcmd.
MSODBCSQL_URL="${MSODBCSQL_URL:-https://go.microsoft.com/fwlink/?linkid=2249004}"
# Legacy LAPS MSI -- adds the ms-Mcs-AdmPwd schema attribute we plant the M5.s4
# UUID into (built-in Windows LAPS isn't applied on the packer-built base).
LAPS_URL="${LAPS_URL:-https://download.microsoft.com/download/C/7/A/C7AAD914-A8A6-4904-88A1-29E657445D03/LAPS.x64.msi}"

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  "") ;;
  *) echo "usage: $0 [--force]" >&2; exit 2 ;;
esac

mkdir -p "$STAGING" "$STATE_DIR"

# ---- 1) download (idempotent: skip if file exists + non-empty) -----------
fetch() {
  local url=$1 dest=$2
  if [[ -s "$dest" ]]; then
    echo "  ok: $(basename "$dest") already staged ($(stat -c %s "$dest") bytes)"
    return
  fi
  echo "  fetching $(basename "$dest") from $url"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    echo "ERROR: download failed for $url" >&2
    echo "       drop the file manually at $dest and re-run." >&2
    exit 1
  fi
  mv "$dest.part" "$dest"
}

echo "==> staging installers under $STAGING"
fetch "$SQLEXPR_URL"   "$STAGING/SQLEXPR_x64_ENU.exe"
fetch "$SQLCMD_URL"    "$STAGING/sqlcmd.msi"
fetch "$MSODBCSQL_URL" "$STAGING/msodbcsql.msi"
fetch "$LAPS_URL"      "$STAGING/LAPS.x64.msi"

# Bake the .exe as-is; the role self-extracts it on the guest at install time:
#    SQLEXPR_x64_ENU.exe /Q /X:C:\Windows\Setup\mssql\extracted

# ---- 2) bake into db.oscar (idempotent via host-side marker) ------------
need_bake() {
  local marker=$1
  if [[ $FORCE -eq 1 ]]; then return 0; fi
  [[ ! -f "$marker" ]]
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE="$PROJECT_ROOT/.venv/bin/ansible-playbook"
INVENTORY="$PROJECT_ROOT/ansible/inventory/hosts.yml"
SHUTDOWN_PLAY="$PROJECT_ROOT/ansible/playbooks/_internal_shutdown.yml"

declare -A WIN_HOST
WIN_HOST[nilgiri-db.oscar]="db.oscar"
WIN_HOST[nilgiri-dc1.oscar]="dc1.oscar"

wait_for_winrm() {
  local dom=$1 ip=$2
  for _ in {1..60}; do
    if echo > /dev/tcp/"$ip"/5985 2>/dev/null; then return 0; fi
    sleep 2
  done
  echo "  WARN: $dom WinRM (5985) not reachable after 120s" >&2
  return 1
}

domain_ip() {
  case "$1" in
    nilgiri-db.oscar)  echo "10.30.0.21" ;;
    nilgiri-dc1.oscar) echo "10.30.0.10" ;;
    *) echo "" ;;
  esac
}

shutdown_vm() {
  local dom=$1
  local host="${WIN_HOST[$dom]:-}"
  if [[ -z "$host" ]]; then
    echo "  ERROR: no ansible host mapping for $dom" >&2; exit 1
  fi
  if ! virsh domstate "$dom" 2>/dev/null | grep -q running; then
    echo "  $dom is off; starting to let NTFS auto-recover"
    virsh start "$dom" >/dev/null
    wait_for_winrm "$dom" "$(domain_ip "$dom")" || true
    sleep 5
  fi
  echo "  graceful shutdown $dom via ansible WinRM"
  "$ANSIBLE" -i "$INVENTORY" "$SHUTDOWN_PLAY" -e "target_hosts=$host" >/dev/null || true
  for _ in {1..60}; do
    virsh domstate "$dom" 2>/dev/null | grep -q running || { echo "  $dom is off"; return; }
    sleep 2
  done
  echo "  WARN: $dom still running after 120s; falling back to destroy" >&2
  virsh destroy "$dom" >/dev/null
  sleep 3
}

start_vm() {
  local dom=$1
  if ! virsh domstate "$dom" 2>/dev/null | grep -q running; then
    echo "  starting $dom"
    virsh start "$dom" >/dev/null
  fi
}

# virt-customize needs root for the COW volumes (libvirt-qemu:kvm 644).
VC="sudo virt-customize"

bake_db() {
  local marker="$STATE_DIR/db.oscar.done"
  if ! need_bake "$marker"; then
    echo "==> db.oscar: marker present at $marker, skip (use --force)"
    return
  fi
  echo "==> baking SQL Server 2022 Express media into db.oscar"
  shutdown_vm "$DB_DOM"
  # guestfs uses Unix-style paths: C:\Windows\Setup -> /Windows/Setup.
  $VC -a "$DB_VOL" \
    --mkdir '/Windows/Setup/mssql' \
    --copy-in "$STAGING/SQLEXPR_x64_ENU.exe:/Windows/Setup/mssql" \
    --copy-in "$STAGING/sqlcmd.msi:/Windows/Setup/mssql" \
    --copy-in "$STAGING/msodbcsql.msi:/Windows/Setup/mssql"
  date -Iseconds > "$marker"
  start_vm "$DB_DOM"
}

bake_dc() {
  local marker="$STATE_DIR/dc1.oscar.done"
  if ! need_bake "$marker"; then
    echo "==> dc1.oscar: marker present at $marker, skip (use --force)"
    return
  fi
  echo "==> baking LAPS.x64.msi into dc1.oscar"
  shutdown_vm "$DC_DOM"
  $VC -a "$DC_VOL" \
    --mkdir '/Windows/Setup/laps' \
    --copy-in "$STAGING/LAPS.x64.msi:/Windows/Setup/laps"
  date -Iseconds > "$marker"
  start_vm "$DC_DOM"
}

bake_db
bake_dc

echo "==> done. installers live under:"
echo "    db.oscar      C:\\Windows\\Setup\\mssql\\"
echo "    dc1.oscar     C:\\Windows\\Setup\\laps\\"
