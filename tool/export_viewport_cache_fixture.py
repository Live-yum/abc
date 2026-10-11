#!/usr/bin/env python3
"""Materialize only original synthetic cache contracts, never public/user saves."""
import argparse
import hashlib
import json
from pathlib import Path
from test_viewport_cache import fixture

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=Path)
args = parser.parse_args()
args.directory.mkdir(parents=True, exist_ok=False)
records = {}
for name, alternate in (('original.wld', False), ('alternate.wld', True)):
    path = args.directory/name
    fixture(path, alternate)
    records[name] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'bytes': path.stat().st_size}
(args.directory/'manifest.json').write_text(json.dumps(records, indent=2)+'\n')
