"""Run the existing unittest suites and make release skips an explicit failure."""

import argparse
import json
import os
import sys
import unittest
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("syntax", "ingestion", "retrieval", "knowledge_schema"))
    parser.add_argument("files", nargs="*")
    parser.add_argument("--release", action="store_true")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    os.chdir(root)
    sys.path.insert(0, str(root))
    if options.mode == "syntax":
        if not options.files:
            parser.error("No Python sources found; refusing an empty check.")
        for filename in options.files:
            compile(Path(filename).read_bytes(), filename, "exec")
        print(f"PASS Python syntax: {len(options.files)} files ({sys.executable})")
        return 0
    if options.release and options.mode == "ingestion" and sys.version_info[:2] != (3, 11):
        print("FAIL release ingestion tests require the Function runtime Python 3.11.", file=sys.stderr)
        return 1
    suite = unittest.defaultTestLoader.discover("tests", pattern=f"test_{options.mode}.py")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(json.dumps({
        "suite": options.mode, "interpreter": sys.executable,
        "python": ".".join(map(str, sys.version_info[:3])),
        "tests": result.testsRun, "skipped": len(result.skipped), "release": options.release,
    }))
    if options.release and result.skipped:
        print("FAIL release requires every dependency-backed test to execute.", file=sys.stderr)
    return int(not result.wasSuccessful() or result.testsRun == 0 or (options.release and bool(result.skipped)))


if __name__ == "__main__":
    raise SystemExit(main())
