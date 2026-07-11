"""Create the restricted ZIP form accepted by the native artifact contract."""

from __future__ import annotations

import hashlib
import os
import re
import stat
import struct
import sys
import zipfile
from pathlib import Path, PurePosixPath


MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_MEMBER_BYTES = 256 * 1024 * 1024
MAX_EXPANDED_BYTES = 1024 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 64
MAX_COMPRESSION_RATIO = 200
MAX_CENTRAL_DIRECTORY_BYTES = 1024 * 1024
MAX_NAME_BYTES = 4096


def fail(message: str) -> None:
    raise SystemExit(f"create_contract_zip.py: {message}")


def normalized_name(value: str) -> str:
    try:
        value.encode("ascii")
    except UnicodeEncodeError:
        fail(f"member name is not ASCII: {value!r}")
    if any(ord(character) < 0x20 or ord(character) > 0x7E for character in value):
        fail(f"member name is not printable ASCII: {value!r}")
    path = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or re.match(r"^[A-Za-z]:", value)
        or "\\" in value
        or path.is_absolute()
        or any(part in ("", ".", "..") for part in value.split("/"))
    ):
        fail(f"member name is not normalized: {value!r}")
    return value


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def verify_archive(
    archive: Path, root: Path, expected_names: list[str], expected_digests: dict[str, str]
) -> None:
    if len(expected_names) != len({name.lower() for name in expected_names}):
        fail("duplicate or case-colliding member name")
    data = archive.read_bytes()
    if not data or len(data) > MAX_ARCHIVE_BYTES:
        fail("archive size exceeds the 512 MiB contract limit")
    if len(data) < 22 or data[-22:-18] != b"PK\x05\x06":
        fail("archive has no exact, comment-free end record")
    disk, central_disk, disk_entries, entries, central_size, central_offset, comment = (
        struct.unpack_from("<HHHHIIH", data, len(data) - 18)
    )
    if (disk, central_disk, disk_entries, entries, comment) != (
        0,
        0,
        len(expected_names),
        len(expected_names),
        0,
    ):
        fail("archive uses comments, multiple disks, ZIP64, or an unexpected entry count")
    if entries <= 0 or entries > MAX_ARCHIVE_ENTRIES:
        fail("archive entry count exceeds the 64-entry contract limit")
    if central_size <= 0 or central_size > MAX_CENTRAL_DIRECTORY_BYTES:
        fail("central directory exceeds the contract limit")
    if central_offset + central_size != len(data) - 22:
        fail("central directory is not contiguous with the end record")
    if central_offset >= 20 and data[central_offset - 20 : central_offset - 16] == b"PK\x06\x07":
        fail("ZIP64 locator is present")

    names: list[str] = []
    folded_names: set[str] = set()
    expanded_size = 0
    next_local_offset = 0
    position = central_offset
    for _ in range(entries):
        if data[position : position + 4] != b"PK\x01\x02":
            fail("malformed central directory")
        version_needed, flags, method = struct.unpack_from("<HHH", data, position + 6)
        crc = struct.unpack_from("<I", data, position + 16)[0]
        compressed_size, uncompressed_size = struct.unpack_from("<II", data, position + 20)
        name_size, extra_size, comment_size = struct.unpack_from("<HHH", data, position + 28)
        external_attributes = struct.unpack_from("<I", data, position + 38)[0]
        local_offset = struct.unpack_from("<I", data, position + 42)[0]
        if name_size <= 0 or name_size > MAX_NAME_BYTES:
            fail("member name exceeds the contract limit")
        try:
            name = data[position + 46 : position + 46 + name_size].decode("ascii")
        except UnicodeDecodeError:
            fail("member name is not ASCII")
        normalized_name(name)
        if name.lower() in folded_names:
            fail("archive contains duplicate or case-colliding member names")
        folded_names.add(name.lower())
        if version_needed <= 0 or version_needed > 20:
            fail(f"unsupported required ZIP version for {name}")
        if flags & ~0x0806 or flags & 0x0001 or method not in (0, 8):
            fail(f"unsupported ZIP flags or method for {name}")
        if method == 0 and flags & 0x0006:
            fail(f"stored member uses deflate flags for {name}")
        if extra_size or comment_size:
            fail(f"extra fields or member comments are present for {name}")
        if (
            compressed_size <= 0
            or uncompressed_size <= 0
            or compressed_size == 0xFFFFFFFF
            or uncompressed_size == 0xFFFFFFFF
            or uncompressed_size > MAX_MEMBER_BYTES
            or uncompressed_size > compressed_size * MAX_COMPRESSION_RATIO
            or (method == 0 and compressed_size != uncompressed_size)
        ):
            fail(f"member sizes are outside the contract limits for {name}")
        expanded_size += uncompressed_size
        if expanded_size > MAX_EXPANDED_BYTES:
            fail("expanded archive size exceeds the 1 GiB contract limit")
        unix_type = (external_attributes >> 16) & 0xF000
        if external_attributes & 0x10 or unix_type != stat.S_IFREG:
            fail(f"member is not encoded as a regular file: {name}")
        if local_offset != next_local_offset:
            fail(f"local records are overlapping or non-contiguous before {name}")
        if data[local_offset : local_offset + 4] != b"PK\x03\x04":
            fail(f"missing local header for {name}")
        (
            local_version,
            local_flags,
            local_method,
            _local_time,
            _local_date,
            local_crc,
            local_compressed_size,
            local_uncompressed_size,
            local_name_size,
            local_extra_size,
        ) = struct.unpack_from("<5H3I2H", data, local_offset + 4)
        local_name = data[local_offset + 30 : local_offset + 30 + local_name_size]
        if local_flags & 0x0009 or local_extra_size:
            fail(f"local header uses descriptors, encryption, or extra fields for {name}")
        if (
            local_version != version_needed
            or local_flags != flags
            or local_method != method
            or local_crc != crc
            or local_compressed_size != compressed_size
            or local_uncompressed_size != uncompressed_size
            or local_name != name.encode("ascii")
        ):
            fail(f"local and central metadata differ for {name}")
        next_local_offset = local_offset + 30 + local_name_size + compressed_size
        names.append(name)
        position += 46 + name_size + extra_size + comment_size
    if (
        position != central_offset + central_size
        or next_local_offset != central_offset
        or names != expected_names
    ):
        fail("archive member order or central directory length is unexpected")

    with zipfile.ZipFile(archive, "r") as source_zip:
        if source_zip.comment or source_zip.testzip() is not None:
            fail("archive content failed comment or CRC validation")
        for name in names:
            digest = hashlib.sha256()
            with source_zip.open(name, "r") as member:
                while block := member.read(1024 * 1024):
                    digest.update(block)
            if digest.hexdigest() != expected_digests[name]:
                fail(f"archive content differs from staged source: {name}")
            if file_digest(root.joinpath(*name.split("/"))) != expected_digests[name]:
                fail(f"staged source changed during archive creation: {name}")


