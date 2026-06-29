#!/usr/bin/env bash
# kali_tun0_up.sh -- bring up / repair the corp OpenVPN tunnel on the kali
# sandbox. Idempotent: tests the LOWER_UP carrier flag (a dead tunnel leaves a
# stale tun0 with its IP still assigned, so mere existence is NOT "up"). If the
# carrier is down, kills stale openvpn, re-fetches corp.ovpn, and restarts.
#
# Env: KALI_SUDO_PASS (default "kali") -- fed to sudo -S for openvpn.
set -u

SUDO_PASS="${KALI_SUDO_PASS:-kali}"
OVPN="/tmp/corp.ovpn"
PORTAL_URL="http://10.10.0.10/corp.ovpn"

carrier_up() { ip link show tun0 2>/dev/null | grep -qw LOWER_UP; }

if carrier_up; then
    echo "  tun0 up (carrier present)"
    ip -4 -o addr show tun0
    exit 0
fi

echo "  tun0 down/stale -- (re)starting OpenVPN..."
# Blanket-kill openvpn (the only one on the kali sandbox is this corp tunnel)
# to stop stale daemons fighting over tun0.
echo "$SUDO_PASS" | sudo -S -p '' pkill -x openvpn 2>/dev/null || true
sleep 2

# Tear down any stale tun0 + orphaned routes: OpenVPN 2.7's DCO driver can leave
# a wedged tun0 device behind that makes the next start fail fatally. We start
# with --disable-dco below to avoid the DCO path entirely.
echo "$SUDO_PASS" | sudo -S -p '' ip link delete tun0 2>/dev/null || true
echo "$SUDO_PASS" | sudo -S -p '' ip route del 10.20.0.0/24 2>/dev/null || true
echo "$SUDO_PASS" | sudo -S -p '' ip route del 10.30.0.0/24 2>/dev/null || true

if ! curl -sS -u admin:admin "$PORTAL_URL" -o "$OVPN"; then
    echo "  ERROR: could not fetch corp.ovpn from the VPN portal ($PORTAL_URL) -- is 10.10.0.10 up?"
    exit 1
fi

# --disable-dco: use the classic tun driver (DCO is unreliable across restarts).
echo "$SUDO_PASS" | sudo -S -p '' openvpn --config "$OVPN" --disable-dco --daemon --log /tmp/openvpn.log

for _ in $(seq 1 20); do
    carrier_up && break
    sleep 1
done

if carrier_up; then
    echo "  tun0 up"
    ip -4 -o addr show tun0
else
    echo "  ERROR: tun0 still down after restart -- check /tmp/openvpn.log on kali"
    echo "         (VPN portal 10.10.0.10 reachable? range networking healthy?)"
    exit 1
fi
