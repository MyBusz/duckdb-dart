param (
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedWrapperCommit,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Build", "Clean")]
    [string]$Command = "Build"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$ExpectedDuckDBCommit = "68d7555f68bd25c1a251ccca2e6338949c33986a"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$SourceDirectory = Join-Path $RepositoryRoot "vendor\duckdb"
$BuildRoot = Join-Path $PSScriptRoot ".build"
$BuildDirectory = Join-Path $BuildRoot "release"
$Generator = "Visual Studio 17 2022"

function Assert-NativeSuccess {
    param ([string]$Description)
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Require-Command {
    param ([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool not found: $Name"
    }
}

if ($Command -eq "Clean") {
    if (Test-Path -LiteralPath $BuildRoot) {
        Remove-Item -LiteralPath $BuildRoot -Recurse -Force
    }
    Write-Host "Removed ignored build directory: $BuildRoot"
    exit 0
}

Require-Command "git"
Require-Command "cmake"
Require-Command "python"

if ($PSVersionTable.PSVersion -lt [Version]"5.1") {
    throw "Windows PowerShell 5.1 or PowerShell 7 or newer is required"
}
if (-not [Environment]::Is64BitOperatingSystem) {
    throw "Windows x64 build requires a 64-bit operating system"
}
if (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory "CMakeLists.txt") -PathType Leaf)) {
    throw "Pinned DuckDB submodule is absent: $SourceDirectory"
}
if ($ExpectedWrapperCommit -cnotmatch "^[0-9a-f]{40}$") {
    throw "ExpectedWrapperCommit must be a lowercase 40-character Git commit"
}

$ActualWrapperCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
Assert-NativeSuccess "Wrapper revision inspection"
if ($ActualWrapperCommit -cne $ExpectedWrapperCommit) {
    throw "Wrapper commit $ActualWrapperCommit does not match required $ExpectedWrapperCommit"
}
$WrapperChanges = (& git -C $RepositoryRoot status --porcelain=v1 `
        --untracked-files=all --ignore-submodules=none | Out-String).Trim()
Assert-NativeSuccess "Wrapper worktree inspection"
if ($WrapperChanges) {
    throw "Wrapper repository has tracked, staged, or untracked changes"
}

$ActualCommit = (& git -C $SourceDirectory rev-parse HEAD).Trim()
Assert-NativeSuccess "DuckDB revision inspection"
if ($ActualCommit -ne $ExpectedDuckDBCommit) {
    throw "DuckDB commit $ActualCommit does not match $ExpectedDuckDBCommit"
}
$SourceChanges = (& git -C $SourceDirectory status --porcelain=v1 `
        --untracked-files=all --ignored | Out-String).Trim()
Assert-NativeSuccess "DuckDB worktree inspection"
if ($SourceChanges) {
    throw "DuckDB submodule has tracked, staged, untracked, or ignored changes"
}

$CMakeVersionOutput = (& cmake --version | Out-String).Trim()
Assert-NativeSuccess "CMake version inspection"
if ($CMakeVersionOutput -notmatch "cmake version ([0-9]+)\.([0-9]+)") {
    throw "Could not parse CMake version: $CMakeVersionOutput"
}
if (([int]$Matches[1] -lt 3) -or
    (([int]$Matches[1] -eq 3) -and ([int]$Matches[2] -lt 15))) {
    throw "CMake 3.15 or newer is required for static MSVC runtime selection"
}
$PythonVersionOutput = (& python --version 2>&1 | Out-String).Trim()
Assert-NativeSuccess "Python version inspection"
if ($PythonVersionOutput -notmatch "Python ([0-9]+)\.([0-9]+)") {
    throw "Python 3.10 or newer is required: $PythonVersionOutput"
}
$PythonMajor = [int]$Matches[1]
$PythonMinor = [int]$Matches[2]
if (($PythonMajor -lt 3) -or
    (($PythonMajor -eq 3) -and ($PythonMinor -lt 10))) {
    throw "Python 3.10 or newer is required: $PythonVersionOutput"
}

$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $VsWhere -PathType Leaf)) {
    throw "Visual Studio locator not found: $VsWhere"
}
$VsInstall = (& $VsWhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath | Out-String).Trim()
Assert-NativeSuccess "Visual Studio inspection"
if (-not $VsInstall) {
    throw "Visual Studio 2022 with the MSVC x64 tools is required"
}
$VsInstallationVersion = (& $VsWhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationVersion | Out-String).Trim()
Assert-NativeSuccess "Visual Studio version inspection"
if (-not $VsInstallationVersion -or
    ([Version]$VsInstallationVersion).Major -ne 17) {
    throw "Visual Studio 2022 version 17 is required: $VsInstallationVersion"
}

