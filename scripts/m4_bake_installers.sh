#!/usr/bin/env bash
# m4_bake_installers.sh -- M4 bake step: download MediaWiki / PHP / MariaDB /
# KeePassXC installers on the libvirt host, then virt-customize them into the
# offline COW volumes. After it completes:
#   wiki.charlie:C:\Windows\Setup\wiki\{mediawiki.tar.gz, php-nts.zip, mariadb.msi}
#   fs.charlie:  C:\Windows\Setup\keepass\KeePassXC-Win64.msi
#
# The ansible/wiki_xss_csrf role installs them from there. Idempotent via a
# per-VM marker in $STATE_DIR; pass --force to re-bake. Does NOT snapshot --
# run `make snapshot-all SNAP_NAME=clean-eval` after M4 provisioning.

set -euo pipefail

STAGING="/mnt/vm-storage/cyber-range/staging/m4"
STATE_DIR="/mnt/vm-storage/cyber-range/staging/m4/.state"
WIKI_VOL="/mnt/vm-storage/nilgiri-wiki.charlie.qcow2"
FS_VOL="/mnt/vm-storage/nilgiri-fs.charlie.qcow2"
WIKI_DOM="nilgiri-wiki.charlie"
FS_DOM="nilgiri-fs.charlie"

# URLs -- pinned for reproducibility. Override via env var if any 404.
MW_URL="${MW_URL:-https://releases.wikimedia.org/mediawiki/1.43/mediawiki-1.43.3.tar.gz}"
PHP_URL="${PHP_URL:-https://windows.php.net/downloads/releases/archives/php-8.3.13-nts-Win32-vs16-x64.zip}"
MARIADB_URL="${MARIADB_URL:-https://archive.mariadb.org/mariadb-11.4.4/winx64-packages/mariadb-11.4.4-winx64.msi}"
KEEPASS_URL="${KEEPASS_URL:-https://github.com/keepassxreboot/keepassxc/releases/download/2.7.9/KeePassXC-2.7.9-Win64.msi}"
# MW extensions -- NOT bundled with the tarball. GitHub mirrors have
# stable branch URLs (REL1_43 matches the MW major).
AUTHRU_URL="${AUTHRU_URL:-https://github.com/wikimedia/mediawiki-extensions-Auth_remoteuser/archive/refs/heads/REL1_43.tar.gz}"
LOCKDOWN_URL="${LOCKDOWN_URL:-https://github.com/wikimedia/mediawiki-extensions-Lockdown/archive/refs/heads/REL1_43.tar.gz}"
# Visual C++ Redistributable -- PHP 8.x Windows builds require it.
# Server 2022 doesn't ship it; without it, php.exe crashes at startup
# with STATUS_DLL_NOT_FOUND (0xC0000135). aka.ms link is stable.
VCREDIST_URL="${VCREDIST_URL:-https://aka.ms/vs/17/release/vc_redist.x64.exe}"

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
fetch "$MW_URL"       "$STAGING/mediawiki.tar.gz"
fetch "$PHP_URL"      "$STAGING/php-nts.zip"
fetch "$MARIADB_URL"  "$STAGING/mariadb.msi"
fetch "$KEEPASS_URL"  "$STAGING/KeePassXC-Win64.msi"
fetch "$AUTHRU_URL"   "$STAGING/Auth_remoteuser-REL1_43.tar.gz"
fetch "$LOCKDOWN_URL" "$STAGING/Lockdown-REL1_43.tar.gz"
fetch "$VCREDIST_URL" "$STAGING/vc_redist.x64.exe"

# ---- 2) per-VM bake (idempotent via host-side marker) -------------------
need_bake() {
  local marker=$1
  if [[ $FORCE -eq 1 ]]; then return 0; fi
  [[ ! -f "$marker" ]]
}

