"""Immutable inputs for the four-suite a5612b4/cddd936 causal diagnostic.

This is deliberately independent of ordinary current-head performance CI.
The original comparator and all old anomalies remain authoritative evidence.
"""

PINS = {
    "baseline": {"commit": "a5612b474fc8dc50d41b3bc6b87234d30ba97e02",
                 "tree": "19afe39726b5ee724af413c2546c4389c5d0c205"},
    "candidate": {"commit": "cddd936f95d31b14a76503e13ffc89173110a057",
                  "tree": "ff5236bcfa02b8fcb3f361e9437c59c5bacc60fd"},
}
SUITES = {"native": 1500, "wasm": 1500,
          "map-generation": 600, "map-dart2js": 900}
SEQUENCE = ("baseline", "candidate", "candidate", "baseline", "baseline", "candidate")
OUT_OF_SCOPE = ("cloud", "resources", "map-aot", "map-owner", "ui-profile")
COMMON_HARNESS = {'.flutter-version': 'af7ad6b385523c1c98977a15b50c53b1fd4f35b1c5d85513600a03ba3284f6b1',
 '.github/actions/setup-flutter/action.yml': 'c385d4a7395973ba7ec4aa537d1f941ef2313bec5ea71bbebbdd619893827380',
 '.github/actions/setup-performance/action.yml': '78d89a03661620e07ad61ea5c8d381c131a9ab9930f9a6cca3ed527fef35150f',
 'integration_test/support/profile_memory_native.dart': '8a405c0a7f1bcff0939e822300bba689551a2dd8a9865820ac57665387a4bf10',
 'package-lock.json': '1813ccd7059d6d4fc0281e1925fbc38ca44a8ae5e2b7180ac0c1f43ada8b07b5',
 'pubspec.lock': '9cd23f6f2914d3420f3419a759af3f754e5173481aa029c8e519c5354d411135',
 'test/achievements_test.dart': '83594d1763a8be775ff49bf4023847da0dd85adddf3a91fd732345d81208d43d',
 'test/performance/measurements.dart': 'b4e78a04d512ab98c7fcc64f19ad6ac3488d78b9964429fecdfc70cba0eb678c',
 'test/performance/native_actions_test.dart': '1dd6aa4945052eee5d9d85a09f08e5dd0ed8b19e97dfaad4dd9e8d52f1b7c5cb',
 'test/performance/native_counters.dart': '16c294ef0d53f9deb0c5172d9fca81cc510b7258917c5756daa941343aaab41c',
 'test/resource_store_test.dart': '229b0ea8f1b830ee5de7beb6f8e926940f0584f318eb4ed19d3e7ff6d6abed9c',
 'tool/build_map_worker.sh': '8658398af94a5962887c00e93234e1bdac522414142dfff5eef1dc326434e4d6',
 'tool/perf/benchmark_wasm.mjs': 'be4c99a63cbb3e1a17c16fce297cfc8ab06d80ebe5d443bb61e454bb664472ab',
 'tool/perf/compare.py': '91f4073d6701a84ac1a880a5a77131b36c0ad0135620a7da977c914509985be8',
 'tool/perf/generate_native_map.py': '6103d4fa294e6a215d00a8a71174db53a28042055e58b11e5a566a4293fa14bd',
 'tool/perf/generate_synthetic_world.py': '19ab1b7501e9fd36a1334ca012f0c3b4098942618a6db5d98326ba426fd3a04b',
 'tool/perf/map_actions_web.dart': 'ecacb63355b538b63529e50d0177d45a4dd9e895e0030b6613ca21ee9aa40aa6',
 'tool/perf/map_fixture.dart': 'b432203595dd3f7adf960922e17bfee54476a5073422d0e5fd101fbc6851af84',
 'tool/perf/map_perf_core.dart': '5f26211531a5d0cbd57a5532dbf4b12e8cc14224f47f599f9b42ab07981e6c6f',
 'tool/perf/map_report_metadata.cjs': '23e1a1192663cd982a8c8a3c8d073ff84d2dd7f5121a7a117e3c94537aa2080c',
 'tool/perf/metrics.mjs': 'b1b89a3c9e83a327f16c10d0a66065a1c16a5b498851262dafc643f7a2e4b6e8',
 'tool/perf/run_ci_suite.py': '33258516eb3a1c207a8dcd1ba6867ab611e992d52cffa33dab103c5514768315',
 'tool/perf/run_map_web.cjs': '973c895b81120404c9d21bbb30d2936d8298772ce69a8e1a044edfe6451643ad',
 'tool/perf/write_map_fixture.dart': '16880c921b5312e5fcb06fcb87551c9fc6bc6e42c896b70b5ef6dd31bbd66fa0'}
FROZEN_VALIDATOR = {'tool/perf/compare_ci.py': 'd34d5dff76e785716326bc7913eba3e94048ff423e5632b0757409744c5658df',
 'tool/perf/ui_compare.py': '649f09a7837a9efaaef346c8c997b2af7508e66d2126b815493cf1b90eafe65f',
 'tool/perf/ui_validate.py': 'e5c1371bb16a68615e5e04b40293c9d80f9c2da5be8ba8822916bebfa4ab0cbc'}


def schedule():
    return [{"slot": f"{index + 1:02d}-{role}", "role": role,
             "pair": index // 2 + 1} for index, role in enumerate(SEQUENCE)]


def diagnostic_changed(paths):
    """A PR's historical path match alone must not rerun expensive diagnostics."""
    return any(path == ".github/workflows/performance-paired.yml" or
               (path.startswith("tool/perf/paired_") and path.endswith(".py") and
                "/" not in path[len("tool/perf/"):]) for path in paths)
