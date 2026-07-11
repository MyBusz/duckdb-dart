OUTPUT_DIR ?= $(CURDIR)/dist
WORK_DIR ?= $(OUTPUT_DIR)/.android-work
JOBS ?=
SOURCE_COMMIT ?= $(DUCKDB_DART_SOURCE_COMMIT)

.PHONY: all release validate

all: release

release:
	@test -n "$(SOURCE_COMMIT)" || { echo "error: SOURCE_COMMIT must be the expected wrapper source commit S" >&2; exit 1; }
	@"$(CURDIR)/build_android.sh" --source-commit "$(SOURCE_COMMIT)" --output-dir "$(OUTPUT_DIR)" --work-dir "$(WORK_DIR)" $(if $(JOBS),--jobs "$(JOBS)",)

validate:
	@python3 "$(CURDIR)/validate_android.py" \
		--archive "$(OUTPUT_DIR)/duckdb-android-arm64-v8a-x86_64.zip" \
		--ndk "$(ANDROID_NDK_HOME)"
