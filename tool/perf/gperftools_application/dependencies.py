"""Explicit repository/authoring layouts; no untrusted module discovery."""
import hashlib
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
AUTHOR = ROOT.parent
CONTRACTS = ROOT / 'tool/perf/gperftools_application_contracts'
PREFLIGHT = ROOT / 'tool/perf/gperftools_preflight'
ORIGINAL = ROOT / 'tool/perf'
if not CONTRACTS.is_dir():
    CONTRACTS = AUTHOR / 'gperftools-application-contracts'
    PREFLIGHT = AUTHOR / 'gperftools-preflight-index'
    ORIGINAL = AUTHOR / 'publication-review-protocol-format-v5/snapshot/tool/perf'
for directory in (ORIGINAL, PREFLIGHT, CONTRACTS):
    if not directory.is_dir():
        raise RuntimeError('Required reviewed dependency layout absent')
    sys.path.insert(0, str(directory))
PINS = {
    'run_preflight.py': '89ef2a1f8cdafa0afe1c67d547e2c3e28703113e197347633e561d6dac9b1ea8',
    'source-manifest.json': 'c7d7f13a006503459a5738df090c3ba3f61f5afc5507e826939958ca515f1f51',
    'profile_contract.py': '07cee15d0c0c3f6d3be56b60f2339fd419def81d3fcaea4236660468a9f25d79',
    'pprof_raw.py': '3bc28fc584db560c865f7f7aa8e3acc72debfe6e40257e8b861367e320093646',
}
for name, expected in PINS.items():
    if hashlib.sha256((PREFLIGHT / name).read_bytes()).hexdigest() != expected:
        raise RuntimeError('Official package/parser dependency changed: ' + name)
if hashlib.sha256((CONTRACTS / 'application_contract.py').read_bytes()).hexdigest() != '4cbfff240cfd5073f347af52aa3bb1c87cd1669b5a3375f14e44623a2504d1bf':
    raise RuntimeError('ACK-v2/in-place ELF application contract dependency changed')
