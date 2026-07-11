from __future__ import annotations

from contextlib import redirect_stderr
import io
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import validate_android as validator


class AndroidArchiveTests(unittest.TestCase):
    def _library_root(self, root: Path, *, complete: bool = True) -> Path:
        libraries = root / "libraries"
        for index, member in enumerate(validator.MEMBERS):
            if index == 1 and not complete:
                break
            library = libraries.joinpath(*member.split("/"))
            library.parent.mkdir(parents=True, exist_ok=True)
            library.write_bytes(f"library-{index}".encode("ascii"))
        return libraries

    def test_create_uses_candidate_and_does_not_replace_final(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            final = root / validator.ARCHIVE_NAME
            final.write_bytes(b"existing release")

            candidate = validator.create_archive(final, self._library_root(root))
            self.addCleanup(candidate.unlink, missing_ok=True)

            self.assertNotEqual(candidate, final)
            self.assertEqual(candidate.parent, final.parent)
            self.assertEqual(final.read_bytes(), b"existing release")
            validator.validate_zip_structure(candidate)

    def test_create_failure_removes_candidate_and_preserves_final(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            final = root / validator.ARCHIVE_NAME
            final.write_bytes(b"existing release")

            with self.assertRaisesRegex(validator.ValidationError, "missing regular input"):
                validator.create_archive(
                    final,
                    self._library_root(root, complete=False),
                )

            self.assertEqual(final.read_bytes(), b"existing release")
            self.assertEqual(
                list(root.glob(f".{validator.ARCHIVE_NAME}.*.tmp.zip")),
                [],
            )

    def test_validation_failure_does_not_replace_final(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            final = root / validator.ARCHIVE_NAME
            final.write_bytes(b"existing release")
            arguments = SimpleNamespace(
                archive=final,
                ndk=root / "ndk",
                build_root=None,
                library_root=self._library_root(root),
                create=True,
            )

            with mock.patch.object(validator, "parse_args", return_value=arguments):
                with mock.patch.object(
                    validator,
                    "validate_archive_binaries",
                    side_effect=validator.ValidationError("expected failure"),
                ):
                    errors = io.StringIO()
                    with redirect_stderr(errors):
                        self.assertEqual(validator.main(), 1)
                    self.assertIn("expected failure", errors.getvalue())

            self.assertEqual(final.read_bytes(), b"existing release")
            self.assertEqual(
                list(root.glob(f".{validator.ARCHIVE_NAME}.*.tmp.zip")),
                [],
            )


class AndroidElfTests(unittest.TestCase):
    def _elf(self, *, elf_type: int = 3, load_offset: int = 0) -> bytes:
        identification = b"\x7fELF" + bytes((2, 1, 1)) + bytes(9)
        header = struct.pack(
            "<16sHHIQQQIHHHHHH",
            identification,
            elf_type,
            validator.MACHINES[validator.MEMBERS[0]],
            1,
            0,
            64,
            0,
            0,
            64,
            56,
            1,
            0,
            0,
            0,
        )
        program = struct.pack("<IIQQQQQQ", 1, 5, load_offset, 0, 0, 1, 1, 16384)
        return header + program

    def test_rejects_non_dynamic_elf(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            library = Path(temporary) / "libduckdb.so"
            library.write_bytes(self._elf(elf_type=2))
            with self.assertRaisesRegex(validator.ValidationError, "expected ET_DYN"):
                validator.validate_elf(
                    library,
                    validator.MEMBERS[0],
                    Path("readelf"),
                    Path("nm"),
                )

    def test_rejects_incongruent_load_segment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            library = Path(temporary) / "libduckdb.so"
            library.write_bytes(self._elf(load_offset=1))
            with self.assertRaisesRegex(validator.ValidationError, "incongruent"):
                validator.validate_elf(
                    library,
                    validator.MEMBERS[0],
                    Path("readelf"),
                    Path("nm"),
                )

    def test_requires_extension_and_static_loader_symbols(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            library = Path(temporary) / "libduckdb.so"
            library.write_bytes(self._elf())
            dynamic = "(SONAME) Library soname: [libduckdb.so]\n"
            c_api_symbols = "\n".join(
                f"00000000 T {symbol}" for symbol in sorted(validator.REQUIRED_SYMBOLS)
            )
            with mock.patch.object(
                validator,
                "run_tool",
                side_effect=(dynamic, c_api_symbols),
            ):
                with self.assertRaisesRegex(
                    validator.ValidationError,
                    "missing linked ICU/JSON/Parquet or static-loader symbols",
                ):
                    validator.validate_elf(
                        library,
                        validator.MEMBERS[0],
                        Path("readelf"),
                        Path("nm"),
                    )


if __name__ == "__main__":
    unittest.main()
