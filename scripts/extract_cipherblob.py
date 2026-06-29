#!/usr/bin/env python3
"""Locate + emit the AES-GCM CipherBlob constant embedded in a published
CredService.exe (single-file win-x64 dotnet publish output).

CipherBlob layout: nonce(12) || ct(36) || tag(16) = 64 bytes (m6.s3 UUID is
36 chars). The script is invoked without the key, so it emits the top-k
highest-entropy 64-byte windows to stdout for the consumer to trial-decrypt.

Usage:
    python3 extract_cipherblob.py path/to/CredService.exe [--length 64]
"""
import argparse
import math
import sys
from pathlib import Path


def shannon_entropy(b: bytes) -> float:
    if not b:
        return 0.0
    freq = [0] * 256
    for x in b:
        freq[x] += 1
    n = len(b)
    h = 0.0
    for c in freq:
        if c == 0:
            continue
        p = c / n
        h -= p * math.log2(p)
    return h


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("binary", help="path to CredService.exe")
    ap.add_argument("--length", type=int, default=64,
                    help="cipherblob length in bytes (default 64 = 12 nonce + 36 ct + 16 tag)")
    ap.add_argument("--top-k", type=int, default=5,
                    help="emit the top-k highest-entropy windows (the consumer "
                    "tries each in turn). Default 5.")
    args = ap.parse_args()

    data = Path(args.binary).read_bytes()
    L = args.length
    if len(data) < L:
        print(f"binary too small ({len(data)} bytes; need >= {L})", file=sys.stderr)
        sys.exit(2)

    # Stride 4: dotnet aligns byte[] literals to 4-byte boundaries.
    stride = 4
    candidates: list[tuple[float, int]] = []
    for i in range(0, len(data) - L + 1, stride):
        w = data[i : i + L]
        h = shannon_entropy(w)
        # Skip all-printable-ASCII and zero-heavy windows (never the cipherblob).
        if all(32 <= b < 127 for b in w):
            continue
        if w.count(0) > L // 2:
            continue
        candidates.append((h, i))

    candidates.sort(reverse=True)
    # Emit the top-k highest-entropy windows back-to-back for the consumer to try.
    out = bytearray()
    for _, off in candidates[: args.top_k]:
        out.extend(data[off : off + L])
    sys.stdout.buffer.write(bytes(out))


if __name__ == "__main__":
    main()
