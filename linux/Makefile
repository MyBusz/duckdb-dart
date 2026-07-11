.PHONY: all release clean help

LINUX_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

all: release

release:
	@test -n "$(OUTPUT_DIR)" || \
		(echo "OUTPUT_DIR is required" >&2; exit 2)
	@test -n "$(EXPECTED_WRAPPER_COMMIT)" || \
		(echo "EXPECTED_WRAPPER_COMMIT is required" >&2; exit 2)
	bash "$(LINUX_DIR)/build_duckdb.sh" "$(EXPECTED_WRAPPER_COMMIT)" "$(OUTPUT_DIR)"

clean:
	rm -rf "$(LINUX_DIR)/.build"

help:
	@echo "make release EXPECTED_WRAPPER_COMMIT=<S> OUTPUT_DIR=/absolute/or/relative/output"
