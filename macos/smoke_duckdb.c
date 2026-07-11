#define _POSIX_C_SOURCE 200809L

#include <duckdb.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct duckdb_api {
    duckdb_state (*open)(const char *, duckdb_database *);
    void (*close)(duckdb_database *);
    duckdb_state (*connect)(duckdb_database, duckdb_connection *);
    void (*disconnect)(duckdb_connection *);
    duckdb_state (*query)(duckdb_connection, const char *, duckdb_result *);
    void (*destroy_result)(duckdb_result *);
    const char *(*result_error)(duckdb_result *);
    idx_t (*row_count)(duckdb_result *);
    int64_t (*value_int64)(duckdb_result *, idx_t, idx_t);
};

static int load_symbol(void *library, const char *name, void *destination,
                       size_t destination_size) {
    void *address;
    const char *error;

    dlerror();
    address = dlsym(library, name);
    error = dlerror();
    if (error != NULL || address == NULL) {
        fprintf(stderr, "missing C API symbol %s: %s\n", name,
                error == NULL ? "unknown lookup failure" : error);
        return 1;
    }
    if (destination_size != sizeof(address)) {
        fprintf(stderr, "unsupported function pointer representation for %s\n", name);
        return 1;
    }
    memcpy(destination, &address, sizeof(address));
    return 0;
}

#define LOAD_API(library, api, field, symbol)                                      \
    do {                                                                            \
        if (load_symbol((library), (symbol), &(api).field, sizeof((api).field))) {  \
            return 1;                                                               \
        }                                                                           \
    } while (0)

static int load_api(void *library, struct duckdb_api *api) {
    LOAD_API(library, *api, open, "duckdb_open");
    LOAD_API(library, *api, close, "duckdb_close");
    LOAD_API(library, *api, connect, "duckdb_connect");
    LOAD_API(library, *api, disconnect, "duckdb_disconnect");
    LOAD_API(library, *api, query, "duckdb_query");
    LOAD_API(library, *api, destroy_result, "duckdb_destroy_result");
    LOAD_API(library, *api, result_error, "duckdb_result_error");
    LOAD_API(library, *api, row_count, "duckdb_row_count");
    LOAD_API(library, *api, value_int64, "duckdb_value_int64");
    return 0;
}

static int execute(struct duckdb_api *api, duckdb_connection connection,
                   const char *sql) {
    duckdb_result result;
    if (api->query(connection, sql, &result) == DuckDBError) {
        fprintf(stderr, "query failed: %s\nSQL: %s\n", api->result_error(&result),
                sql);
        api->destroy_result(&result);
        return 1;
    }
    api->destroy_result(&result);
    return 0;
}

static int expect_int64(struct duckdb_api *api, duckdb_connection connection,
                        const char *sql, int64_t expected) {
    duckdb_result result;
    int failed;

    if (api->query(connection, sql, &result) == DuckDBError) {
        fprintf(stderr, "query failed: %s\nSQL: %s\n", api->result_error(&result),
                sql);
        api->destroy_result(&result);
        return 1;
    }
    failed = api->row_count(&result) != 1 ||
             api->value_int64(&result, 0, 0) != expected;
    if (failed) {
        fprintf(stderr, "query returned an unexpected value; expected %lld\nSQL: %s\n",
                (long long)expected, sql);
    }
    api->destroy_result(&result);
    return failed;
}

static int run_smoke(struct duckdb_api *api) {
    duckdb_database database = NULL;
    duckdb_connection connection = NULL;
    int failed = 0;

    if (api->open(NULL, &database) == DuckDBError ||
        api->connect(database, &connection) == DuckDBError) {
        fprintf(stderr, "could not open and connect to an in-memory DuckDB\n");
        if (connection != NULL) {
            api->disconnect(&connection);
        }
        if (database != NULL) {
            api->close(&database);
        }
        return 1;
    }

    failed |= expect_int64(
        api, connection,
        "SELECT count(*) FROM duckdb_extensions() "
        "WHERE extension_name IN ('icu', 'parquet', 'json') AND loaded",
        3);
    failed |= expect_int64(
        api, connection,
        "SELECT count(*) FROM duckdb_settings() WHERE "
        "name IN ('autoload_known_extensions', 'autoinstall_known_extensions') "
        "AND value = 'false'",
        2);
    failed |= expect_int64(
        api, connection,
        "SELECT CAST(json_extract('{\"answer\": 42}', '$.answer') AS BIGINT)",
        42);
    failed |= expect_int64(
        api, connection,
        "SELECT count(*) FROM (SELECT icu_sort_key('resume', 'en_US') AS sort_value) "
        "WHERE sort_value IS NOT NULL",
        1);
    failed |= execute(api, connection,
                      "COPY (SELECT 42 AS answer) TO 'smoke.parquet' "
                      "(FORMAT parquet)");
    failed |= expect_int64(api, connection,
                           "SELECT answer FROM read_parquet('smoke.parquet')", 42);

    api->disconnect(&connection);
    api->close(&database);
    return failed;
}

int main(int argc, char **argv) {
    struct duckdb_api api = {0};
    void *library;
    char temporary_template[] = "/tmp/dart-duckdb-macos-smoke.XXXXXX";
    char *temporary_directory;
    int original_directory = -1;
    mode_t previous_umask;
    int failed = 1;

    if (argc != 2 || argv[1][0] != '/') {
        fprintf(stderr, "usage: %s /absolute/path/to/libduckdb.dylib\n", argv[0]);
        return 2;
    }
    library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }

    if (load_api(library, &api)) {
        dlclose(library);
        return 1;
    }

    previous_umask = umask(0077);
    temporary_directory = mkdtemp(temporary_template);
    umask(previous_umask);
    if (temporary_directory == NULL) {
        fprintf(stderr, "mkdtemp failed: %s\n", strerror(errno));
        dlclose(library);
        return 1;
    }
    original_directory = open(".", O_RDONLY);
    if (original_directory < 0 || chdir(temporary_directory) != 0) {
        fprintf(stderr, "could not enter private temporary directory: %s\n",
                strerror(errno));
        goto cleanup;
    }

    failed = run_smoke(&api);
    if (unlink("smoke.parquet") != 0 && errno != ENOENT) {
        fprintf(stderr, "could not remove temporary Parquet file: %s\n",
                strerror(errno));
        failed = 1;
    }

cleanup:
    if (original_directory >= 0) {
        if (fchdir(original_directory) != 0) {
            failed = 1;
        }
        close(original_directory);
    }
    if (rmdir(temporary_directory) != 0) {
        fprintf(stderr, "could not remove temporary directory: %s\n",
                strerror(errno));
        failed = 1;
    }
    if (dlclose(library) != 0) {
        fprintf(stderr, "dlclose failed: %s\n", dlerror());
        failed = 1;
    }
    if (!failed) {
        printf("macOS DuckDB runtime smoke passed (JSON, ICU, Parquet, settings)\n");
    }
    return failed;
}
