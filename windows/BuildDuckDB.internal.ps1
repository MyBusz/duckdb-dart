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
& (Join-Path $PSScriptRoot "BuildDuckDB.ps1") `
    -OutputDirectory $OutputDirectory `
    -ExpectedWrapperCommit $ExpectedWrapperCommit `
    -Command $Command
