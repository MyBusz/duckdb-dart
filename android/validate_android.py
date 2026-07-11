#!/usr/bin/env python3
"""Create and validate the pinned Android DuckDB native archive."""

from __future__ import annotations

import argparse
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile


ARCHIVE_NAME = "duckdb-android-arm64-v8a-x86_64.zip"
MEMBERS = (
    "arm64-v8a/libduckdb.so",
    "x86_64/libduckdb.so",
)
MACHINES = {
    "arm64-v8a/libduckdb.so": 183,  # EM_AARCH64
    "x86_64/libduckdb.so": 62,  # EM_X86_64
}
STATIC_EXTENSIONS = {"core_functions", "icu", "json", "parquet"}
REQUIRED_SYMBOLS = {
    "duckdb_close",
    "duckdb_connect",
    "duckdb_destroy_result",
    "duckdb_disconnect",
    "duckdb_library_version",
    "duckdb_open",
    "duckdb_query",
}
REQUIRED_EXTENSION_SYMBOLS = {
    "_ZN6duckdb12IcuExtension4LoadERNS_15ExtensionLoaderE",
    "_ZN6duckdb13JsonExtension4LoadERNS_15ExtensionLoaderE",
    "_ZN6duckdb16ParquetExtension4LoadERNS_15ExtensionLoaderE",
    "_ZN6duckdb16LinkedExtensionsEv",
    "_ZN6duckdb6DuckDB19LoadStaticExtensionINS_12IcuExtensionEEEvv",
    "_ZN6duckdb6DuckDB19LoadStaticExtensionINS_13JsonExtensionEEEvv",
    "_ZN6duckdb6DuckDB19LoadStaticExtensionINS_16ParquetExtensionEEEvv",
}
ALLOWED_NEEDED = {"libc.so", "libdl.so", "liblog.so", "libm.so"}


class ValidationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--ndk", required=True, type=Path)
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("--library-root", type=Path)
    parser.add_argument("--create", action="store_true")
    args = parser.parse_args()
    if args.create and args.library_root is None:
        parser.error("--create requires --library-root")
    return args


def validate_member_name(name: str) -> None:
    try:
        name.encode("ascii")
    except UnicodeEncodeError as error:
        fail(f"archive member is not ASCII: {name!r}")
        raise AssertionError from error
    path = PurePosixPath(name)
    if (
        not name
        or name.startswith("/")
        or "\\" in name
        or path.as_posix() != name
        or any(part in {"", ".", ".."} for part in name.split("/"))
    ):
        fail(f"archive member is not normalized: {name!r}")


