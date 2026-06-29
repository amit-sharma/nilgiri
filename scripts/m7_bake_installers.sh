#!/usr/bin/env bash
# m7_bake_installers.sh -- stage everything M7 needs that requires host tooling
# or internet egress, before the alpha/oscar segments are isolated.
#
#   PHASE A (offline, host-side, marker-gated) -- build the deploy-scripts git
#     repo (M7.s3 secret committed then deleted in history) on the host and
#     virt-customize it into ws.alpha's COW volume at C:\dev\deploy-scripts.
#
#   PHASE B (live, needs egress) -- the Linux Docker hosts (c2.oscar,
#     gitlab.alpha, teamcity.alpha) pull heavy images/packages over SSH against
#     the LIVE VMs; REQUIRES temporary egress on the oscar + alpha segments. The
#     script verifies egress and bails with instructions if absent.
#
# Idempotent via per-host markers under STATE_DIR. Pass --force to redo.
#
# KEEP IN SYNC: the GitLab PAT planted in git history below must match
# ansible/roles/{alpha_pivot_host,gitlab_cicd}/defaults/main.yml.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING="/mnt/vm-storage/cyber-range/staging/m7"
STATE_DIR="$STAGING/.state"
PY="$REPO_ROOT/.venv/bin/python"

# --- shared constants (sync with role defaults) ---------------------------
GITLAB_PAT="glpat-nilgiri7s3deploytok"
MYTHIC_REF="v3.3.1"                       # pin Mythic
GITLAB_IMAGE="gitlab/gitlab-ce:17.8.1-ce.0"

# ws.alpha (Windows) bake target.
WS_VOL="/mnt/vm-storage/nilgiri-ws.alpha.qcow2"
WS_DOM="nilgiri-ws.alpha"
WS_IP="10.40.0.100"
WS_HOST="ws.alpha"

# Linux Docker hosts: "host:ip" pairs.
LINUX_HOSTS=( "c2.oscar:10.30.0.30" "gitlab.alpha:10.40.0.20" "teamcity.alpha:10.40.0.21" )

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  "") ;;
  *) echo "usage: $0 [--force]" >&2; exit 2 ;;
esac

mkdir -p "$STAGING" "$STATE_DIR"

[[ -x "$PY" ]] || { echo "ERROR: project venv missing -- run 'make venv'" >&2; exit 1; }

# Reads flags/manifest.yaml relative to cwd (callers cd "$REPO_ROOT" first).
m7s3_uuid() { "$PY" - <<'EOF'
import yaml
d = yaml.safe_load(open("flags/manifest.yaml"))
print(next(f["uuid"] for f in d["flags"] if f["id"] == "m7.s3"))
EOF
}

############################################################################
# PHASE A -- build deploy-scripts repo + bake into ws.alpha (offline)
############################################################################
phase_a() {
  local marker="$STATE_DIR/ws.alpha.done"
  if [[ -f "$marker" && $FORCE -eq 0 ]]; then
    echo "==> ws.alpha marker present; skip repo bake (--force to redo)"
    return 0
  fi

  command -v git >/dev/null || { echo "ERROR: git not on PATH (host)"; exit 1; }
  local M7S3; M7S3="$(cd "$REPO_ROOT" && m7s3_uuid)"
  echo "==> building deploy-scripts repo (m7.s3=$M7S3)"

  local repo="$STAGING/deploy-scripts"
  rm -rf "$repo"; mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git config user.email "svc_deploy@alpha.local"
    git config user.name "svc_deploy"
    cat > deploy.sh <<'SH'
#!/usr/bin/env bash
# infra deploy helper. Secrets now live in GitLab CI variables (see README).
set -euo pipefail
echo "deploying $(git rev-parse --short HEAD) to alpha fleet"
SH
    printf '# infra/pipelines deploy scripts\nSecrets moved to GitLab CI variables.\n' > README.md
    # The secret-bearing file -- committed, then removed in a later commit.
    cat > deploy.env <<ENV
# deploy.env -- local secrets (DO NOT COMMIT). Oops, committed anyway.
GITLAB_PAT=$GITLAB_PAT
DEPLOY_FLAG=$M7S3
ENV
    git add -A && git commit -q -m "initial deploy scripts + local env"
    git rm -q deploy.env
    git commit -q -m "chore: remove committed secrets, move to CI variables"
  )
  echo "  repo built: $(cd "$repo" && git rev-list --count HEAD) commits; HEAD has no deploy.env"

  # Package the repo as a zip for the alpha_pivot_host role to deliver over
  # WinRM (win_copy + win_unzip) against the live ws.alpha (no virt-customize).
  local zip="$STAGING/deploy-scripts.zip"
  rm -f "$zip"
  ( cd "$STAGING" && zip -q -r "$zip" deploy-scripts )
  echo "==> packaged repo -> $zip ($(stat -c %s "$zip") bytes)"
  date -Iseconds > "$marker"
  echo "  done: alpha_pivot_host will win_copy + unzip this to C:\\dev\\deploy-scripts"
}

