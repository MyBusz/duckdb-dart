OUTPUT_DIR ?=
EXPECTED_WRAPPER_COMMIT ?=

.PHONY: all package release check-local help

all: package

package release:
	@test -n "$(OUTPUT_DIR)" || { echo "OUTPUT_DIR is required" >&2; exit 2; }
	@test -n "$(EXPECTED_WRAPPER_COMMIT)" || { echo "EXPECTED_WRAPPER_COMMIT (source S) is required" >&2; exit 2; }
	bash ./build_duckdb.sh "$(EXPECTED_WRAPPER_COMMIT)" "$(OUTPUT_DIR)"

check-local:
	@test -d ./Libraries/release/duckdb.xcframework || { \
		echo "Missing prebootstrapped ios/Libraries/release/duckdb.xcframework" >&2; \
		exit 2; \
	}

help:
	@printf '%s\n' \
		'make package EXPECTED_WRAPPER_COMMIT=<S> OUTPUT_DIR=/fresh/output/path' \
		'make check-local'