def create_archive(archive: Path, library_root: Path) -> Path:
    if archive.name != ARCHIVE_NAME:
        fail(f"archive must be named {ARCHIVE_NAME}")
    archive.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=archive.parent,
        prefix=f".{archive.name}.",
        suffix=".tmp.zip",
    )
    os.close(descriptor)
    temporary_archive = Path(temporary_name)
    try:
        with zipfile.ZipFile(
            temporary_archive,
            mode="w",
            compression=zipfile.ZIP_STORED,
            allowZip64=False,
            strict_timestamps=True,
        ) as output:
            output.comment = b""
            for member in MEMBERS:
                source = library_root.joinpath(*member.split("/"))
                if not source.is_file() or source.is_symlink():
                    fail(f"missing regular input library: {source}")
                info = zipfile.ZipInfo(member, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_STORED
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                info.flag_bits = 0
                output.writestr(info, source.read_bytes())
    except Exception:
        temporary_archive.unlink(missing_ok=True)
        raise
    return temporary_archive


def validate_zip_structure(archive: Path) -> None:
    data = archive.read_bytes()
    if len(data) < 22 or data[-22:-18] != b"PK\x05\x06":
        fail("archive must end in an uncommented EOCD record")
    (
        signature,
        disk,
        central_disk,
        disk_entries,
        total_entries,
        central_size,
        central_offset,
        comment_length,
    ) = struct.unpack_from("<4s4H2LH", data, len(data) - 22)
    if signature != b"PK\x05\x06" or comment_length != 0:
        fail("archive comments are unsupported")
    if disk != 0 or central_disk != 0 or disk_entries != total_entries:
        fail("multi-disk ZIP archives are unsupported")
    if total_entries != len(MEMBERS):
        fail("archive must contain exactly the two Android libraries")
    if total_entries == 0xFFFF or central_size == 0xFFFFFFFF or central_offset == 0xFFFFFFFF:
        fail("ZIP64 archives are unsupported")
    if central_offset + central_size != len(data) - 22:
        fail("central directory does not end immediately before EOCD")

    cursor = central_offset
    names: list[str] = []
    expected_local_offset = 0
    for _ in range(total_entries):
        if cursor + 46 > central_offset + central_size:
            fail("truncated central directory")
        fields = struct.unpack_from("<4s6H3L5H2L", data, cursor)
        if fields[0] != b"PK\x01\x02":
            fail("invalid central-directory signature")
        (
            _,
            version_made,
            version_needed,
            flags,
            method,
            modified_time,
            modified_date,
            crc,
            compressed_size,
            uncompressed_size,
            name_length,
            extra_length,
            member_comment_length,
            disk_start,
            _,
            external_attributes,
            local_offset,
        ) = fields
        variable_start = cursor + 46
        variable_end = variable_start + name_length + extra_length + member_comment_length
        if variable_end > central_offset + central_size:
            fail("central-directory variable data is truncated")
        name_bytes = data[variable_start : variable_start + name_length]
        try:
            name = name_bytes.decode("ascii")
        except UnicodeDecodeError as error:
            fail("archive member name is not ASCII")
            raise AssertionError from error
        validate_member_name(name)
        names.append(name)
        if extra_length != 0 or version_needed >= 45:
            fail("ZIP extra fields and ZIP64 features are unsupported")
        if (
            flags != 0
            or method != zipfile.ZIP_STORED
            or member_comment_length != 0
            or disk_start != 0
            or version_made >> 8 != 3
            or not stat.S_ISREG(external_attributes >> 16)
        ):
            fail(f"unsupported ZIP feature on {name}")
        if modified_time != 0 or modified_date != 33:
            fail(f"non-normalized timestamp on {name}")
        if local_offset != expected_local_offset or local_offset + 30 > central_offset:
            fail(f"non-contiguous or invalid local record for {name}")
        local = struct.unpack_from("<4s5H3L2H", data, local_offset)
        if local[0] != b"PK\x03\x04":
            fail(f"invalid local-header signature for {name}")
        if (
            local[2] != flags
            or local[3] != method
            or local[6] != crc
            or local[7] != compressed_size
            or local[8] != uncompressed_size
            or local[9] != name_length
        ):
            fail(f"local and central metadata differ for {name}")
        local_name_start = local_offset + 30
        local_name_end = local_name_start + local[9]
        local_extra_end = local_name_end + local[10]
        if data[local_name_start:local_name_end] != name_bytes or local[10] != 0:
            fail(f"local name or extra data is unsupported for {name}")
        data_end = local_extra_end + compressed_size
        if data_end > central_offset:
            fail(f"member data overlaps the central directory for {name}")
        expected_local_offset = data_end
        cursor = variable_end

    if tuple(names) != MEMBERS or cursor != central_offset + central_size:
        fail("archive member order or central-directory length is invalid")
    if expected_local_offset != central_offset:
        fail("unexpected bytes occur between members and the central directory")

    with zipfile.ZipFile(archive, "r") as source:
        if source.comment or tuple(source.namelist()) != MEMBERS:
            fail("archive comments or members do not match the contract")
        for info in source.infolist():
            if info.flag_bits & 0x08:
                fail(f"data descriptor is unsupported for {info.filename}")
            if info.is_dir() or stat.S_ISLNK(info.external_attr >> 16):
                fail(f"directory or symlink member is unsupported: {info.filename}")
            if info.file_size == 0:
                fail(f"empty native library: {info.filename}")
            source.read(info)


def locate_llvm_tools(ndk: Path) -> tuple[Path, Path]:
    prebuilt = ndk / "toolchains" / "llvm" / "prebuilt"
    candidates = sorted(path for path in prebuilt.iterdir() if path.is_dir())
    for candidate in candidates:
        readelf = candidate / "bin" / "llvm-readelf"
        nm = candidate / "bin" / "llvm-nm"
        if readelf.is_file() and nm.is_file():
            return readelf, nm
    fail(f"NDK LLVM inspection tools are missing under {prebuilt}")


def run_tool(arguments: list[Path | str]) -> str:
    completed = subprocess.run(
        [os.fspath(argument) for argument in arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if completed.returncode != 0:
        fail(f"tool failed ({' '.join(map(os.fspath, arguments))}):\n{completed.stdout}")
    return completed.stdout


def validate_elf(path: Path, member: str, readelf: Path, nm: Path) -> None:
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF":
        fail(f"{member} is not ELF")
    if data[4] != 2 or data[5] != 1:
        fail(f"{member} must be little-endian ELF64")
    header = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    if header[1] != 3:  # ET_DYN
        fail(f"{member} has ELF type {header[1]}, expected ET_DYN")
    if header[2] != MACHINES[member]:
        fail(f"{member} has ELF machine {header[2]}, expected {MACHINES[member]}")
    program_offset = header[5]
    program_entry_size = header[9]
    program_count = header[10]
    if program_entry_size < 56:
        fail(f"{member} has invalid program headers")
    load_alignments: list[int] = []
    for index in range(program_count):
        offset = program_offset + index * program_entry_size
        if offset + 56 > len(data):
            fail(f"{member} has truncated program headers")
        program = struct.unpack_from("<IIQQQQQQ", data, offset)
        if program[0] == 1:  # PT_LOAD
            alignment = program[7]
            load_alignments.append(alignment)
            if (
                alignment < 16384
                or (alignment & (alignment - 1)) != 0
                or program[2] % alignment != program[3] % alignment
            ):
                fail(
                    f"{member} has non-power-of-two, incongruent, or sub-16-KiB "
                    f"PT_LOAD alignment: offset={program[2]}, vaddr={program[3]}, "
                    f"alignment={alignment}"
                )
    if not load_alignments:
        fail(f"{member} has no PT_LOAD segments")

    dynamic = run_tool([readelf, "--dynamic", "--wide", path])
    sonames = re.findall(r"\(SONAME\).*?\[([^]]+)]", dynamic)
    needed = set(re.findall(r"\(NEEDED\).*?\[([^]]+)]", dynamic))
    if sonames != ["libduckdb.so"]:
        fail(f"{member} has unexpected SONAME values: {sonames}")
    unexpected_needed = needed - ALLOWED_NEEDED
    if unexpected_needed or "libc++_shared.so" in needed:
        fail(f"{member} has unexpected needed libraries: {sorted(needed)}")
    if "(RPATH)" in dynamic or "(RUNPATH)" in dynamic:
        fail(f"{member} contains an RPATH or RUNPATH")

    symbols_output = run_tool([nm, "--dynamic", "--defined-only", path])
    symbols = {line.split()[-1] for line in symbols_output.splitlines() if line.split()}
    missing_symbols = REQUIRED_SYMBOLS - symbols
    if missing_symbols:
        fail(f"{member} is missing DuckDB C API symbols: {sorted(missing_symbols)}")
    missing_extension_symbols = REQUIRED_EXTENSION_SYMBOLS - symbols
    if missing_extension_symbols:
        fail(
            f"{member} is missing linked ICU/JSON/Parquet or static-loader symbols: "
            f"{sorted(missing_extension_symbols)}"
        )

    print(
        f"validated {member}: ELF64 machine={header[2]}, "
        f"PT_LOAD alignments={load_alignments}, needed={sorted(needed)}"
    )


def read_cache(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith(("#", "//")) or "=" not in line or ":" not in line:
            continue
        key_and_type, value = line.split("=", 1)
        key, _ = key_and_type.split(":", 1)
        result[key] = value
    return result


def validate_build_configuration(build_root: Path) -> None:
    expected_common = {
        "ANDROID_PLATFORM": "android-21",
        "ANDROID_STL": "c++_static",
        "ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES": "ON",
        "BUILD_EXTENSIONS": "icu;parquet;json",
        "BUILD_SHELL": "OFF",
        "BUILD_UNITTESTS": "OFF",
        "CMAKE_BUILD_TYPE": "Release",
        "DISABLE_EXTENSION_LOAD": "ON",
        "ENABLE_EXTENSION_AUTOLOADING": "OFF",
        "ENABLE_EXTENSION_AUTOINSTALL": "OFF",
        "EXTENSION_STATIC_BUILD": "ON",
        "SET_DUCKDB_LIBRARY_VERSION": "OFF",
    }
    for abi in ("arm64-v8a", "x86_64"):
        build_dir = build_root / abi
        cache_path = build_dir / "CMakeCache.txt"
        loader_path = build_dir / "codegen" / "src" / "generated_extension_loader.cpp"
        ninja_path = build_dir / "build.ninja"
        if not cache_path.is_file() or not loader_path.is_file() or not ninja_path.is_file():
            fail(f"missing CMake evidence for {abi} under {build_dir}")
        cache = read_cache(cache_path)
        for key, value in expected_common.items():
            if cache.get(key) != value:
                fail(f"{abi} CMake option {key}={cache.get(key)!r}; expected {value!r}")
        if cache.get("ANDROID_ABI") != abi:
            fail(f"{abi} CMake cache records ABI {cache.get('ANDROID_ABI')!r}")
        linker_flags = cache.get("CMAKE_SHARED_LINKER_FLAGS", "")
        for flag in ("max-page-size=16384", "common-page-size=16384"):
            if flag not in linker_flags:
                fail(f"{abi} CMake cache is missing linker flag {flag}")
        loader = loader_path.read_text(encoding="utf-8")
        linked_extensions = set(re.findall(r'extension=="([a-z0-9_]+)"', loader))
        if linked_extensions != STATIC_EXTENSIONS:
            fail(
                f"{abi} static extensions are {sorted(linked_extensions)}; "
                f"expected {sorted(STATIC_EXTENSIONS)}"
            )
        ninja = ninja_path.read_text(encoding="utf-8")
        if "DUCKDB_DISABLE_EXTENSION_LOAD" not in ninja:
            fail(f"{abi} compile rules do not disable runtime extension loading")
        for prohibited_define in (
            "DUCKDB_EXTENSION_AUTOLOAD_DEFAULT=1",
            "DUCKDB_EXTENSION_AUTOINSTALL_DEFAULT=1",
        ):
            if prohibited_define in ninja:
                fail(f"{abi} compile rules contain {prohibited_define}")

    prohibited_artifacts = [
        path
        for path in build_root.rglob("*")
        if path.is_file()
        and (
            path.name.endswith((".duckdb_extension", ".duckdb_extension.wasm", ".part"))
            or path.name.endswith((".tar", ".tar.gz", ".tgz", ".zip"))
        )
    ]
    if prohibited_artifacts:
        fail(f"build tree contains loadable/download artifacts: {prohibited_artifacts}")


def validate_archive_binaries(archive: Path, ndk: Path) -> None:
    readelf, nm = locate_llvm_tools(ndk)
    with zipfile.ZipFile(archive, "r") as source, tempfile.TemporaryDirectory() as temp:
        temp_root = Path(temp)
        for member in MEMBERS:
            target = temp_root.joinpath(*member.split("/"))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read(member))
            validate_elf(target, member, readelf, nm)


def main() -> int:
    args = parse_args()
    temporary_archive: Path | None = None
    try:
        if args.create:
            temporary_archive = create_archive(args.archive, args.library_root)
            archive_to_validate = temporary_archive
        else:
            archive_to_validate = args.archive
        if not archive_to_validate.is_file():
            fail(f"archive does not exist: {archive_to_validate}")
        validate_zip_structure(archive_to_validate)
        validate_archive_binaries(archive_to_validate, args.ndk)
        if args.build_root is not None:
            validate_build_configuration(args.build_root)
        if temporary_archive is not None:
            os.replace(temporary_archive, args.archive)
            temporary_archive = None
    except (OSError, subprocess.SubprocessError, zipfile.BadZipFile, ValidationError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    finally:
        if temporary_archive is not None:
            try:
                temporary_archive.unlink()
            except FileNotFoundError:
                pass
    print(f"validated {args.archive}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
