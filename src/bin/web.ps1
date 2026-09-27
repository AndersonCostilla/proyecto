param(
    [int]$Port = 8787,
    [switch]$Dev
)

$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
. $bootstrap
Start-PwxWebServer -Port $Port -DevMode:$Dev
