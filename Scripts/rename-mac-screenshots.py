#!/usr/bin/env python3
"""Rename exported xcresult attachments from UUIDs back to their test names.

`xcresulttool export attachments` names files by UUID; the manifest carries
the name the test gave each one.
"""
import json
import pathlib
import re
import sys

directory = pathlib.Path(sys.argv[1])
manifest = directory / "manifest.json"
if not manifest.exists():
    sys.exit(f"error: no manifest at {manifest}")

renamed = 0
for entry in json.loads(manifest.read_text()):
    for attachment in entry.get("attachments", []):
        source = directory / attachment["exportedFileName"]
        suggested = attachment.get("suggestedHumanReadableName", "")
        # "02-sound-detail_0_<uuid>.png" -> "02-sound-detail.png"
        name = re.sub(r"_\d+_[0-9A-F-]{36}(?=\.)", "", suggested, flags=re.I)
        if not name or not source.exists():
            continue
        source.rename(directory / name)
        renamed += 1

manifest.unlink()
print(f"renamed {renamed} screenshot(s) in {directory}")
