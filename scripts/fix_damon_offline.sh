#!/bin/bash
# Offline DAMON-off fix + baseline-snapshot re-bake for the kali-clone Linux VMs.
#
# The Kali 6.18 kernel auto-starts a DAMON kdamond that soft-locks a CPU; the
# guest stops petting the qemu watchdog and the VM HARD-RESETS mid-eval. Every
# VM built from the kali base image is affected. Fix: kernel cmdline
# damon_stat.enabled=0 (the only off switch for a built-in =y).
#
# This injects that cmdline into BOTH baseline snapshots (clean-eval and
# clean-eval-easy) of every clone, offline via virt-customize.
#
# Per VM, per snapshot:
#   qemu-img snapshot -a <snap>            # active layer := snapshot content
#   (diagnostic) report if the fix was already present
#   virt-customize: grub.d drop-in + update-grub
#   qemu-img snapshot -d <snap>            # drop the old internal snapshot
#   virsh snapshot-delete --metadata       # clear stale libvirt metadata
#   virsh snapshot-create-as               # re-bake from the fixed active layer
#
# Requires the target VMs OFF (the script shuts them down, destroying wedged
# ones). Privileged ops: qemu-img + virt-customize on the root-owned qcow2.
# Prime sudo first so it never prompts mid-loop:
#     sudo -v && bash scripts/fix_damon_offline.sh [VM ...]
#
# With no args it processes all five clones. Pass a subset to validate on one
# first, e.g.:  sudo -v && bash scripts/fix_damon_offline.sh nilgiri-kali

set -u

DEFAULT_VMS="nilgiri-kali nilgiri-vpn-portal nilgiri-c2.oscar nilgiri-gitlab.alpha nilgiri-teamcity.alpha"
VMS="${*:-$DEFAULT_VMS}"
# clean-eval applied LAST so the running default lands on the hard baseline.
SNAPS="clean-eval-easy clean-eval"
DESC="nilgiri range baseline"
DROPIN='mkdir -p /etc/default/grub.d && printf '\''GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX damon_stat.enabled=0"\n'\'' > /etc/default/grub.d/99-disable-damon.cfg && update-grub'

disk_of() { virsh domblklist "$1" --details 2>/dev/null | awk '$2=="disk"{print $4; exit}'; }
has_snap() { qemu-img snapshot -l "$1" 2>/dev/null | awk -v t="$2" '$2==t{f=1} END{exit !f}'; }

echo ">> targets: $VMS"

# ---------------------------------------------------------------- 1. power off
for vm in $VMS; do
    st=$(virsh domstate "$vm" 2>/dev/null || echo missing)
    [ "$st" = "running" ] && virsh shutdown "$vm" >/dev/null 2>&1
done
echo ">> waiting for graceful shutdown (max 60s)..."
for _ in $(seq 1 20); do
    pending=0
    for vm in $VMS; do [ "$(virsh domstate "$vm" 2>/dev/null)" != "shut off" ] && pending=1; done
    [ "$pending" = 0 ] && break
    sleep 3
done
for vm in $VMS; do
    if [ "$(virsh domstate "$vm" 2>/dev/null)" != "shut off" ]; then
        echo "   $vm wedged -- destroying"
        virsh destroy "$vm" >/dev/null 2>&1
    fi
done

# ----------------------------------------------- 2. per VM / per snapshot fix
fail=0
for vm in $VMS; do
    disk=$(disk_of "$vm")
    if [ -z "$disk" ] || [ ! -e "$disk" ]; then
        echo "!! $vm: no disk found -- skipped"; fail=1; continue
    fi
    for snap in $SNAPS; do
        if ! has_snap "$disk" "$snap"; then
            echo "-- $vm / $snap: absent -- skipped"; continue
        fi
        echo "== $vm / $snap =="
        sudo qemu-img snapshot -a "$snap" "$disk" || { echo "   apply FAILED"; fail=1; continue; }
        had=$(sudo virt-cat -a "$disk" /boot/grub/grub.cfg 2>/dev/null | grep -c 'damon_stat.enabled=0')
        echo "   pre-fix: grub.cfg already had the flag on ${had:-0} line(s)"
        if ! sudo virt-customize -a "$disk" --no-network --run-command "$DROPIN" >/dev/null 2>&1; then
            echo "   virt-customize FAILED"; fail=1; continue
        fi
        now=$(sudo virt-cat -a "$disk" /boot/grub/grub.cfg 2>/dev/null | grep -c 'damon_stat.enabled=0')
        if [ "${now:-0}" -lt 1 ]; then
            echo "   POST-FIX VERIFY FAILED: flag not in grub.cfg -- not re-baking"; fail=1; continue
        fi
        sudo qemu-img snapshot -d "$snap" "$disk" || { echo "   snapshot delete FAILED"; fail=1; continue; }
        virsh snapshot-delete --domain "$vm" --snapshotname "$snap" --metadata >/dev/null 2>&1 || true
        virsh snapshot-create-as --domain "$vm" --name "$snap" --description "$DESC" --atomic >/dev/null 2>&1 \
            || { echo "   snapshot re-bake FAILED"; fail=1; continue; }
        echo "   fixed + re-baked (grub.cfg flag on $now line(s))"
    done
done

# --------------------------------------------------------------- 3. power on
echo ">> starting clones..."
for vm in $VMS; do virsh start "$vm" >/dev/null 2>&1 || true; done

echo ">> DONE (fail=$fail)"
exit $fail