############################################################################
# PHASE B -- stage Docker assets on the (egress-capable) HOST, then transfer
# them to the no-egress guests via `docker save | ssh ... docker load`.
#
# Containment model (load-bearing): the libvirt HOST has internet; the alpha +
# oscar guest segments do NOT. Everything heavy is pulled/built on the host and
# streamed into the guests over the bridge; the guests never touch the internet.
#   - Docker engine: baked into the kali base image.
#   - /opt/Mythic: built once on the host (stage_mythic_on_host), streamed to c2.oscar.
#   - all container IMAGES: pulled on the host, streamed to the guests.
# (ensure_docker_on_guest falls back to a one-time guest-egress install if a
# guest's kali base predates the docker.io change.)
############################################################################
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
# Default to the post-rotation kali password (c2.oscar/gitlab.alpha/teamcity.alpha
# had kali:kali rotated to close the m7.s5 Rails-console shortcut). Override via
# KALI_SSH_PASS for hosts still at the base default.
KALI_SSH_PASS="${KALI_SSH_PASS:-08d3ec40a4e0772c1af26c80}"
rcmd() { local ip=$1; shift; sshpass -p "$KALI_SSH_PASS" ssh "${SSH_OPTS[@]}" kali@"$ip" "$@"; }

GITLAB_RUNNER_IMAGE="gitlab/gitlab-runner:v17.10.0"
# helper image revision tracks the runner version (`gitlab-runner --version`).
GITLAB_HELPER_IMAGE="gitlab/gitlab-runner-helper:x86_64-67b2b2db"

# Stream a set of host images into a guest (load-only; guest needs no egress).
# Pulls the image on the host first if it isn't cached.
xfer_images() {
  local ip=$1; shift
  for img in "$@"; do
    docker image inspect "$img" >/dev/null 2>&1 || { echo "  host pull $img"; docker pull "$img"; }
  done
  echo "  streaming $# image(s) -> $ip"
  docker save "$@" | rcmd "$ip" 'cat > /var/tmp/m7-images.tar'
  rcmd "$ip" 'sudo docker load -i /var/tmp/m7-images.tar && rm -f /var/tmp/m7-images.tar' | tail -3
}

ensure_docker_on_guest() {  # one-time; needs guest egress if Docker absent
  local ip=$1
  if rcmd "$ip" 'command -v docker >/dev/null 2>&1'; then return 0; fi
  echo "  Docker absent on $ip -- installing (NEEDS TEMP EGRESS on this segment)"
  rcmd "$ip" 'curl -fsSL https://get.docker.com | sudo sh && sudo systemctl enable --now docker' \
    || { echo "ERROR: Docker install on $ip failed (no egress?). NAT the segment once or bake Docker into the kali base." >&2; exit 1; }
}

