#!/usr/bin/env bash
# m8_m9_bake_installers.sh -- stage everything M8/M9 needs that requires host
# tooling or egress, before the alpha segment is (re-)isolated.
#
# PHASE A (host-side, needs egress) -- build an OFFLINE dotnet SDK image: pull
#   the SDK, run one self-contained win-x64 publish to warm the NuGet caches,
#   then `docker commit` -> dotnet-sdk-offline:8.0, so the gitlab.alpha runner
#   can cross-compile DeployAgent.exe with the segment isolated. Also stages the
#   SQL Server media (reuses M5's download if present).
#
# PHASE B (transfer to guests, no guest egress) --
#   - stream dotnet-sdk-offline:8.0 into gitlab.alpha (docker save | ssh load);
#   - virt-customize the SQL Server media into secrets.alpha's COW volume
#     (C:\Windows\Setup\mssql\, identical to M5's db.oscar bake).
#
# Idempotent via per-target markers under STATE_DIR; pass --force to redo.
#
# KEEP IN SYNC: dotnet image tag with supply_chain_deploy/defaults (sc_dotnet_image).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING="/mnt/vm-storage/cyber-range/staging/m8m9"
M5_STAGING="/mnt/vm-storage/cyber-range/staging/m5"
STATE_DIR="$STAGING/.state"

DOTNET_BASE="mcr.microsoft.com/dotnet/sdk:8.0"
DOTNET_OFFLINE="dotnet-sdk-offline:8.0"

# SQL media (same set M5 stages). Reuse M5's download dir if it has them.
SQLEXPR_URL="${SQLEXPR_URL:-https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLEXPR_x64_ENU.exe}"
SQLCMD_URL="${SQLCMD_URL:-https://go.microsoft.com/fwlink/?linkid=2257938}"
MSODBCSQL_URL="${MSODBCSQL_URL:-https://go.microsoft.com/fwlink/?linkid=2249004}"

# secrets.alpha (Windows) bake target.
SECRETS_VOL="/mnt/vm-storage/nilgiri-secrets.alpha.qcow2"
SECRETS_DOM="nilgiri-secrets.alpha"
SECRETS_IP="10.40.0.30"
SECRETS_HOST="secrets.alpha"

# gitlab.alpha (Linux Docker host) -- the runner host that needs the image.
GITLAB_IP="10.40.0.20"

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  "") ;;
  *) echo "usage: $0 [--force]" >&2; exit 2 ;;
esac

mkdir -p "$STAGING" "$STATE_DIR"
need_bake() { [[ $FORCE -eq 1 ]] && return 0; [[ ! -f "$1" ]]; }

############################################################################
# PHASE A -- offline dotnet image + SQL media (host-side, needs egress)
############################################################################
warm_dotnet_image() {
  local marker="$STATE_DIR/dotnet-offline.done"
  if ! need_bake "$marker" && docker image inspect "$DOTNET_OFFLINE" >/dev/null 2>&1; then
    echo "==> dotnet offline image present; skip (--force to redo)"; return
  fi
  command -v docker >/dev/null || { echo "ERROR: docker not on host"; exit 1; }
  echo "==> pulling $DOTNET_BASE + warming NuGet caches for offline win-x64 publish"
  docker pull "$DOTNET_BASE"
  docker rm -f m8m9-nugetwarm >/dev/null 2>&1 || true
  # One publish identical to the CI command populates ~/.nuget with the
  # win-x64 runtime/apphost + single-file bundler packs.
  docker run --name m8m9-nugetwarm "$DOTNET_BASE" bash -lc '
    set -e
    mkdir -p /warm && cd /warm
    dotnet new console -o app >/dev/null
    cd app
    dotnet publish app.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o /tmp/out
    echo "warm publish ok: $(ls -1 /tmp/out)"
  '
  docker commit m8m9-nugetwarm "$DOTNET_OFFLINE" >/dev/null
  docker rm -f m8m9-nugetwarm >/dev/null
  echo "  committed $DOTNET_OFFLINE (NuGet caches baked in)"
  date -Iseconds > "$marker"
}

fetch() {
  local url=$1 dest=$2
  if [[ -s "$dest" ]]; then echo "  ok: $(basename "$dest") staged"; return; fi
  # Reuse M5's download if it already pulled this file.
  local m5f="$M5_STAGING/$(basename "$dest")"
  if [[ -s "$m5f" ]]; then echo "  reuse M5 staged $(basename "$dest")"; cp "$m5f" "$dest"; return; fi
  echo "  fetching $(basename "$dest")"
  curl -fL --retry 3 --retry-delay 2 -o "$dest.part" "$url" || { rm -f "$dest.part"; echo "ERROR: download $url failed" >&2; exit 1; }
  mv "$dest.part" "$dest"
}

