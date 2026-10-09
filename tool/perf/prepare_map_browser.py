#!/usr/bin/env python3
"""Stage only public code and an interactive synthetic MAP benchmark page.

No browser is launched and no personal or derived fixture is copied or served.
Use an authorized browser workflow to open the staged page, then click Run.
"""
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[2]
destination = root / 'build' / 'map-benchmark'
files = {
    root / 'tool/perf/map_worker_browser.html': destination / 'index.html',
    root / 'web/terra_map.js': destination / 'terra_map.js',
    root / 'web/terra_map_worker.js': destination / 'terra_map_worker.js',
    root / 'web/engine/map_worker.js': destination / 'engine/map_worker.js',
}
for source, target in files.items():
    if not source.is_file():
        raise SystemExit('Build the MAP worker first: bash tool/build_map_worker.sh')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
print('Prepared public interactive MAP benchmark in build/map-benchmark; no browser launched.')
