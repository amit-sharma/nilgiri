#!/bin/bash
# PURGE-ONLY: remove every internal 'clean-eval' snapshot from each range
# qcow2. Delete by NAME (the tag), NOT by the qemu-img display-ID: libvirt
# internal snapshots have an empty id_str, so deleting by number fails; the
# loop clears duplicates one at a time.
#
# Run with ALL range VMs OFF (qemu-img needs an unlocked qcow2). The only
# privileged op is `qemu-img snapshot -d` (qcow2 is libvirt-qemu:kvm 0644).
# Prime sudo first so this script never prompts mid-loop:
#     sudo -v && bash scripts/rebake_clean_eval.sh
# After it finishes, create one fresh clean-eval per host via virsh and
# restart the range.
set -u
SNAP=clean-eval
PROJECT=nilgiri

count_snap() { qemu-img snapshot -l "$1" 2>/dev/null | awk -v t="$SNAP" '$2==t' | wc -l; }

fail=0
for vm in $(virsh list --all --name | grep "^${PROJECT}-"); do
    st=$(virsh domstate "$vm" 2>/dev/null)
    if [ "$st" != "shut off" ]; then
        printf '%-26s NOT OFF (%s) -- skipped\n' "$vm" "$st"; fail=1; continue
    fi
    disk=$(virsh domblklist "$vm" --details 2>/dev/null | awk '$2=="disk"{print $4; exit}')
    if [ -z "$disk" ]; then
        printf '%-26s no disk found -- skipped\n' "$vm"; fail=1; continue
    fi
    before=$(count_snap "$disk")
    n=0
    while [ "$(count_snap "$disk")" -gt 0 ]; do
        if ! sudo qemu-img snapshot -d "$SNAP" "$disk"; then
            printf '%-26s delete FAILED after %d\n' "$vm" "$n"; fail=1; break
        fi
        n=$((n+1))
        if [ "$n" -ge 10 ]; then printf '%-26s guard hit\n' "$vm"; fail=1; break; fi
    done
    # clear any stale virsh metadata so the later create is unambiguous
    virsh snapshot-delete --domain "$vm" --snapshotname "$SNAP" --metadata >/dev/null 2>&1 || true
    after=$(count_snap "$disk")
    printf '%-26s before=%s deleted=%s remaining=%s\n' "$vm" "$before" "$n" "$after"
    [ "$after" -ne 0 ] && fail=1
done
echo "PURGE DONE (fail=$fail) -- tell the assistant to create fresh snapshots"
exit $fail
