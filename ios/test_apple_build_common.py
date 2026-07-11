from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


COMMON = Path(__file__).with_name("apple_build_common.sh")


class AppleBuildCommonTest(unittest.TestCase):
    def run_assertion(self, symbol_function: str) -> subprocess.CompletedProcess[str]:
        script = f"""
source {COMMON!s}
{symbol_function}
assert_duckdb_symbols ignored arm64
"""
        return subprocess.run(
            ["bash", "-c", script],
            check=False,
            text=True,
            capture_output=True,
        )

    def test_symbol_derivation_failure_is_not_hidden(self) -> None:
        result = self.run_assertion("required_dart_symbols() { return 17; }")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("derivation failed with status 17", result.stderr)

    def test_symbol_count_must_be_exactly_109(self) -> None:
        result = self.run_assertion(
            "required_dart_symbols() { "
            "local i; for ((i = 0; i < 108; i++)); do printf 'symbol_%d\\n' \"$i\"; done; "
            "}"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("returned 108 symbols; expected 109", result.stderr)


if __name__ == "__main__":
    unittest.main()
