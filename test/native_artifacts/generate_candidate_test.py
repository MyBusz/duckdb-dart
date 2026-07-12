from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tool" / "native_artifacts" / "generate_candidate.py"
SPEC = importlib.util.spec_from_file_location("generate_candidate", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)

SOURCE_COMMIT = "1" * 40
VERSIONS = {
    "android-cmake": "3.22.1",
    "android-ninja": "1.10.2",
    "linux-cmake": "3.22.1",
    "linux-ninja": "1.10.1",
    "linux-clang": "14.0.0",
    "apple-cmake": "4.0.2",
    "apple-ninja": "1.12.1",
    "xcode": "16.4",
    "apple-clang": "17.0.0",
    "windows-cmake": "4.0.2",
    "visual-studio": "17.14.35931.197",
    "msvc": "19.44.35207.1",
}


class GenerateCandidateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.input = self.root / "input"
        self.input.mkdir()
        self._write_inputs()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_inputs(self) -> None:
        for target, archive_name in generator.ARCHIVES.items():
            self._write_archive(target, generator.ESSENTIAL_MEMBERS[target])
        for platform, file_name in generator.METADATA_FILES.items():
            generator.record_tools(
                platform,
                SOURCE_COMMIT,
                self.input / file_name,
                [f"{name}={VERSIONS[name]}" for name in generator.TOOLS_BY_PLATFORM[platform]],
            )

    def _write_archive(self, target: str, members: tuple[str, ...]) -> None:
        with zipfile.ZipFile(self.input / generator.ARCHIVES[target], "w") as archive:
            for index, member in enumerate(members):
                info = zipfile.ZipInfo(member, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, f"{target}-{index}".encode())

    def _generate(self, name: str = "candidate") -> Path:
        output = self.root / name
        generator.generate_candidate(self.input, SOURCE_COMMIT, output)
        return output

    def test_generates_valid_ordered_candidate(self) -> None:
        output = self._generate()
        self.assertEqual(
            {path.name for path in output.iterdir()},
            {*generator.ARCHIVES.values(), "assets.lock.json", "SHA256SUMS"},
        )
        manifest = json.loads((output / "assets.lock.json").read_text())
        self.assertEqual(manifest["sourceCommit"], SOURCE_COMMIT)
        self.assertEqual(
            [tool["name"] for tool in manifest["toolchains"]["buildTools"]],
            list(generator.ORDERED_TOOLS),
        )
        self.assertEqual([item["target"] for item in manifest["artifacts"]], list(generator.ARCHIVES))
        ios = manifest["artifacts"][1]
        self.assertEqual(
            ios["supportedPlatforms"],
            [
                {
                    "platform": "ios",
                    "architectures": ["arm64"],
                    "minimumOsVersion": "13.0",
                },
                {
                    "platform": "ios-simulator",
                    "architectures": ["arm64"],
                    "minimumOsVersion": "14.0",
                },
                {
                    "platform": "ios-simulator",
                    "architectures": ["x86_64"],
                    "minimumOsVersion": "13.0",
                },
            ],
        )

    def test_preserves_archive_bytes(self) -> None:
        output = self._generate()
        for name in generator.ARCHIVES.values():
            self.assertEqual((self.input / name).read_bytes(), (output / name).read_bytes())

    def test_writes_exact_six_ordered_checksum_lines(self) -> None:
        output = self._generate()
        lines = (output / "SHA256SUMS").read_text(encoding="ascii").splitlines()
        self.assertEqual(len(lines), 6)
        expected_names = [*generator.ARCHIVES.values(), "assets.lock.json"]
        self.assertEqual([line.split("  ", 1)[1] for line in lines], expected_names)
        for line, name in zip(lines, expected_names, strict=True):
            self.assertEqual(line.split("  ", 1)[0], hashlib.sha256((output / name).read_bytes()).hexdigest())

    def test_output_is_deterministic(self) -> None:
        first = self._generate("first")
        second = self._generate("second")
        for name in ("assets.lock.json", "SHA256SUMS"):
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())

    def test_rejects_missing_and_extra_archives(self) -> None:
        missing = self.input / next(iter(generator.ARCHIVES.values()))
        saved = missing.read_bytes()
        missing.unlink()
        with self.assertRaises(generator.CandidateError):
            self._generate("missing")
        missing.write_bytes(saved)
        (self.input / "unknown.zip").write_bytes(b"unexpected")
        with self.assertRaises(generator.CandidateError):
            self._generate("extra")

    def test_rejects_missing_and_extra_metadata(self) -> None:
        metadata = self.input / generator.METADATA_FILES["linux"]
        saved = metadata.read_bytes()
        metadata.unlink()
        with self.assertRaises(generator.CandidateError):
            self._generate("missing-metadata")
        metadata.write_bytes(saved)
        (self.input / "other-tools.json").write_text("{}")
        with self.assertRaises(generator.CandidateError):
            self._generate("extra-metadata")

    def test_rejects_source_mismatch(self) -> None:
        metadata = self.input / generator.METADATA_FILES["apple"]
        value = json.loads(metadata.read_text())
        value["sourceCommit"] = "2" * 40
        metadata.write_text(json.dumps(value))
        with self.assertRaisesRegex(generator.CandidateError, "mismatched source commit"):
            self._generate()

    def test_rejects_malformed_and_duplicate_tool_metadata(self) -> None:
        metadata = self.input / generator.METADATA_FILES["windows"]
        metadata.write_text('{"schemaVersion":1,"schemaVersion":1}')
        with self.assertRaisesRegex(generator.CandidateError, "duplicate JSON key"):
            self._generate("duplicate-key")
        metadata.unlink()
        generator.record_tools(
            "windows",
            SOURCE_COMMIT,
            metadata,
            [f"{name}={VERSIONS[name]}" for name in generator.TOOLS_BY_PLATFORM["windows"]],
        )
        value = json.loads(metadata.read_text())
        value["tools"][1] = value["tools"][0]
        metadata.write_text(json.dumps(value))
        with self.assertRaises(generator.CandidateError):
            self._generate("duplicate-tool")

    def test_rejects_wrong_member_set_and_order(self) -> None:
        self._write_archive("android", tuple(reversed(generator.ESSENTIAL_MEMBERS["android"])))
        with self.assertRaisesRegex(generator.CandidateError, "ordered essential members"):
            self._generate("wrong-order")
        self._write_archive("android", (generator.ESSENTIAL_MEMBERS["android"][0],))
        with self.assertRaises(generator.CandidateError):
            self._generate("missing-member")

    def test_rejects_unknown_tool_when_recording_metadata(self) -> None:
        output = self.root / "bad-tools.json"
        values = [
            "android-cmake=3.22.1",
            "arbitrary-ninja=1.10.2",
        ]
        with self.assertRaises(generator.CandidateError):
            generator.record_tools("android", SOURCE_COMMIT, output, values)


if __name__ == "__main__":
    unittest.main()
