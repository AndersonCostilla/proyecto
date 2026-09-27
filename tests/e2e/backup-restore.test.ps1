function Add-PwxRestoreSeed {
    param(
        [string]$Workspace,
        [string]$RelPath,
        [string]$Content
    )
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    $full = Join-Path $Workspace ($RelPath.Replace('/', $sep))
    New-PwxDirectory -Path (Split-Path -Parent $full) | Out-Null
    [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

Run-PwxTest -Name 'backup restore: roundtrip deja el store identico al bundle y preserva pre-restore' -File 'e2e\backup-restore' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        # El bundle vive FUERA del workspace (guarda BUNDLE_DENTRO_DEL_STORE)
        $env:PWX_BACKUP_DIR = Join-Path (Split-Path -Parent $ws) ('pwx-bk-' + [guid]::NewGuid().ToString('N'))
        Add-PwxRestoreSeed -Workspace $ws -RelPath 'clients/C-0001/client.json' -Content '{"id":"C-0001"}'
        Add-PwxRestoreSeed -Workspace $ws -RelPath 'sequences.json' -Content '{"job":7}'
        Add-PwxRestoreSeed -Workspace $ws -RelPath 'notas.txt' -Content 'original'

        $b = New-PwxBackup -Label 'rt'
        $manifest = Get-PwxJsonFile -Path (Join-Path $b.path 'manifest.json')

        # Mutacion: cambiar 1 archivo y crear un extra que debe desaparecer
        Add-PwxRestoreSeed -Workspace $ws -RelPath 'notas.txt' -Content 'MUTADO'
        Add-PwxRestoreSeed -Workspace $ws -RelPath 'extra.txt' -Content 'basura'

        $r = Restore-PwxBackup -Path $b.path -Force
        Assert-PwxEqual ([string]$r.workspace) ([string]$ws) 'resumen.workspace apunta al workspace actual'
        Assert-PwxNull $r.tmp_path 'tmp_path null tras el rename'
        Assert-PwxNotNull $r.pre_restore_path 'pre_restore_path presente (habia datos)'
        Assert-PwxTrue (Test-Path -LiteralPath ([string]$r.pre_restore_path)) 'pre-restore existe en disco'
        Assert-PwxEqual ([int]$manifest.file_count) ([int]$r.file_count) 'file_count del resumen'
        Assert-PwxEqual ([long]$manifest.total_bytes) ([long]$r.total_bytes) 'total_bytes del resumen'
        Assert-PwxEqual ([string]$manifest.content_hash) ([string]$r.content_hash) 'content_hash del resumen'

        # Por cada entry del manifest: sha256 del destino == sha256 del manifest
        $sep = [string][System.IO.Path]::DirectorySeparatorChar
        foreach ($entry in @($manifest.files)) {
            $rel = ([string]$entry.path).Substring('store/'.Length)
            $dest = Join-Path $ws ($rel.Replace('/', $sep))
            Assert-PwxTrue (Test-Path -LiteralPath $dest) ("existe " + $entry.path)
            Assert-PwxEqual ([string]$entry.sha256) (Get-PwxSha256 -Path $dest) ("sha256 coincide " + $entry.path)
        }

        # El extra desaparece y el store final tiene EXACTAMENTE los archivos del manifest
        Assert-PwxTrue (-not (Test-Path -LiteralPath (Join-Path $ws 'extra.txt'))) 'extra.txt ya no existe'
        $disk = @(Get-ChildItem -LiteralPath $ws -File -Recurse)
        Assert-PwxEqual ([int]$manifest.file_count) $disk.Count 'sin archivos fuera del manifest'

        # El pre-restore conserva el estado mutado (nunca se borra)
        $mutInPre = Join-Path ([string]$r.pre_restore_path) ('notas.txt'.Replace('/', $sep))
        Assert-PwxTrue (Test-Path -LiteralPath $mutInPre) 'notas.txt existe en pre-restore'
        Assert-PwxEqual 'MUTADO' ([System.IO.File]::ReadAllText($mutInPre)) 'pre-restore conserva la mutacion'
        $extraInPre = Join-Path ([string]$r.pre_restore_path) ('extra.txt'.Replace('/', $sep))
        Assert-PwxTrue (Test-Path -LiteralPath $extraInPre) 'pre-restore conserva extra.txt'
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}

Run-PwxTest -Name 'backup restore: sin -Force sobre store no vacio falla y no toca nada' -File 'e2e\backup-restore' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        $env:PWX_BACKUP_DIR = Join-Path (Split-Path -Parent $ws) ('pwx-bk-' + [guid]::NewGuid().ToString('N'))
        Add-PwxRestoreSeed -Workspace $ws -RelPath 'sequences.json' -Content '{"job":9}'
        Add-PwxRestoreSeed -Workspace $ws -RelPath 'clients/C-0001/client.json' -Content '{"id":"C-0001"}'

        $b = New-PwxBackup -Label 'guard'
        $mainFile = Join-Path $ws 'sequences.json'
        $hashBefore = Get-PwxSha256 -Path $mainFile
        $countBefore = @(Get-ChildItem -LiteralPath $ws -File -Recurse).Count

        $err = $null
        try {
            Restore-PwxBackup -Path $b.path | Out-Null
        }
        catch {
            $err = $_.Exception.Message
        }
        Assert-PwxNotNull $err 'restore sin -Force debe fallar'
        Assert-PwxTrue ($err -like '*BACKUP_RESTORE_FORCE_REQUIRED*') ('codigo BACKUP_RESTORE_FORCE_REQUIRED; obtuvo: ' + $err)

        # Nada tocado
        Assert-PwxEqual $hashBefore (Get-PwxSha256 -Path $mainFile) 'hash del archivo principal intacto'
        Assert-PwxEqual $countBefore (@(Get-ChildItem -LiteralPath $ws -File -Recurse).Count) 'cantidad de archivos intacta'
        $parent = Split-Path -Parent $ws
        $leaf = Split-Path -Leaf $ws
        $siblings = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like ($leaf + '.pre-restore-*') -or $_.Name -like ($leaf + '.restore-tmp-*')
        })
        Assert-PwxEqual 0 $siblings.Count 'sin directorios pre-restore/tmp creados'
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}
