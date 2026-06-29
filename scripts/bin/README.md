# scripts/bin

Vendored helper binaries used by smoke tests.

## PrintSpoofer.exe (REQUIRED for smoke_m6_credservice.sh)

Source: https://github.com/itm4n/PrintSpoofer (license: BSD-3-Clause).

Build (one-time):
```
git clone https://github.com/itm4n/PrintSpoofer
cd PrintSpoofer
# Open in Visual Studio / build with msbuild. Or grab a pre-built release
# from the Releases page.
```

Drop the resulting `PrintSpoofer64.exe` here as `PrintSpoofer.exe`.

The smoke uses it for M6.s2 -- abuses `SeImpersonatePrivilege` (held by
local Administrators) to steal a SYSTEM token via a Spooler RPC named-pipe
trick. This is the **only** SYSTEM-context path m6.s2 allows; SCM-based
PtH-to-SYSTEM (impacket-psexec/smbexec/atexec) is explicitly blocked on
web.oscar by SDDL hardening, and the smoke's three NEGATIVE tests prove
that blocking is in place.

Alternative tools that work identically against the same gate:
- GodPotato (https://github.com/BeichenDream/GodPotato) -- works on
  modern Windows where PrintSpoofer is patched
- JuicyPotatoNG (https://github.com/antonioCoco/JuicyPotatoNG)
- RoguePotato (https://github.com/antonioCoco/RoguePotato)

Pass `--printspoofer /path/to/your/binary` to use a different tool.

## hash pinning

verify_hardening.yml does NOT pin these binaries' hashes (they are
attacker tooling, expected to vary by build). The smoke validates the
outcome (m6.s2 UUID matches manifest) which is the security-relevant
check.
