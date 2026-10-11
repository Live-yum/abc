#!/usr/bin/env python3
"""Bounded caller subprocess for unchanged scalar build provenance producer."""
import argparse
from pathlib import Path
import dependencies
from application_process import read_json
from memory_ownership_run import capture_build

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--folder', required=True, type=Path)
    parser.add_argument('--head', required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--native-proof', required=True, type=Path)
    args = parser.parse_args()
    capture_build(args.folder, args.head, args.source_sha, args.helper, read_json(args.native_proof))
