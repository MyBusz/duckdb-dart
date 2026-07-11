#!/usr/bin/env python3

import os
import stat
import struct
import sys
import zipfile
from pathlib import Path

MEMBER_NAME = "libduckdb.so"
ARCHIVE_NAME = "duckdb-linux-x86_64.zip"


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def validate_archive(path: Path) -> None:
    data = path.read_bytes()
    if len(data) < 22 or data[-22:-18] != b"PK\x05\x06":
        fail("EOCD is not the final comment-free record")
    disk, central_disk, disk_entries, entries, central_size, central_offset, comment = (
        struct.unpack_from("<HHHHIIH", data, len(data) - 18)
    )
    if (disk, central_disk, disk_entries, entries, comment) != (0, 0, 1, 1, 0):
        fail("archive must be single-disk, single-member, and comment-free")
    if central_offset + central_size != len(data) - 22:
        fail("central directory is not contiguous with EOCD")

    if data[:4] != b"PK\x03\x04" or data[central_offset : central_offset + 4] != b"PK\x01\x02":
        fail("invalid local or central header")
    local = struct.unpack_from("<5H3I2H", data, 4)
    central = struct.unpack_from("<6H3I5H2I", data, central_offset + 4)
    (
        local_version,
        local_flags,
        local_method,
        _local_time,
        _local_date,
        local_crc,
        local_csize,
        local_size,
        local_name_len,
        local_extra_len,
    ) = local
    (
        _made_by,
        central_version,
        central_flags,
        central_method,
        _time,
        _date,
        central_crc,
        central_csize,
        central_uncompressed,
        central_name_len,
        central_extra_len,
        central_comment_len,
        central_disk_start,
        _internal_attributes,
        external_attributes,
        local_offset,
    ) = central
    name = data[30 : 30 + local_name_len]
    central_name = data[
        central_offset + 46 : central_offset + 46 + central_name_len
    ]
    if name != MEMBER_NAME.encode("ascii") or central_name != name:
        fail("member name is not exact normalized ASCII")
    if local_extra_len or central_extra_len or central_comment_len:
        fail("ZIP extra fields and member comments are forbidden")
    if local_flags & 0x09 or central_flags & 0x09:
        fail("encryption and data descriptors are forbidden")
    if local_method != zipfile.ZIP_DEFLATED or central_method != local_method:
        fail("unexpected compression method")
    if local_version > 20 or central_version > 20:
        fail("unexpected required ZIP version")
    if (local_crc, local_csize, local_size) != (
        central_crc,
        central_csize,
        central_uncompressed,
    ):
        fail("local and central CRC or sizes differ")
    if local_offset != 0 or central_disk_start != 0:
        fail("invalid local offset or disk start")
    if stat.S_ISLNK((external_attributes >> 16) & 0xFFFF):
        fail("symlink member is forbidden")
    payload_end = 30 + local_name_len + local_extra_len + local_csize
    if payload_end != central_offset:
        fail("unexpected record between payload and central directory")

    with zipfile.ZipFile(path, "r") as archive:
        infos = archive.infolist()
        if len(infos) != 1 or infos[0].is_dir() or infos[0].filename != MEMBER_NAME:
            fail("archive member set is invalid")
        if archive.comment or archive.testzip() is not None:
            fail("archive comment or CRC validation failure")


def main() -> None:
    if sys.version_info < (3, 10):
        fail("Python 3.10 or newer is required")
    if len(sys.argv) != 3:
        fail(f"usage: {sys.argv[0]} LIBRARY OUTPUT_DIRECTORY")
    source = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    source_stat = source.lstat()
    if not stat.S_ISREG(source_stat.st_mode) or source.is_symlink():
        fail("source library must be a regular non-symlink file")
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / ARCHIVE_NAME
    temporary = output_dir / f".{ARCHIVE_NAME}.{os.getpid()}.tmp"
    temporary.unlink(missing_ok=True)
    try:
        info = zipfile.ZipInfo(MEMBER_NAME, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3
        info.external_attr = (stat.S_IFREG | 0o644) << 16
        with zipfile.ZipFile(
            temporary, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=False
        ) as archive:
            with source.open("rb") as input_file, archive.open(info, "w") as output_file:
                while chunk := input_file.read(1024 * 1024):
                    output_file.write(chunk)
        validate_archive(temporary)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
