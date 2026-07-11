from __future__ import annotations

import importlib.util
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("create_contract_zip.py")
SPEC = importlib.util.spec_from_file_location("create_contract_zip", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
zip_creator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(zip_creator)


class CreateContractZipTest(unittest.TestCase):
    def run_creator(self, archive: Path, root: Path, *names: str) -> None:
        arguments = [str(SCRIPT), str(archive), str(root), *names]
        with mock.patch.object(sys, "argv", arguments):
            zip_creator.main()

    def test_shared_limits_are_mirrored_exactly(self) -> None:
        self.assertEqual(zip_creator.MAX_ARCHIVE_BYTES, 512 * 1024 * 1024)
        self.assertEqual(zip_creator.MAX_MEMBER_BYTES, 256 * 1024 * 1024)
        self.assertEqual(zip_creator.MAX_EXPANDED_BYTES, 1024 * 1024 * 1024)
        self.assertEqual(zip_creator.MAX_ARCHIVE_ENTRIES, 64)
        self.assertEqual(zip_creator.MAX_COMPRESSION_RATIO, 200)

    def test_creator_validates_structure_and_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            (root / "library.bin").write_bytes(bytes(range(256)) * 8)
            archive = Path(temporary) / "artifact.zip"
            self.run_creator(archive, root, "library.bin")
            self.assertTrue(archive.is_file())

    def test_rejects_non_normalized_member_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(SystemExit, "not normalized"):
                self.run_creator(root / "artifact.zip", root, "../escape")

    def test_rejects_non_printable_ascii_member_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("line\nbreak", "delete\x7fcharacter"):
                with self.subTest(name=repr(name)):
                    with self.assertRaisesRegex(SystemExit, "printable ASCII"):
                        self.run_creator(root / "artifact.zip", root, name)

    def test_rejects_drive_style_member_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("C:relative", "d:/absolute"):
                with self.subTest(name=name):
                    with self.assertRaisesRegex(SystemExit, "not normalized"):
                        self.run_creator(root / "artifact.zip", root, name)

    def test_rejects_case_colliding_member_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Library.bin").write_bytes(b"one")
            (root / "library.bin").write_bytes(b"two")
            with self.assertRaisesRegex(SystemExit, "case-colliding"):
                self.run_creator(
                    root / "artifact.zip", root, "Library.bin", "library.bin"
                )

    def test_rejects_symlink_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "target").write_bytes(b"content")
            (root / "link").symlink_to("target")
            with self.assertRaisesRegex(SystemExit, "symlink"):
                self.run_creator(root / "artifact.zip", root, "link")

    def test_rejects_more_than_64_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            names = tuple(f"member-{index}" for index in range(65))
            with self.assertRaisesRegex(SystemExit, "64-entry"):
                self.run_creator(root / "artifact.zip", root, *names)

    def test_rejects_member_over_256_mib_before_reading_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "oversized.bin"
            with source.open("wb") as output:
                output.truncate(zip_creator.MAX_MEMBER_BYTES + 1)
            with self.assertRaisesRegex(SystemExit, "256 MiB"):
                self.run_creator(root / "artifact.zip", root, source.name)

    def test_rejects_expanded_total_over_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one").write_bytes(b"12")
            (root / "two").write_bytes(b"34")
            with mock.patch.object(zip_creator, "MAX_EXPANDED_BYTES", 3):
                with self.assertRaisesRegex(SystemExit, "expanded archive"):
                    self.run_creator(root / "artifact.zip", root, "one", "two")

    def test_rejects_archive_over_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            source = root / "member"
            source.write_bytes(bytes(range(64)))
            archive = Path(temporary) / "artifact.zip"
            self.run_creator(archive, root, source.name)
            digest = zip_creator.file_digest(source)
            with mock.patch.object(zip_creator, "MAX_ARCHIVE_BYTES", archive.stat().st_size - 1):
                with self.assertRaisesRegex(SystemExit, "archive size"):
                    zip_creator.verify_archive(
                        archive, root, [source.name], {source.name: digest}
                    )

    def test_rejects_compression_ratio_over_200(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "zeros.bin"
            source.write_bytes(b"\0" * (1024 * 1024))
            archive = root / "artifact.zip"
            with self.assertRaisesRegex(SystemExit, "member sizes"):
                self.run_creator(archive, root, source.name)
            self.assertFalse(archive.exists())

    def test_rejects_archive_comment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            source = root / "member"
            source.write_bytes(bytes(range(64)))
            archive = Path(temporary) / "artifact.zip"
            self.run_creator(archive, root, source.name)
            with zipfile.ZipFile(archive, "a") as output:
                output.comment = b"forbidden"
            with self.assertRaisesRegex(SystemExit, "comment-free"):
                zip_creator.verify_archive(
                    archive,
                    root,
                    [source.name],
                    {source.name: zip_creator.file_digest(source)},
                )

    def test_rejects_data_descriptor_flag_and_zip64_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            source = root / "member"
            source.write_bytes(bytes(range(64)))
            archive = Path(temporary) / "artifact.zip"
            self.run_creator(archive, root, source.name)
            original = archive.read_bytes()
            eocd = len(original) - 22
            central_offset = struct.unpack_from("<I", original, eocd + 16)[0]
            digest = {source.name: zip_creator.file_digest(source)}

            descriptor = bytearray(original)
            struct.pack_into("<H", descriptor, 6, struct.unpack_from("<H", descriptor, 6)[0] | 8)
            struct.pack_into(
                "<H",
                descriptor,
                central_offset + 8,
                struct.unpack_from("<H", descriptor, central_offset + 8)[0] | 8,
            )
            archive.write_bytes(descriptor)
            with self.assertRaisesRegex(SystemExit, "flags"):
                zip_creator.verify_archive(archive, root, [source.name], digest)

            zip64 = bytearray(original)
            struct.pack_into("<I", zip64, central_offset + 20, 0xFFFFFFFF)
            archive.write_bytes(zip64)
            with self.assertRaisesRegex(SystemExit, "member sizes"):
                zip_creator.verify_archive(archive, root, [source.name], digest)


if __name__ == "__main__":
    unittest.main()