def main() -> None:
    if len(sys.argv) < 4:
        fail("usage: create_contract_zip.py <archive> <root> <member> [<member> ...]")
    archive = Path(sys.argv[1]).resolve()
    root = Path(sys.argv[2]).resolve()
    names = [normalized_name(value) for value in sys.argv[3:]]
    if len(names) != len(set(names)) or len(names) != len({name.lower() for name in names}):
        fail("duplicate or case-colliding member name")
    if len(names) > MAX_ARCHIVE_ENTRIES:
        fail("archive entry count exceeds the 64-entry contract limit")

    files: list[tuple[str, Path, os.stat_result]] = []
    expanded_size = 0
    expected_digests: dict[str, str] = {}
    for name in names:
        source = root.joinpath(*name.split("/"))
        metadata = source.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"member is missing, a symlink, or not a regular file: {name}")
        if metadata.st_size <= 0 or metadata.st_size > MAX_MEMBER_BYTES:
            fail(f"member exceeds the 256 MiB contract limit: {name}")
        expanded_size += metadata.st_size
        if expanded_size > MAX_EXPANDED_BYTES:
            fail("expanded archive size exceeds the 1 GiB contract limit")
        files.append((name, source, metadata))
        expected_digests[name] = file_digest(source)

    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary = archive.with_name(f".{archive.name}.tmp")
    temporary.unlink(missing_ok=True)
    try:
        with zipfile.ZipFile(
            temporary,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
            allowZip64=False,
        ) as output:
            output.comment = b""
            for name, source, metadata in files:
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                permissions = 0o755 if metadata.st_mode & stat.S_IXUSR else 0o644
                info.external_attr = (stat.S_IFREG | permissions) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                info.extra = b""
                info.comment = b""
                with source.open("rb") as source_file, output.open(info, "w", force_zip64=False) as member:
                    while block := source_file.read(1024 * 1024):
                        member.write(block)
        verify_archive(temporary, root, names, expected_digests)
        os.replace(temporary, archive)
        verify_archive(archive, root, names, expected_digests)
        print(f"Validated restricted ZIP structure and content: {archive}")
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