Write-Host "Wrapper source: $ActualWrapperCommit"
Write-Host "DuckDB source: $ActualCommit"
Write-Host "Tool: $($CMakeVersionOutput.Split([Environment]::NewLine)[0])"
Write-Host "Tool: $PythonVersionOutput"
Write-Host "Tool: PowerShell $($PSVersionTable.PSVersion)"
Write-Host "Tool: Visual Studio $VsInstallationVersion at $VsInstall"

if (Test-Path -LiteralPath $BuildRoot) {
    Remove-Item -LiteralPath $BuildRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null

$ConfigureArguments = @(
    "-S", $SourceDirectory,
    "-B", $BuildDirectory,
    "-G", $Generator,
    "-A", "x64",
    "-DCMAKE_CONFIGURATION_TYPES=Release",
    "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
    "-DBUILD_EXTENSIONS=icu;parquet;json",
    "-DEXTENSION_STATIC_BUILD=ON",
    "-DBUILD_SHELL=OFF",
    "-DBUILD_UNITTESTS=OFF",
    "-DENABLE_UNITTEST_CPP_TESTS=OFF",
    "-DDISABLE_EXTENSION_LOAD=ON",
    "-DENABLE_EXTENSION_AUTOLOADING=OFF",
    "-DENABLE_EXTENSION_AUTOINSTALL=OFF",
    "-DEXPORT_DLL_SYMBOLS=ON",
    "-DSET_DUCKDB_LIBRARY_VERSION=OFF",
    "-DDUCKDB_EXPLICIT_PLATFORM=windows_amd64",
    "-DOVERRIDE_GIT_DESCRIBE=v1.4.2"
)
$ConfigureOutput = & cmake @ConfigureArguments 2>&1
$ConfigureExitCode = $LASTEXITCODE
$ConfigureOutput | ForEach-Object { Write-Host $_ }
if ($ConfigureExitCode -ne 0) {
    throw "DuckDB CMake configuration failed with exit code $ConfigureExitCode"
}
$LinkedLine = ($ConfigureOutput | Where-Object {
        "$_" -match "Extensions linked into DuckDB:"
    } | Select-Object -Last 1 | Out-String).Trim()
foreach ($Extension in @("icu", "parquet", "json")) {
    if ($LinkedLine -notmatch "(^|[^A-Za-z0-9_])$Extension([^A-Za-z0-9_]|$)") {
        throw "$Extension was not reported as statically linked"
    }
}

$CompilerFile = Get-ChildItem -Path (Join-Path $BuildDirectory "CMakeFiles") `
    -Filter "CMakeCXXCompiler.cmake" -Recurse | Select-Object -First 1
if (-not $CompilerFile) {
    throw "CMake compiler identity file was not generated"
}
$CompilerIdentity = Get-Content -LiteralPath $CompilerFile.FullName | Out-String
if ($CompilerIdentity -notmatch 'CMAKE_CXX_COMPILER_ID "MSVC"') {
    throw "CMake did not select MSVC"
}
if ($CompilerIdentity -notmatch 'CMAKE_CXX_COMPILER_VERSION "([^"]+)"') {
    throw "Could not determine the MSVC compiler version"
}
$MsvcVersion = [Version]$Matches[1]
if ($MsvcVersion -lt [Version]"19.30") {
    throw "MSVC 19.30 or newer from Visual Studio 2022 is required"
}
Write-Host "Tool: MSVC $MsvcVersion"

$Cache = Get-Content -LiteralPath (Join-Path $BuildDirectory "CMakeCache.txt") -Raw
if ($Cache -notmatch '(?m)^CMAKE_MSVC_RUNTIME_LIBRARY(?::[^=]+)?=MultiThreaded\r?$') {
    throw "CMake did not retain the requested static MSVC runtime"
}

& cmake --build $BuildDirectory --config Release --target duckdb --parallel
Assert-NativeSuccess "DuckDB Release build"

$Dll = Join-Path $BuildDirectory "src\Release\duckdb.dll"
if (-not (Test-Path -LiteralPath $Dll -PathType Leaf)) {
    throw "Expected DuckDB DLL is absent: $Dll"
}
$DuckDBProject = Join-Path $BuildDirectory "src\duckdb.vcxproj"
if (-not (Test-Path -LiteralPath $DuckDBProject -PathType Leaf)) {
    throw "DuckDB Visual Studio project is absent: $DuckDBProject"
}
$DuckDBProjectContent = Get-Content -LiteralPath $DuckDBProject -Raw
if ($DuckDBProjectContent -notmatch '<RuntimeLibrary>MultiThreaded</RuntimeLibrary>' -or
    $DuckDBProjectContent -match '<RuntimeLibrary>MultiThreadedDLL</RuntimeLibrary>') {
    throw "DuckDB target is not configured for the static MSVC runtime"
}
$VcToolsVersionFile = Join-Path $VsInstall `
    "VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt"
if (-not (Test-Path -LiteralPath $VcToolsVersionFile -PathType Leaf)) {
    throw "Default MSVC toolset version file is absent: $VcToolsVersionFile"
}
$VcToolsVersion = (Get-Content -LiteralPath $VcToolsVersionFile -Raw).Trim()
$Dumpbin = Join-Path $VsInstall `
    "VC\Tools\MSVC\$VcToolsVersion\bin\Hostx64\x64\dumpbin.exe"
if (-not (Test-Path -LiteralPath $Dumpbin -PathType Leaf)) {
    throw "x64 dumpbin.exe was not found: $Dumpbin"
}
$Headers = & $Dumpbin /headers $Dll 2>&1
Assert-NativeSuccess "PE header inspection"
$Headers | ForEach-Object { Write-Host $_ }
if (($Headers | Out-String) -notmatch "8664 machine \(x64\)") {
    throw "DuckDB DLL is not an AMD64 PE image"
}
$Exports = & $Dumpbin /exports $Dll 2>&1
Assert-NativeSuccess "DLL export inspection"
if (($Exports | Out-String) -notmatch "\bduckdb_open\b") {
    throw "duckdb_open is not exported from duckdb.dll"
}
$Dependents = & $Dumpbin /dependents $Dll 2>&1
Assert-NativeSuccess "DLL dependency inspection"
$DependentNames = @($Dependents | ForEach-Object {
        if ("$_" -match '^\s+([A-Za-z0-9_.-]+\.dll)\s*$') {
            $Matches[1].ToUpperInvariant()
        }
    } | Sort-Object -Unique)
if ($DependentNames.Count -eq 0) {
    throw "DUMPBIN dependency output did not contain any parseable DLL names"
}
$AllowedDependents = @(
    "ADVAPI32.DLL",
    "BCRYPT.DLL",
    "KERNEL32.DLL",
    "OLE32.DLL",
    "RSTRMGR.DLL",
    "SHELL32.DLL",
    "USER32.DLL",
    "WS2_32.DLL"
)
$UnexpectedDependents = @($DependentNames | Where-Object {
        $AllowedDependents -notcontains $_
    })
if ($UnexpectedDependents.Count -ne 0) {
    throw "DuckDB DLL has non-allowlisted dependencies: $($UnexpectedDependents -join ', ')"
}
Write-Host "DuckDB DLL exports:"
$Exports | Where-Object { "$_" -match "\bduckdb_(open|connect|query)\b" } |
    ForEach-Object { Write-Host $_ }
Write-Host "DuckDB DLL dependencies:"
$DependentNames | ForEach-Object { Write-Host "  $_" }

$ResolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $OutputDirectory)
New-Item -ItemType Directory -Path $ResolvedOutput -Force | Out-Null
$ArchiveName = "duckdb-windows-x64.zip"
$PackageStage = Join-Path $ResolvedOutput ".$ArchiveName.$PID.$([Guid]::NewGuid().ToString('N')).stage"
New-Item -ItemType Directory -Path $PackageStage | Out-Null
try {
    & python (Join-Path $PSScriptRoot "package_zip.py") $Dll $PackageStage
    Assert-NativeSuccess "Windows staged package creation"
    $StagedArchive = Join-Path $PackageStage $ArchiveName

    & (Join-Path $PSScriptRoot "SmokeTest.ps1") -ArchivePath $StagedArchive

    & python (Join-Path $PSScriptRoot "package_zip.py") `
        --publish $StagedArchive $ResolvedOutput
    Assert-NativeSuccess "Windows atomic package publication"
} finally {
    if (Test-Path -LiteralPath $PackageStage) {
        Remove-Item -LiteralPath $PackageStage -Recurse -Force
    }
}
Write-Host "Created $(Join-Path $ResolvedOutput $ArchiveName)"
