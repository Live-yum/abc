"""Fixed inputs for an additional MAP-only causal experiment, never acceptance."""

PINS = {
    "A": {"commit": "a5612b474fc8dc50d41b3bc6b87234d30ba97e02",
          "tree": "19afe39726b5ee724af413c2546c4389c5d0c205"},
    "B": {"commit": "cddd936f95d31b14a76503e13ffc89173110a057",
          "tree": "ff5236bcfa02b8fcb3f361e9437c59c5bacc60fd"},
}
VARIANTS = {
    "A": ("A", ()),
    "A_SHA": ("A", ("native/abc_engine.c", "native/abc_engine.h")),
    "A_QUERY": ("A", ("native/vendor/TerraWasm/src/terra_circuit_query.c",)),
    "B": ("B", ()),
}
TREES = {"A": PINS["A"]["tree"], "B": PINS["B"]["tree"],
         "A_SHA": "a3b91b75f755bfc48f61228a06ab107e4be0cb93",
         "A_QUERY": "e3a308005099165197d3f2904fb1da8929702227"}
# Defined before observing any new timings; exactly three independent processes
# per variant in each group. Groups have distinct fresh processes and reports.
ORDER = ("A", "A_SHA", "A_QUERY", "B",
         "B", "A_QUERY", "A_SHA", "A",
         "A_SHA", "A", "B", "A_QUERY")
GROUPS = ("frozen", "auxiliary")
HARNESS = {
    "tool/perf/generate_native_map.py": "6103d4fa294e6a215d00a8a71174db53a28042055e58b11e5a566a4293fa14bd",
    "tool/perf/generate_synthetic_world.py": "19ab1b7501e9fd36a1334ca012f0c3b4098942618a6db5d98326ba426fd3a04b",
    "tool/perf/run_ci_suite.py": "33258516eb3a1c207a8dcd1ba6867ab611e992d52cffa33dab103c5514768315",
    "tool/perf/compare.py": "91f4073d6701a84ac1a880a5a77131b36c0ad0135620a7da977c914509985be8",
}
FIXTURE = {"bytes": 262536,
           "sha256": "d24057aa969cd0cb6ec3af93670e8be87828157facd77412a7d99fc88bc350b7"}
ITERATIONS = 26
EXPECTED_MATCHES = {"matched_tile_count": 65536, "matched_chest_count": 0}
REQUESTS = (("lit", b"render_lit_map", b"{}"),
            ("marked", b"mark_tiles_and_chests_map",
             b'{"tile_markers":[{"tile_type":1,"color":"#ff00ff","radius":2}]}'))
BUILD_TIMEOUT = 1800
PROCESS_TIMEOUT = 600
EXECUTION_BUDGET = 30 * 60  # Shared by all builds and measurements; reserve upload time.


def schedule():
    return [{"slot": f"{number:02d}-{variant}", "variant": variant}
            for number, variant in enumerate(ORDER, 1)]


def diagnostic_changed(paths):
    return any(path == ".github/workflows/performance-mapgen-diagnostic.yml" or
               (path.startswith("tool/perf/mapgen_diagnostic") and path.endswith(".py") and
                "/" not in path[len("tool/perf/"):]) for path in paths)
