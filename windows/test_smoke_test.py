from __future__ import annotations

from pathlib import Path
import re
import unittest


SMOKE_TEST = Path(__file__).with_name("SmokeTest.ps1")


class SmokeTestNativeImportTests(unittest.TestCase):
    def test_native_imports_use_exact_explicit_entry_points(self) -> None:
        script = SMOKE_TEST.read_text(encoding="utf-8")
        source_match = re.search(r"\$Source = @'\n(?P<source>.*?)\n'@", script, re.DOTALL)
        self.assertIsNotNone(source_match, "embedded C# source was not found")
        source = source_match.group("source")

        declarations = re.findall(
            r'\[DllImport\("(?P<library>[^"]+)"(?P<arguments>.*?)\)\]\s*'
            r'(?:\[return: MarshalAs\([^]]+\)\]\s*)?'
            r"private static extern [^(]+ (?P<method>\w+)\(",
            source,
            re.DOTALL,
        )
        expected = {
            "LoadLibraryW": {
                "EntryPoint": '"LoadLibraryW"',
                "CharSet": "CharSet.Unicode",
                "SetLastError": "true",
                "ExactSpelling": "true",
            },
            "GetProcAddress": {
                "EntryPoint": '"GetProcAddress"',
                "CharSet": "CharSet.Ansi",
                "SetLastError": "true",
                "ExactSpelling": "true",
            },
            "FreeLibrary": {
                "EntryPoint": '"FreeLibrary"',
                "SetLastError": "true",
                "ExactSpelling": "true",
            },
        }

        self.assertEqual(len(declarations), source.count("[DllImport("))
        self.assertEqual(len(declarations), len(expected))
        self.assertEqual({method for _, _, method in declarations}, set(expected))
        for library, arguments, method in declarations:
            with self.subTest(method=method):
                self.assertEqual(library, "kernel32.dll")
                options = dict(
                    re.findall(r"(\w+)\s*=\s*([^,]+?)(?=\s*,|$)", arguments.strip())
                )
                self.assertEqual(options, expected[method])


if __name__ == "__main__":
    unittest.main()
