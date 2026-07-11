#!/usr/bin/env python3

import re
import subprocess
import sys
from pathlib import Path

ALLOWED_NEEDED = {
    "ld-linux-x86-64.so.2",
    "libc.so.6",
    "libdl.so.2",
    "libgcc_s.so.1",
    "libm.so.6",
    "libpthread.so.0",
    "librt.so.1",
    "libstdc++.so.6",
}
MAXIMUM_VERSIONS = {
    "GLIBC": (2, 35),
    "GLIBCXX": (3, 4, 30),
    "CXXABI": (1, 3, 13),
}


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def inspect(*arguments: str) -> str:
    process = subprocess.run(
        arguments,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if process.returncode != 0:
        fail(f"{' '.join(arguments)} failed: {process.stderr.strip()}")
    return process.stdout


def parse_version(name: str, namespace: str) -> tuple[int, ...]:
    match = re.fullmatch(rf"{namespace}_(\d+(?:\.\d+)*)", name)
    if match is None:
        fail(f"malformed {namespace} symbol requirement: {name}")
    return tuple(int(component) for component in match.group(1).split("."))


def padded(version: tuple[int, ...], width: int) -> tuple[int, ...]:
    return version + (0,) * (width - len(version))


def validate_versions(version_info: str) -> None:
    marker = "Version needs section"
    if marker not in version_info:
        fail("ELF has no version-needs section")
    requirements = re.findall(r"\bName:\s+(\S+)", version_info.split(marker, 1)[1])
    if not requirements:
        fail("ELF version-needs section contains no requirements")

    observed: dict[str, tuple[int, ...]] = {}
    for name in requirements:
        for namespace, maximum in MAXIMUM_VERSIONS.items():
            if not name.startswith(f"{namespace}_"):
                continue
            version = parse_version(name, namespace)
            width = max(len(version), len(maximum))
            if padded(version, width) > padded(maximum, width):
                fail(f"{name} exceeds Ubuntu 22.04 maximum {namespace}_{'.'.join(map(str, maximum))}")
            current = observed.get(namespace)
            if current is None or padded(version, width) > padded(current, width):
                observed[namespace] = version
            break

    for namespace, maximum in MAXIMUM_VERSIONS.items():
        version = observed.get(namespace)
        if version is not None:
            print(f"Maximum {namespace} requirement: {namespace}_{'.'.join(map(str, version))}")
        else:
            print(f"Maximum {namespace} requirement: none (limit {'.'.join(map(str, maximum))})")


def validate_notes(notes: str) -> None:
    for line in notes.splitlines():
        lowered = line.lower()
        if "x86 feature" in lowered:
            fail(f"unintended x86 feature property: {line.strip()}")
        if "x86 isa" not in lowered:
            continue
        match = re.search(r"x86 ISA (?:needed|used):\s*(\S.*)$", line, re.IGNORECASE)
        if match is None:
            fail(f"malformed x86 ISA property: {line.strip()}")
        values = {value.strip() for value in match.group(1).split(",")}
        if values != {"x86-64-baseline"}:
            fail(f"unintended x86 ISA property: {line.strip()}")


def main() -> None:
    if sys.version_info < (3, 10):
        fail("Python 3.10 or newer is required")
    if len(sys.argv) != 2:
        fail(f"usage: {sys.argv[0]} LIBRARY")
    library = Path(sys.argv[1])
    if not library.is_file() or library.is_symlink():
        fail(f"library must be a regular non-symlink file: {library}")

    header = inspect("readelf", "-hW", str(library))
    if not re.search(r"Class:\s+ELF64\b", header):
        fail("DuckDB library is not ELF64")
    if not re.search(r"Machine:\s+Advanced Micro Devices X86-64\b", header):
        fail("DuckDB library is not x86_64")

    dynamic = inspect("readelf", "-dW", str(library))
    needed_tags = re.findall(r"\(NEEDED\)", dynamic)
    needed = re.findall(r"\(NEEDED\).*Shared library:\s*\[([^\]]+)\]", dynamic)
    if len(needed) != len(needed_tags):
        fail("malformed DT_NEEDED entry")
    unexpected = sorted(set(needed) - ALLOWED_NEEDED)
    if unexpected:
        fail(f"non-allowlisted DT_NEEDED entries: {', '.join(unexpected)}")
    sonames = re.findall(r"\(SONAME\).*Library soname:\s*\[([^\]]+)\]", dynamic)
    if sonames != ["libduckdb.so"]:
        fail(f"DuckDB SONAME must be exactly libduckdb.so, found: {sonames}")
    if re.search(r"\((?:RPATH|RUNPATH)\)", dynamic):
        fail("DuckDB library must not contain DT_RPATH or DT_RUNPATH")

    exports = inspect("nm", "-D", "--defined-only", str(library))
    for symbol in ("duckdb_open", "duckdb_connect", "duckdb_query"):
        if not re.search(rf"\b{symbol}$", exports, re.MULTILINE):
            fail(f"{symbol} is not exported")

    validate_versions(inspect("readelf", "--version-info", "-W", str(library)))
    validate_notes(inspect("readelf", "-nW", str(library)))
    print(f"Allowed DT_NEEDED: {', '.join(sorted(needed))}")
    print("Linux ELF baseline validation passed")


if __name__ == "__main__":
    main()
