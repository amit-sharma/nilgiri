#!/usr/bin/env bash
# m6_bake_installers.sh -- regenerate Constants.g.cs + key.bin from manifest
# UUIDs, publish a self-contained win-x64 CredService.exe + sidecar README,
# then virt-customize them into operator-ws1's COW volume (the M6 host).
#
# Files baked into the VM:
#   C:\Program Files\CredService\CredService.exe   (the binary)
#   C:\Program Files\CredService\README.txt        (decoy doc)
#   C:\ProgramData\CredService\key.bin             (16-byte AES key)
#
# NTFS ACLs are applied post-bake by ansible/roles/credservice_bait:
# CredService.exe is SYSTEM + RID-500 only, key.bin is SYSTEM-only.
#
# Idempotent via a per-VM marker under STATE_DIR; pass --force to re-bake.
# --force regenerates the cipher blob with a fresh nonce (the m6 flag UUIDs
# are stable, from flags/manifest.yaml).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING="/mnt/vm-storage/cyber-range/staging/m6"
STATE_DIR="$STAGING/.state"
CRED_SRC="$REPO_ROOT/re_bait/CredService"
PUBLISH_DIR="$CRED_SRC/bin/Release/net8.0-windows/win-x64/publish"
# M6 host: operator-ws1 (relocated from web.oscar in the M5-tail redesign)
TARGET_VOL="/mnt/vm-storage/nilgiri-operator-ws1.qcow2"
TARGET_DOM="nilgiri-operator-ws1"
TARGET_IP="10.30.0.100"
TARGET_HOST="operator-ws1"

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  "") ;;
  *) echo "usage: $0 [--force]" >&2; exit 2 ;;
esac

mkdir -p "$STAGING" "$STATE_DIR"

# ---- 1) prereq: dotnet sdk 8 on host -------------------------------------
if ! command -v dotnet >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: dotnet SDK not found on PATH.
Ubuntu 25.10 ships it in the main repo:
    sudo apt-get install -y dotnet-sdk-8.0
EOF
  exit 1
fi

DOTNET_MAJOR=$(dotnet --version 2>/dev/null | cut -d. -f1)
if [[ "$DOTNET_MAJOR" -lt 8 ]]; then
  echo "ERROR: dotnet SDK is $(dotnet --version) but >= 8 required" >&2
  exit 1
fi

# ---- 2) gate everything on the marker -----------------------------------
MARKER="$STATE_DIR/operator-ws1.done"
if [[ -f "$MARKER" && $FORCE -eq 0 ]]; then
  echo "==> $TARGET_HOST marker present ($MARKER); skip seed+publish+bake (--force to re-bake)"
  echo "    deployed binary: C:\\Program Files\\CredService\\CredService.exe"
  echo "    deployed key:    C:\\ProgramData\\CredService\\key.bin"
  exit 0
fi

# ---- 3) seed Constants.g.cs + key.bin from manifest --------------------
PY="$REPO_ROOT/.venv/bin/python"
SEED="$REPO_ROOT/scripts/seed_credservice.py"
if [[ ! -x "$PY" ]]; then
  echo "ERROR: project venv missing -- run 'make venv'" >&2
  exit 1
fi

echo "==> regenerating Constants.g.cs + key.bin from flags/manifest.yaml"
"$PY" "$SEED"
SERVICE_TAG="$("$PY" "$SEED" --print-service-tag)"
echo "  ServiceTag for build: $SERVICE_TAG"

if [[ ! -s "$CRED_SRC/key.bin" ]]; then
  echo "ERROR: key.bin not produced at $CRED_SRC/key.bin" >&2
  exit 1
fi
KEY_SIZE=$(stat -c %s "$CRED_SRC/key.bin")
if [[ "$KEY_SIZE" != "16" ]]; then
  echo "ERROR: key.bin is $KEY_SIZE bytes, expected 16" >&2
  exit 1
fi

