param(
    [int]$Port = 8787
)

$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
. $bootstrap
Start-PwxWebServer -Port $Port
