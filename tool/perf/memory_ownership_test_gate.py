#!/usr/bin/env python3
"""Require real new-schema and unchanged legacy test suites before measurement."""
import json
from pathlib import Path
import unittest


def main():
    root = Path(__file__).resolve().parent
    patterns = ('memory_ownership*_test.py', 'computer_memory_checks_test.py',
                'memory_probe_control_validate_test.py')
    combined, counts = unittest.TestSuite(), {}
    for pattern in patterns:
        suite = unittest.defaultTestLoader.discover(str(root), pattern=pattern)
        count = suite.countTestCases()
        if count == 0:
            raise ValueError('Required suite discovered zero tests: ' + pattern)
        counts[pattern] = count
        combined.addTests(suite)
    print(json.dumps({'requiredTestCounts': counts}), flush=True)
    result = unittest.TextTestRunner(verbosity=2).run(combined)
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
