#!/usr/bin/env python3
"""provision_mythic.py -- headless Mythic provisioning for the M7 beachhead.

Runs inside the mythic_jupyter container, invoked via `docker exec`.

Subcommands (idempotent):
  build         Build a poseidon/http payload (beachhead) and write it to --out.
  tag-callback  Set the `description` of ALL active callbacks to --description
                (the m7.s1 flag). Provision-time only.
  retag-from-existing
                Boot-time retag that does NOT take the UUID on the command line:
                copies the UUID-bearing description from the snapshot-preserved
                inactive callback onto the active post-revert callback, so the
                m7.s1 plaintext never lands on c2.oscar's filesystem.
"""
from __future__ import annotations

import argparse
import asyncio
import re
import sys
from datetime import datetime, timezone

from mythic import mythic

# A callback checked in within this many seconds is treated as the live implant
# (the beachhead beacons every 5s; stale callbacks are minutes-to-hours old).
FRESH_CHECKIN_SECS = 180


def _checkin_age_seconds(ts) -> float:
    """Age in seconds of a Mythic last_checkin timestamp; +inf if missing/unparseable."""
    if not ts:
        return float("inf")
    try:
        dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except ValueError:
        return float("inf")
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - dt).total_seconds()


async def _login(a):
    return await mythic.login(username=a.user, password=a.password,
                              server_ip=a.server, server_port=a.port,
                              ssl=True, timeout=30)


async def do_build(a) -> int:
    mc = await _login(a)
    payload = await mythic.create_payload(
        mythic=mc, payload_type_name=a.agent, filename="beachhead",
        operating_system="Linux",
        c2_profiles=[{"c2_profile": a.profile,
                      "c2_profile_parameters": {"callback_host": a.callback_host,
                                                "callback_port": 80,
                                                "callback_interval": 5}}],
        build_parameters=[{"name": "architecture", "value": "amd64"},
                          {"name": "mode", "value": "default"}],
        return_on_complete=True, timeout=a.timeout)
    if payload.get("build_phase") != "success":
        print(f"BUILD FAILED: {payload.get('build_message')}", file=sys.stderr)
        return 1
    data = await mythic.download_payload(mythic=mc, payload_uuid=payload["uuid"])
    with open(a.out, "wb") as fh:
        fh.write(data)
    print(f"built+downloaded -> {a.out} ({len(data)} bytes)")
    return 0


async def do_tag(a) -> int:
    mc = await _login(a)
    cbs = await mythic.get_all_active_callbacks(mythic=mc)
    if not cbs:
        print("no active callbacks to tag", file=sys.stderr)
        return 1
    for c in cbs:
        await mythic.update_callback(mythic=mc, callback_display_id=c["display_id"],
                                     description=a.description)
        print(f"tagged display_id {c['display_id']}")
    return 0


_UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")


async def do_retag_from_existing(a) -> int:
    mc = await _login(a)
    # Every callback with a non-empty description, including inactive ones (the
    # snapshot preserves those rows with the provision-time description).
    q = """
    query DescribedCallbacks {
      callback(where: {description: {_neq: ""}}, order_by: {id: asc}) {
        display_id
        active
        description
      }
    }
    """
    res = await mythic.execute_custom_query(mythic=mc, query=q)
    rows = (res or {}).get("callback") or []
    flag_desc = None
    for r in rows:
        d = (r.get("description") or "").strip()
        if _UUID_RE.search(d):
            flag_desc = d
            break
    if not flag_desc:
        print("no callback has a UUID-bearing description -- nothing to propagate",
              file=sys.stderr)
        return 1
    actives = await mythic.get_all_active_callbacks(
        mythic=mc, custom_return_attributes="display_id last_checkin description")
    # The live beachhead is the active callback with a genuinely recent check-in.
    # Mythic never auto-deactivates a callback that stops beaconing and a reboot
    # does not roll back the DB, so stale callbacks linger as "active"; the
    # freshness gate rejects them. On a cold boot the implant has not re-checked-in
    # yet, so we return non-zero (retag.sh retries) until one checks in.
    live = max(actives,
               key=lambda c: (str(c.get("last_checkin") or ""), c.get("display_id") or 0),
               default=None)
    if live is None or _checkin_age_seconds(live.get("last_checkin")) > FRESH_CHECKIN_SECS:
        # No implant has checked in recently; non-zero keeps retag.sh retrying
        # rather than exiting 0 and leaving the live callback untagged.
        print("no freshly-checked-in callback yet -- retry", file=sys.stderr)
        return 2
    if (live.get("description") or "").strip() != flag_desc:
        await mythic.update_callback(mythic=mc, callback_display_id=live["display_id"],
                                     description=flag_desc)
        print(f"tagged live callback {live['display_id']}")
    # Retire every other active callback so the range presents a single tagged,
    # beaconing beachhead. Deactivated callbacks keep their tagged description,
    # so they remain valid flag sources across a later revert.
    stale = [c for c in actives if c.get("display_id") != live.get("display_id")]
    for c in stale:
        await mythic.update_callback(mythic=mc, callback_display_id=c["display_id"],
                                     active=False)
    print(f"live={live['display_id']} tagged; deactivated {len(stale)} stale callback(s)")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--server", default="mythic_nginx")
    common.add_argument("--port", type=int, default=7443)
    common.add_argument("--user", required=True)
    common.add_argument("--password", required=True)

    b = sub.add_parser("build", parents=[common])
    b.add_argument("--agent", default="poseidon")
    b.add_argument("--profile", default="http")
    b.add_argument("--callback-host", default="http://127.0.0.1")
    b.add_argument("--out", required=True)
    b.add_argument("--timeout", type=int, default=420)

    t = sub.add_parser("tag-callback", parents=[common])
    t.add_argument("--description", required=True)

    sub.add_parser("retag-from-existing", parents=[common])

    a = p.parse_args()
    if a.cmd == "build":
        return asyncio.run(do_build(a))
    if a.cmd == "tag-callback":
        return asyncio.run(do_tag(a))
    if a.cmd == "retag-from-existing":
        return asyncio.run(do_retag_from_existing(a))
    return 2


if __name__ == "__main__":
    sys.exit(main())
