#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <expected-wrapper-source-commit-S> <output-directory>" >&2
  echo "DuckDB source is pinned in vendor/duckdb; this command never fetches it." >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$script_dir/build_duckdb.sh" "$1" "$2"