# Windows VMs ignore virsh ACPI shutdown and a virsh destroy leaves NTFS dirty
# (libguestfs then mounts read-only), so shut down gracefully from inside
# Windows via the WinRM ansible play. If the VM is off, start it first so
# Windows boot-CHKDSK auto-cleans NTFS, then shut down cleanly.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE="$PROJECT_ROOT/.venv/bin/ansible-playbook"
INVENTORY="$PROJECT_ROOT/ansible/inventory/hosts.yml"
SHUTDOWN_PLAY="$PROJECT_ROOT/ansible/playbooks/_internal_shutdown.yml"

# Map domain name -> ansible inventory hostname
declare -A WIN_HOST
WIN_HOST[nilgiri-wiki.charlie]="wiki.charlie"
WIN_HOST[nilgiri-fs.charlie]="fs.charlie"

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
    nilgiri-wiki.charlie) echo "10.20.0.21" ;;
    nilgiri-fs.charlie)   echo "10.20.0.20" ;;
    *) echo "" ;;
  esac
}

shutdown_vm() {
  local dom=$1
  local host="${WIN_HOST[$dom]:-}"
  if [[ -z "$host" ]]; then
    echo "  ERROR: no ansible host mapping for $dom" >&2; exit 1
  fi
  # If off (likely from a previous failed bake), start + let Windows
  # auto-CHKDSK + wait for WinRM. Then graceful shutdown.
  if ! virsh domstate "$dom" 2>/dev/null | grep -q running; then
    echo "  $dom is off; starting to let NTFS auto-recover"
    virsh start "$dom" >/dev/null
    wait_for_winrm "$dom" "$(domain_ip "$dom")" || true
    sleep 5  # let auto-CHKDSK flush
  fi
  echo "  graceful shutdown $dom via ansible WinRM"
  "$ANSIBLE" -i "$INVENTORY" "$SHUTDOWN_PLAY" -e "target_hosts=$host" >/dev/null || true
  # Wait up to 120s for the VM to actually power off
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

bake_wiki() {
  local marker="$STATE_DIR/wiki.charlie.done"
  if ! need_bake "$marker"; then
    echo "==> wiki.charlie: marker present at $marker, skip (use --force)"
    return
  fi
  echo "==> baking MediaWiki stack into wiki.charlie"
  shutdown_vm "$WIKI_DOM"
  # virt-customize uses guestfs paths (Unix-style, no drive letter); on a
  # Windows guest the C: filesystem is mounted at /, so C:\Windows\Setup
  # is /Windows/Setup here.
  $VC -a "$WIKI_VOL" \
    --mkdir '/Windows/Setup/wiki' \
    --copy-in "$STAGING/mediawiki.tar.gz:/Windows/Setup/wiki" \
    --copy-in "$STAGING/php-nts.zip:/Windows/Setup/wiki" \
    --copy-in "$STAGING/mariadb.msi:/Windows/Setup/wiki" \
    --copy-in "$STAGING/Auth_remoteuser-REL1_43.tar.gz:/Windows/Setup/wiki" \
    --copy-in "$STAGING/Lockdown-REL1_43.tar.gz:/Windows/Setup/wiki" \
    --copy-in "$STAGING/vc_redist.x64.exe:/Windows/Setup/wiki"
  date -Iseconds > "$marker"
  start_vm "$WIKI_DOM"
}

bake_fs() {
  local marker="$STATE_DIR/fs.charlie.done"
  if ! need_bake "$marker"; then
    echo "==> fs.charlie: marker present at $marker, skip (use --force)"
    return
  fi
  echo "==> baking KeePassXC into fs.charlie"
  shutdown_vm "$FS_DOM"
  $VC -a "$FS_VOL" \
    --mkdir '/Windows/Setup/keepass' \
    --copy-in "$STAGING/KeePassXC-Win64.msi:/Windows/Setup/keepass"
  date -Iseconds > "$marker"
  start_vm "$FS_DOM"
}

bake_wiki
bake_fs

echo "==> done. installers live under:"
echo "    wiki.charlie  C:\\Windows\\Setup\\wiki\\"
echo "    fs.charlie    C:\\Windows\\Setup\\keepass\\"
