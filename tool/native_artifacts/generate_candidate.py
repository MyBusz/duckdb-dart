#!/usr/bin/env python3
"""Record native tool identities and assemble a verified release candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
import zipfile


CORE_COMMIT = "68d7555f68bd25c1a251ccca2e6338949c33986a"
RELEASE_TAG = "native-duckdb-1.4.2-r1"
FLUTTER_VERSION = "3.41.3"
DART_VERSION = "3.11.1"
ANDROID_NDK_VERSION = "28.2.13676358"

ARCHIVES = {
    "android": "duckdb-android-arm64-v8a-x86_64.zip",
    "ios": "duckdb-ios-xcframework.zip",
    "macos": "duckdb-macos-universal.zip",
    "linux": "duckdb-linux-x86_64.zip",
    "windows": "duckdb-windows-x64.zip",
}
METADATA_FILES = {
    "android": "android-tools.json",
    "linux": "linux-tools.json",
    "apple": "apple-tools.json",
    "windows": "windows-tools.json",
}
TOOLS_BY_PLATFORM = {
    "android": ("android-cmake", "android-ninja"),
    "linux": ("linux-cmake", "linux-ninja", "linux-clang"),
    "apple": ("apple-cmake", "apple-ninja", "xcode", "apple-clang"),
    "windows": ("windows-cmake", "visual-studio", "msvc"),
}
ORDERED_TOOLS = tuple(
    tool
    for platform in ("android", "linux", "apple", "windows")
    for tool in TOOLS_BY_PLATFORM[platform]
)
ESSENTIAL_MEMBERS = {
    "android": (
        "arm64-v8a/libduckdb.so",
        "x86_64/libduckdb.so",
    ),
    "ios": (
        "duckdb.xcframework/Info.plist",
        "duckdb.xcframework/ios-arm64/duckdb.framework/duckdb",
        "duckdb.xcframework/ios-arm64_x86_64-simulator/duckdb.framework/duckdb",
    ),
    "macos": ("libduckdb.dylib",),
    "linux": ("libduckdb.so",),
    "windows": ("duckdb.dll",),
}
INSTALL_ROOTS = {
    "android": "android/src/main/jniLibs",
    "ios": "ios/Libraries/release",
    "macos": "macos/Libraries/release",
    "linux": "linux/Libraries/release",
    "windows": "windows/Libraries/release",
}
SUPPORTED_PLATFORMS = {
    "android": [
        {
            "platform": "android",
            "architectures": ["arm64-v8a", "x86_64"],
            "minimumOsVersion": "21",
        }
    ],
    "ios": [
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
    "macos": [
        {
            "platform": "macos",
            "architectures": ["x86_64"],
            "minimumOsVersion": "10.15",
        },
        {
            "platform": "macos",
            "architectures": ["arm64"],
            "minimumOsVersion": "11.0",
        },
    ],
    "linux": [{"platform": "linux", "architectures": ["x86_64"]}],
    "windows": [{"platform": "windows", "architectures": ["x64"]}],
}

COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
VERSION_PATTERN = re.compile(
    r"^[0-9]+(?:\.[0-9]+){0,3}(?:[-+][0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$"
)


class CandidateError(RuntimeError):
    """A candidate input violates the release contract."""


def fail(message: str) -> None:
    raise CandidateError(message)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _require_regular_file(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"missing {label}: {path.name}")
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        fail(f"{label} must be a regular non-symlink file: {path.name}")


def _strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            fail(f"tool metadata contains duplicate JSON key {key!r}")
        result[key] = value
    return result


def _load_metadata(path: Path, platform: str, source_commit: str) -> list[dict[str, str]]:
    _require_regular_file(path, "tool metadata")
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_strict_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"malformed tool metadata {path.name}: {error}")
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion",
        "platform",
        "sourceCommit",
        "coreCommit",
        "tools",
    }:
        fail(f"tool metadata {path.name} has missing or unknown fields")
    if value["schemaVersion"] != 1 or value["platform"] != platform:
        fail(f"tool metadata {path.name} has the wrong identity")
    if value["sourceCommit"] != source_commit:
        fail(f"tool metadata {path.name} has a mismatched source commit")
    if value["coreCommit"] != CORE_COMMIT:
        fail(f"tool metadata {path.name} has a mismatched DuckDB commit")
    tools = value["tools"]
    if not isinstance(tools, list) or len(tools) != len(TOOLS_BY_PLATFORM[platform]):
        fail(f"tool metadata {path.name} has the wrong tool count")
    result: list[dict[str, str]] = []
    seen: set[str] = set()
    for index, item in enumerate(tools):
        expected_name = TOOLS_BY_PLATFORM[platform][index]
        if not isinstance(item, dict) or set(item) != {"name", "version"}:
            fail(f"tool metadata {path.name} has a malformed tool record")
        name = item["name"]
        version = item["version"]
        if name != expected_name or not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
            fail(f"tool metadata {path.name} has an invalid tool identity or version")
        if name in seen:
            fail(f"tool metadata {path.name} contains a duplicate tool")
        seen.add(name)
        result.append({"name": name, "version": version})
    return result


def _validate_member_name(name: str) -> None:
    try:
        name.encode("ascii")
    except UnicodeEncodeError:
        fail(f"archive member is not ASCII: {name!r}")
    path = PurePosixPath(name)
    if (
        not name
        or name.startswith("/")
        or name.endswith("/")
        or "\\" in name
        or re.match(r"^[A-Za-z]:", name)
        or path.is_absolute()
        or any(part in ("", ".", "..") for part in name.split("/"))
        or any(ord(character) < 0x20 or ord(character) > 0x7E for character in name)
    ):
        fail(f"archive member path is unsafe: {name!r}")


def _inspect_archive(path: Path, target: str) -> dict[str, object]:
    _require_regular_file(path, "native archive")
    size = path.stat().st_size
    if size <= 0:
        fail(f"native archive is empty: {path.name}")
    archive_hash = _sha256_file(path)
    members: list[dict[str, object]] = []
    try:
        with zipfile.ZipFile(path, "r") as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            essential = ESSENTIAL_MEMBERS[target]
            if tuple(names[: len(essential)]) != essential:
                fail(f"{path.name} does not begin with the ordered essential members")
            if len(names) < len(essential):
                fail(f"{path.name} is missing essential members")
            folded: set[str] = set()
            for info in infos:
                _validate_member_name(info.filename)
                if info.filename.lower() in folded:
                    fail(f"{path.name} contains duplicate or case-colliding members")
                folded.add(info.filename.lower())
                unix_mode = info.external_attr >> 16
                if (
                    info.is_dir()
                    or stat.S_ISLNK(unix_mode)
                    or (unix_mode != 0 and not stat.S_ISREG(unix_mode))
                    or info.flag_bits & 0x1
                ):
                    fail(
                        f"{path.name} contains a directory, special file, "
                        "symlink, or encrypted member"
                    )
                if info.file_size <= 0:
                    fail(f"{path.name} contains an empty member")
                digest = hashlib.sha256()
                with archive.open(info, "r") as source:
                    while block := source.read(1024 * 1024):
                        digest.update(block)
                members.append(
                    {
                        "path": info.filename,
                        "size": info.file_size,
                        "sha256": digest.hexdigest(),
                        "installDestination": f"{INSTALL_ROOTS[target]}/{info.filename}",
                    }
                )
    except CandidateError:
        raise
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        fail(f"unable to inspect {path.name}: {error}")
    return {
        "target": target,
        "fileName": path.name,
        "size": size,
        "sha256": archive_hash,
        "supportedPlatforms": SUPPORTED_PLATFORMS[target],
        "members": members,
    }


def record_tools(
    platform: str,
    source_commit: str,
    output: Path,
    tool_values: list[str],
) -> None:
    if not COMMIT_PATTERN.fullmatch(source_commit):
        fail("source commit must be a full lowercase Git SHA")
    if platform not in TOOLS_BY_PLATFORM:
        fail(f"unknown tool metadata platform: {platform}")
    if len(tool_values) != len(TOOLS_BY_PLATFORM[platform]):
        fail(f"{platform} metadata requires exactly {len(TOOLS_BY_PLATFORM[platform])} tools")
    tools: list[dict[str, str]] = []
    seen: set[str] = set()
    for index, value in enumerate(tool_values):
        if "=" not in value:
            fail("tool values must use NAME=VERSION")
        name, version = value.split("=", 1)
        if name != TOOLS_BY_PLATFORM[platform][index] or name in seen:
            fail(f"{platform} tools must be supplied once in contract order")
        if not VERSION_PATTERN.fullmatch(version):
            fail(f"invalid version for {name}: {version!r}")
        seen.add(name)
        tools.append({"name": name, "version": version})
    if output.exists() or output.is_symlink():
        fail(f"metadata output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    value = {
        "schemaVersion": 1,
        "platform": platform,
        "sourceCommit": source_commit,
        "coreCommit": CORE_COMMIT,
        "tools": tools,
    }
    output.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8", newline="\n")


def generate_candidate(input_dir: Path, source_commit: str, output_dir: Path) -> None:
    if not COMMIT_PATTERN.fullmatch(source_commit):
        fail("source commit must be a full lowercase Git SHA")
    try:
        input_metadata = input_dir.lstat()
    except FileNotFoundError:
        fail("candidate input directory is missing")
    if not stat.S_ISDIR(input_metadata.st_mode) or input_dir.is_symlink():
        fail("candidate input must be a real directory")
    expected_names = set(ARCHIVES.values()) | set(METADATA_FILES.values())
    actual_names = {entry.name for entry in input_dir.iterdir()}
    missing = sorted(expected_names - actual_names)
    extra = sorted(actual_names - expected_names)
    if missing or extra:
        fail(f"candidate input file set mismatch; missing={missing}, extra={extra}")

    build_tools: list[dict[str, str]] = []
    for platform, file_name in METADATA_FILES.items():
        build_tools.extend(_load_metadata(input_dir / file_name, platform, source_commit))
    if tuple(tool["name"] for tool in build_tools) != ORDERED_TOOLS:
        fail("combined native tools are not in contract order")

    artifacts = [
        _inspect_archive(input_dir / file_name, target)
        for target, file_name in ARCHIVES.items()
    ]
    manifest = {
        "schemaVersion": 1,
        "releaseTag": RELEASE_TAG,
        "sourceCommit": source_commit,
        "coreCommit": CORE_COMMIT,
        "toolchains": {
            "flutter": FLUTTER_VERSION,
            "dart": DART_VERSION,
            "androidNdk": ANDROID_NDK_VERSION,
            "buildTools": build_tools,
        },
        "staticExtensions": ["icu", "parquet", "json"],
        "licenses": [
            {"path": "LICENSE", "identifier": "MIT"},
            {"path": "licenses/duckdb/LICENSE", "identifier": "MIT"},
        ],
        "artifacts": artifacts,
    }
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    archive_hashes = {
        artifact["fileName"]: artifact["sha256"] for artifact in artifacts
    }

    if output_dir.exists() or output_dir.is_symlink():
        fail("candidate output directory must not already exist")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.", dir=output_dir.parent))
    try:
        for file_name in ARCHIVES.values():
            source = input_dir / file_name
            destination = stage / file_name
            shutil.copyfile(source, destination)
            if _sha256_file(destination) != archive_hashes[file_name]:
                fail(f"copied archive changed: {file_name}")
        manifest_path = stage / "assets.lock.json"
        manifest_path.write_bytes(manifest_bytes)
        checksum_names = [*ARCHIVES.values(), "assets.lock.json"]
        checksum_text = "".join(
            f"{_sha256_file(stage / name)}  {name}\n" for name in checksum_names
        )
        (stage / "SHA256SUMS").write_text(
            checksum_text,
            encoding="ascii",
            newline="\n",
        )
        os.replace(stage, output_dir)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    record = subparsers.add_parser("record-tools", help="write strict build metadata")
    record.add_argument("--platform", required=True, choices=tuple(TOOLS_BY_PLATFORM))
    record.add_argument("--source-commit", required=True)
    record.add_argument("--output", required=True, type=Path)
    record.add_argument("--tool", action="append", required=True)
    generate = subparsers.add_parser("generate", help="assemble seven candidate assets")
    generate.add_argument("--input-dir", required=True, type=Path)
    generate.add_argument("--source-commit", required=True)
    generate.add_argument("--output-dir", required=True, type=Path)
    return parser


def main(arguments: list[str] | None = None) -> int:
    options = _parser().parse_args(arguments)
    try:
        if options.command == "record-tools":
            record_tools(options.platform, options.source_commit, options.output, options.tool)
        else:
            generate_candidate(options.input_dir, options.source_commit, options.output_dir)
    except CandidateError as error:
        print(f"native candidate: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
