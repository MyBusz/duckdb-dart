# Third-Party Notices and Provenance

## DuckDB.dart wrapper

This repository is derived from the TigerEyeLabs
[`duckdb-dart`](https://github.com/TigerEyeLabs/duckdb-dart) wrapper at commit
`9643f1116ccbc76f7aaf35da62014b49e963770d`. The wrapper is distributed under
the MIT License preserved in the repository root [`LICENSE`](LICENSE) file.

## MyBusz patch layer

MyBusz changes are maintained as a patch layer on top of that exact wrapper
baseline. Their provenance is recorded in this repository's Git history; the
upstream wrapper license and copyright notice remain unchanged.

## DuckDB

DuckDB v1.4.2 is tracked as the `vendor/duckdb` submodule at exact commit
`68d7555f68bd25c1a251ccca2e6338949c33986a`. Archive consumers can find an
included copy of the DuckDB license at
[`licenses/duckdb/LICENSE`](licenses/duckdb/LICENSE). The source submodule also
retains its original license at
[`vendor/duckdb/LICENSE`](vendor/duckdb/LICENSE).
