#!/usr/bin/env python3
from pathlib import Path
import argparse, plistlib

def valid_bundle_id(s):
    parts = s.split(".")
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    return len(parts) >= 2 and all(p and set(p) <= allowed for p in parts)

ap = argparse.ArgumentParser()
ap.add_argument("icons")
ap.add_argument("-o", "--output", default="Theme.plist")
args = ap.parse_args()

theme = {}
for p in sorted(Path(args.icons).glob("*.png")):
    if not valid_bundle_id(p.stem):
        continue
    data = p.read_bytes()
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) <= 2_000_000:
        theme[p.stem] = data

with open(args.output, "wb") as f:
    plistlib.dump(theme, f, fmt=plistlib.FMT_BINARY)

print(f"packed {len(theme)} icons -> {args.output}")
