param (
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$ResolvedArchive = (Resolve-Path -LiteralPath $ArchivePath).Path
if ([IO.Path]::GetExtension($ResolvedArchive) -cne ".zip") {
    throw "Packaged DuckDB smoke requires a ZIP archive: $ResolvedArchive"
}

$TempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$Stage = Join-Path $TempRoot "duckdb-windows-smoke-$PID-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $Stage | Out-Null

try {
    Expand-Archive -LiteralPath $ResolvedArchive -DestinationPath $Stage
    $Members = @(Get-ChildItem -LiteralPath $Stage -File -Recurse)
    if ($Members.Count -ne 1 -or $Members[0].Name -cne "duckdb.dll" -or
        $Members[0].DirectoryName -cne $Stage) {
        throw "Packaged DuckDB ZIP must contain only duckdb.dll at its root"
    }
    $DllPath = (Resolve-Path -LiteralPath $Members[0].FullName).Path
    if (-not [IO.Path]::IsPathRooted($DllPath)) {
        throw "Packaged DuckDB DLL path is not absolute: $DllPath"
    }

    $Source = @'
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class PackagedDuckDbSmoke {
    [DllImport("kernel32.dll", EntryPoint = "LoadLibraryW", CharSet = CharSet.Unicode,
        SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr LoadLibraryW(string path);

    [DllImport("kernel32.dll", EntryPoint = "GetProcAddress", CharSet = CharSet.Ansi,
        SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    [DllImport("kernel32.dll", EntryPoint = "FreeLibrary", SetLastError = true,
        ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeLibrary(IntPtr module);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int DuckDbOpen([MarshalAs(UnmanagedType.LPStr)] string path, out IntPtr database);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int DuckDbConnect(IntPtr database, out IntPtr connection);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int DuckDbQuery(IntPtr connection, [MarshalAs(UnmanagedType.LPStr)] string query, IntPtr result);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void DuckDbDisconnect(ref IntPtr connection);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void DuckDbClose(ref IntPtr database);

    private static T LoadFunction<T>(IntPtr module, string name) where T : class {
        IntPtr address = GetProcAddress(module, name);
        if (address == IntPtr.Zero) {
            throw new InvalidOperationException("Missing DuckDB C API export: " + name);
        }
        return (T)(object)Marshal.GetDelegateForFunctionPointer(address, typeof(T));
    }

    private static void Query(DuckDbQuery query, IntPtr connection, string description, string sql) {
        if (query(connection, sql, IntPtr.Zero) != 0) {
            throw new InvalidOperationException("DuckDB " + description + " query failed");
        }
    }

    public static void Run(string dllPath) {
        if (!Path.IsPathRooted(dllPath)) {
            throw new ArgumentException("DuckDB DLL path must be absolute", "dllPath");
        }
        IntPtr module = LoadLibraryW(dllPath);
        if (module == IntPtr.Zero) {
            throw new InvalidOperationException(
                "LoadLibraryW failed for packaged DuckDB DLL with error " + Marshal.GetLastWin32Error());
        }

        IntPtr database = IntPtr.Zero;
        IntPtr connection = IntPtr.Zero;
        string parquetPath = Path.Combine(Path.GetTempPath(), "duckdb-smoke-" + Guid.NewGuid().ToString("N") + ".parquet");
        try {
            DuckDbOpen open = LoadFunction<DuckDbOpen>(module, "duckdb_open");
            DuckDbConnect connect = LoadFunction<DuckDbConnect>(module, "duckdb_connect");
            DuckDbQuery query = LoadFunction<DuckDbQuery>(module, "duckdb_query");
            DuckDbDisconnect disconnect = LoadFunction<DuckDbDisconnect>(module, "duckdb_disconnect");
            DuckDbClose close = LoadFunction<DuckDbClose>(module, "duckdb_close");

            if (open(null, out database) != 0 || database == IntPtr.Zero) {
                throw new InvalidOperationException("duckdb_open failed");
            }
            if (connect(database, out connection) != 0 || connection == IntPtr.Zero) {
                throw new InvalidOperationException("duckdb_connect failed");
            }

            Query(query, connection, "static extension", @"
                SELECT CASE WHEN count(*) = 3 THEN 1 ELSE error('static extensions missing') END
                FROM duckdb_extensions()
                WHERE extension_name IN ('icu', 'json', 'parquet') AND loaded");
            Query(query, connection, "extension policy", @"
                SELECT CASE WHEN count(*) = 2 THEN 1 ELSE error('extension policy enabled') END
                FROM duckdb_settings()
                WHERE name IN ('autoload_known_extensions', 'autoinstall_known_extensions')
                  AND value = 'false'");
            Query(query, connection, "JSON", @"
                SELECT CASE WHEN json_extract('{""answer"":42}', '$.answer')::INTEGER = 42
                THEN 1 ELSE error('JSON smoke failed') END");
            Query(query, connection, "ICU", @"
                SELECT CASE WHEN icu_sort_key(chr(350), 'ro') IS NOT NULL
                THEN 1 ELSE error('ICU smoke failed') END");

            string escapedParquetPath = parquetPath.Replace("'", "''");
            Query(query, connection, "Parquet write",
                "COPY (SELECT 42 AS answer) TO '" + escapedParquetPath + "' (FORMAT PARQUET)");
            Query(query, connection, "Parquet read",
                "SELECT CASE WHEN (SELECT answer FROM read_parquet('" + escapedParquetPath +
                "')) = 42 THEN 1 ELSE error('Parquet smoke failed') END");

            disconnect(ref connection);
            close(ref database);
        } finally {
            if (connection != IntPtr.Zero) {
                DuckDbDisconnect disconnect = LoadFunction<DuckDbDisconnect>(module, "duckdb_disconnect");
                disconnect(ref connection);
            }
            if (database != IntPtr.Zero) {
                DuckDbClose close = LoadFunction<DuckDbClose>(module, "duckdb_close");
                close(ref database);
            }
            if (File.Exists(parquetPath)) {
                File.Delete(parquetPath);
            }
            FreeLibrary(module);
        }
    }
}
'@

    Add-Type -TypeDefinition $Source -Language CSharp
    [PackagedDuckDbSmoke]::Run($DllPath)
    Write-Host "Packaged DuckDB Windows C API smoke passed: $DllPath"
} finally {
    if (Test-Path -LiteralPath $Stage) {
        Remove-Item -LiteralPath $Stage -Recurse -Force
    }
}