# Build the /opt/Mythic checkout (repo + mythic-cli + poseidon/http profile
# source) ON THE HOST (which has egress + Docker), tar it once, reuse forever.
# This keeps c2.oscar fully no-egress: it receives /opt/Mythic + the images by
# stream, never touching the internet.
stage_mythic_on_host() {
  MYTHIC_TARBALL="$STAGING/opt-mythic.tar.gz"
  [[ -f "$MYTHIC_TARBALL" && $FORCE -eq 0 ]] && return 0
  local stage="$STAGING/opt/Mythic"
  echo "==> [host] staging /opt/Mythic (clone + build mythic-cli + install profiles)"
  command -v git >/dev/null || { echo "ERROR: git missing on host"; exit 1; }
  [[ -x "$stage/mythic-cli" ]] || {
    rm -rf "$stage"; mkdir -p "$(dirname "$stage")"
    git clone --depth 1 -b "$MYTHIC_REF" https://github.com/its-a-feature/Mythic "$stage"
    ( cd "$stage" && make \
        && ./mythic-cli install github https://github.com/MythicAgents/poseidon \
        && ./mythic-cli install github https://github.com/MythicC2Profiles/http )
  }
  # Tar so it extracts to /opt/Mythic on the guest (paths are opt/Mythic/...).
  tar -czf "$MYTHIC_TARBALL" -C "$STAGING" opt/Mythic
  echo "  staged $MYTHIC_TARBALL ($(stat -c %s "$MYTHIC_TARBALL") bytes)"
}

phase_b_c2() { local ip=$1
  ensure_docker_on_guest "$ip"          # satisfied by the kali base (docker.io)
  stage_mythic_on_host
  # Stream /opt/Mythic in if the guest doesn't already have it (no guest egress).
  if ! rcmd "$ip" 'test -x /opt/Mythic/mythic-cli'; then
    echo "==> [c2.oscar] streaming /opt/Mythic from host staging"
    cat "$MYTHIC_TARBALL" | rcmd "$ip" 'sudo tar -xzf - -C /'
  fi
  # Stream the Mythic container images from the host cache (the no-egress win).
  # Tags are read from c2's compose so they always match the checked-out version.
  local imgs
  imgs=$(rcmd "$ip" "grep -hoE 'image: .*' /opt/Mythic/docker-compose.yml | awk '{print \$2}' | sort -u")
  echo "==> [c2.oscar] streaming Mythic images from host cache"
  # shellcheck disable=SC2086
  xfer_images "$ip" $imgs
}

phase_b_gitlab() { local ip=$1
  ensure_docker_on_guest "$ip"
  echo "==> [gitlab.alpha] streaming gitlab-ce + runner + helper images from host"
  xfer_images "$ip" "$GITLAB_IMAGE" "$GITLAB_RUNNER_IMAGE" "$GITLAB_HELPER_IMAGE"
}

phase_b_teamcity() { local ip=$1
  # teamcity.alpha only runs the python TeamCity stub (kali ships python3) --
  # no Docker, no images, no egress needed.
  echo "==> [teamcity.alpha] python3 present? (TeamCity stub host)"
  rcmd "$ip" 'command -v python3 >/dev/null || { echo MISSING_PYTHON3; exit 1; }'
}

phase_b() {
  command -v sshpass >/dev/null || { echo "ERROR: sshpass not installed (apt-get install sshpass)"; exit 1; }
  command -v docker  >/dev/null || { echo "ERROR: docker not on the host (needed to pull+stream images)"; exit 1; }
  for pair in "${LINUX_HOSTS[@]}"; do
    local host="${pair%%:*}" ip="${pair##*:}"
    local marker="$STATE_DIR/${host}.done"
    if [[ -f "$marker" && $FORCE -eq 0 ]]; then
      echo "==> $host marker present; skip (--force to redo)"; continue
    fi
    case "$host" in
      c2.oscar)       phase_b_c2 "$ip" ;;
      gitlab.alpha)   phase_b_gitlab "$ip" ;;
      teamcity.alpha) phase_b_teamcity "$ip" ;;
    esac
    date -Iseconds > "$marker"
    echo "  $host done"
  done
}

cd "$REPO_ROOT"
phase_a
phase_b
echo "==> M7 bake complete (images streamed from host; guests stayed isolated)."
echo "    Run 'make m7' to provision Mythic + ws.alpha + GitLab + runner."
