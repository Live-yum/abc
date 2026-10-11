#!/usr/bin/env python3
"""Run the unchanged official package/source gate only, without a capture."""
import argparse
import os
from pathlib import Path
import dependencies
from application_contract import require
from run_preflight import Runner, package_gate, validate_source_manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deb-dir', type=Path, required=True)
    parser.add_argument('--apt-download-log', type=Path, required=True)
    args = parser.parse_args()
    require(os.environ.get('GITHUB_ACTIONS') == 'true', 'Actual official package gate is CI only')
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    runner = Runner(args.output.resolve())
    try:
        runner.manifest['sourceManifestSha256'] = validate_source_manifest()
        package_gate(runner, args.deb_dir.resolve(), args.apt_download_log.resolve())
        runner.manifest['status'] = 'official-package-identity-only'
        runner.manifest['contractPassed'] = False
        runner.manifest['applicationCapturePerformed'] = False
        runner.persist()
    except BaseException as error:
        runner.manifest['status'] = 'failed'
        runner.manifest['error'] = str(error)
        runner.persist()
        raise


if __name__ == '__main__':
    main()