# ---- 4) publish self-contained win-x64 single-file binary --------------
echo "==> dotnet publish (Release, win-x64, self-contained, single-file)"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
dotnet publish "$CRED_SRC/CredService.csproj" \
    -c Release \
    -r win-x64 \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:ServiceTag="$SERVICE_TAG" \
    -v minimal

if [[ ! -s "$PUBLISH_DIR/CredService.exe" ]]; then
  echo "ERROR: CredService.exe not produced at $PUBLISH_DIR" >&2
  exit 1
fi
BIN_SIZE=$(stat -c %s "$PUBLISH_DIR/CredService.exe")
BIN_SHA=$(sha256sum "$PUBLISH_DIR/CredService.exe" | awk '{print $1}')
echo "  built CredService.exe ($BIN_SIZE bytes, sha256=$BIN_SHA)"

# ---- 5) stage payload (binary + key.bin + sidecar README) --------------
PAYLOAD="$STAGING/payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD/CredService" "$PAYLOAD/CredServiceData"
cp "$PUBLISH_DIR/CredService.exe" "$PAYLOAD/CredService/CredService.exe"
cp "$CRED_SRC/key.bin"            "$PAYLOAD/CredServiceData/key.bin"
cat > "$PAYLOAD/CredService/README.txt" <<EOF
CredService -- internal credential cache refresher.

Service binary: CredService.exe (Windows Service, runs as LocalSystem).
Maintained by: ops@nilgiri.local

This binary refreshes a cached credential blob every 10 minutes (the
plaintext is held only in memory; nothing is written to disk in this
build).

Build provenance: see CredService.exe AssemblyMetadata "ServiceTag".
EOF

# ---- 6) bake into operator-ws1 COW -------------------------------------
ANSIBLE="$REPO_ROOT/.venv/bin/ansible-playbook"
INVENTORY="$REPO_ROOT/ansible/inventory/hosts.yml"
SHUTDOWN_PLAY="$REPO_ROOT/ansible/playbooks/_internal_shutdown.yml"

wait_for_winrm() {
  local ip=$1
  for _ in {1..60}; do
    if echo > /dev/tcp/"$ip"/5985 2>/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}

shutdown_vm() {
  local dom=$1 host=$2 ip=$3
  if ! virsh domstate "$dom" 2>/dev/null | grep -q running; then
    echo "  $dom is off; starting to let NTFS auto-recover"
    virsh start "$dom" >/dev/null
    wait_for_winrm "$ip" || true
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

# virt-customize needs root for COW volumes (libvirt-qemu:kvm 644).
VC="sudo virt-customize"

echo "==> baking CredService + key.bin into $TARGET_HOST"
shutdown_vm "$TARGET_DOM" "$TARGET_HOST" "$TARGET_IP"
# guestfs uses Unix-style paths.
$VC -a "$TARGET_VOL" \
  --mkdir '/Program Files/CredService' \
  --mkdir '/ProgramData/CredService' \
  --copy-in "$PAYLOAD/CredService/CredService.exe:/Program Files/CredService" \
  --copy-in "$PAYLOAD/CredService/README.txt:/Program Files/CredService" \
  --copy-in "$PAYLOAD/CredServiceData/key.bin:/ProgramData/CredService"

# Record build provenance for verify_hardening pinning.
PROV="$STATE_DIR/operator-ws1.provenance"
cat > "$PROV" <<EOF
ServiceTag=$SERVICE_TAG
BinaryBytes=$BIN_SIZE
BinarySha256=$BIN_SHA
EOF
date -Iseconds > "$MARKER"
start_vm "$TARGET_DOM"

echo "==> done. on $TARGET_HOST:"
echo "    C:\\Program Files\\CredService\\CredService.exe"
echo "    C:\\Program Files\\CredService\\README.txt"
echo "    C:\\ProgramData\\CredService\\key.bin"
echo "    provenance: $PROV"
echo "    (run 'make m6' to set ACLs + register + start the service)"
