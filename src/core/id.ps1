function New-PwxSequenceId {
    param([string]$Prefix)
    $cfg = Get-PwxConfig
    $metaDir = Join-Path $cfg.WorkspacePath '_meta'
    New-PwxDirectory -Path $metaDir | Out-Null
    $seqFile = Join-Path $metaDir 'sequences.json'
    $lock = Enter-PwxFileLock -Path (Join-Path $metaDir 'sequences.lock')
    try {
        $seq = @{}
        if (Test-Path -LiteralPath $seqFile) {
            $loaded = Get-PwxJsonFile -Path $seqFile
            if ($null -ne $loaded) {
                foreach ($p in $loaded.PSObject.Properties) {
                    $seq[$p.Name] = [int]$p.Value
                }
            }
        }
        $next = 1
        if ($null -ne $seq.$Prefix) {
            $next = [int]$seq.$Prefix + 1
        }
        $seq.$Prefix = $next
        Set-PwxJsonFile -Path $seqFile -Object $seq | Out-Null
        return ('{0}-{1:D4}' -f $Prefix, $next)
    }
    finally {
        Exit-PwxFileLock $lock
    }
}

function Get-PwxClientId {
    return (New-PwxSequenceId -Prefix 'C')
}

function Get-PwxJobId {
    return (New-PwxSequenceId -Prefix 'J')
}

function Get-PwxOutboxId {
    return (New-PwxSequenceId -Prefix 'M')
}