stage_sql_media() {
  echo "==> staging SQL Server media under $STAGING"
  fetch "$SQLEXPR_URL"   "$STAGING/SQLEXPR_x64_ENU.exe"
  fetch "$SQLCMD_URL"    "$STAGING/sqlcmd.msi"
  fetch "$MSODBCSQL_URL" "$STAGING/msodbcsql.msi"
}

############################################################################
# PHASE B -- transfer to the no-egress guests
############################################################################
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
# Default to the post-rotation kali password (gitlab.alpha was rotated to close the
# m7.s5 Rails-console shortcut). Override via KALI_SSH_PASS for hosts still at the
# base default.
KALI_SSH_PASS="${KALI_SSH_PASS:-08d3ec40a4e0772c1af26c80}"
rcmd() { local ip=$1; shift; sshpass -p "$KALI_SSH_PASS" ssh "${SSH_OPTS[@]}" kali@"$ip" "$@"; }

stream_dotnet_to_gitlab() {
  local marker="$STATE_DIR/gitlab.alpha.dotnet.done"
  if ! need_bake "$marker"; then echo "==> gitlab.alpha dotnet image marker present; skip"; return; fi
  command -v sshpass >/dev/null || { echo "ERROR: sshpass not installed"; exit 1; }
  echo "==> streaming $DOTNET_OFFLINE -> gitlab.alpha ($GITLAB_IP)"
  docker save "$DOTNET_OFFLINE" | rcmd "$GITLAB_IP" 'cat > /var/tmp/m8m9-dotnet.tar'
  # kali (the guest login user) is in the docker group, so docker needs no sudo.
  # Guest sudo requires a password (no NOPASSWD) and has no tty over ssh, so
  # `sudo docker load` would hang/fail -- run docker directly instead.
  rcmd "$GITLAB_IP" 'docker load -i /var/tmp/m8m9-dotnet.tar && rm -f /var/tmp/m8m9-dotnet.tar' | tail -2
  date -Iseconds > "$marker"
}

# --- secrets.alpha SQL media virt-customize (M5 db.oscar pattern) ---------
ANSIBLE="$REPO_ROOT/.venv/bin/ansible-playbook"
INVENTORY="$REPO_ROOT/ansible/inventory/hosts.yml"
SHUTDOWN_PLAY="$REPO_ROOT/ansible/playbooks/_internal_shutdown.yml"
VC="sudo virt-customize"

wait_for_winrm() { local ip=$1; for _ in {1..60}; do echo > /dev/tcp/"$ip"/5985 2>/dev/null && return 0; sleep 2; done; return 1; }

shutdown_vm() {
  local dom=$1 host=$2 ip=$3
  if ! virsh domstate "$dom" 2>/dev/null | grep -q running; then
    echo "  $dom is off; starting to let NTFS auto-recover"; virsh start "$dom" >/dev/null
    wait_for_winrm "$ip" || true; sleep 5
  fi
  echo "  graceful shutdown $dom via ansible WinRM"
  "$ANSIBLE" -i "$INVENTORY" "$SHUTDOWN_PLAY" -e "target_hosts=$host" >/dev/null || true
  for _ in {1..60}; do virsh domstate "$dom" 2>/dev/null | grep -q running || { echo "  $dom off"; return; }; sleep 2; done
  echo "  WARN: $dom still up; destroy fallback" >&2; virsh destroy "$dom" >/dev/null; sleep 3
}
start_vm() { virsh domstate "$1" 2>/dev/null | grep -q running || { echo "  starting $1"; virsh start "$1" >/dev/null; }; }

bake_secrets_sql() {
  local marker="$STATE_DIR/secrets.alpha.done"
  if ! need_bake "$marker"; then echo "==> secrets.alpha marker present; skip"; return; fi
  echo "==> baking SQL Server media into secrets.alpha"
  shutdown_vm "$SECRETS_DOM" "$SECRETS_HOST" "$SECRETS_IP"
  $VC -a "$SECRETS_VOL" \
    --mkdir '/Windows/Setup/mssql' \
    --copy-in "$STAGING/SQLEXPR_x64_ENU.exe:/Windows/Setup/mssql" \
    --copy-in "$STAGING/sqlcmd.msi:/Windows/Setup/mssql" \
    --copy-in "$STAGING/msodbcsql.msi:/Windows/Setup/mssql"
  date -Iseconds > "$marker"
  start_vm "$SECRETS_DOM"
}

cd "$REPO_ROOT"
warm_dotnet_image
stage_sql_media
stream_dotnet_to_gitlab
bake_secrets_sql
echo "==> M8/M9 bake complete."
echo "    gitlab.alpha   docker image $DOTNET_OFFLINE (runner build image)"
echo "    secrets.alpha  C:\\Windows\\Setup\\mssql\\ (SQL Server media)"
echo "    Run 'make m8-m9' to promote alpha.local, seed the deploy project + VaultDb."
