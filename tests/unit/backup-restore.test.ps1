Run-PwxTest -Name 'backup restore: bundle dentro del store aborta con BACKUP_RESTORE_BUNDLE_DENTRO_DEL_STORE' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        # Bundle DENTRO del workspace: la guarda debe abortar antes de staging/swap
        $env:PWX_BACKUP_DIR = Join-Path $ws '_backups'
        $sep = [string][System.IO.Path]::DirectorySeparatorChar
        New-PwxDirectory -Path $ws | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $ws 'main.txt'), 'contenido', (New-Object System.Text.UTF8Encoding($false)))
        $b = New-PwxBackup -Label 'dentro'
        $hashBefore = Get-PwxSha256 -Path (Join-Path $ws 'main.txt')

        $err = $null
        try {
            Restore-PwxBackup -Path $b.path -Force | Out-Null
        }
        catch {
            $err = $_.Exception.Message
        }
        Assert-PwxNotNull $err 'debe fallar con el bundle dentro del store'
        Assert-PwxTrue ($err -like '*BACKUP_RESTORE_BUNDLE_DENTRO_DEL_STORE*') ('codigo de guarda; obtuvo: ' + $err)

        Assert-PwxEqual $hashBefore (Get-PwxSha256 -Path (Join-Path $ws 'main.txt')) 'store intacto'
        $parent = Split-Path -Parent $ws
        $leaf = Split-Path -Leaf $ws
        $siblings = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like ($leaf + '.pre-restore-*') -or $_.Name -like ($leaf + '.restore-tmp-*')
        })
        Assert-PwxEqual 0 $siblings.Count 'sin tmp/pre: aborto antes de tocar nada'
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}

Run-PwxTest -Name 'backup restore: bundle que no verifica aborta con BACKUP_RESTORE_VERIFY_FAILED' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        $env:PWX_BACKUP_DIR = Join-Path (Split-Path -Parent $ws) ('pwx-bk-' + [guid]::NewGuid().ToString('N'))
        $sep = [string][System.IO.Path]::DirectorySeparatorChar
        New-PwxDirectory -Path $ws | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $ws 'main.txt'), 'contenido', (New-Object System.Text.UTF8Encoding($false)))
        $b = New-PwxBackup -Label 'roto'
        $hashBefore = Get-PwxSha256 -Path (Join-Path $ws 'main.txt')

        # Tamper al bundle: verify debe fallar ANTES de cualquier movimiento
        $target = Join-Path $b.path ('store' + $sep + 'main.txt')
        $bytes = [System.IO.File]::ReadAllBytes($target)
        $bytes[0] = $bytes[0] -bxor 0xFF
        [System.IO.File]::WriteAllBytes($target, $bytes)

        $err = $null
        try {
            Restore-PwxBackup -Path $b.path -Force | Out-Null
        }
        catch {
            $err = $_.Exception.Message
        }
        Assert-PwxNotNull $err 'debe fallar con bundle invalido'
        Assert-PwxTrue ($err -like '*BACKUP_RESTORE_VERIFY_FAILED*') ('codigo VERIFY_FAILED; obtuvo: ' + $err)
        Assert-PwxTrue ($err -like '*BACKUP_HASH_MISMATCH*') ('debe listar el problema de hash; obtuvo: ' + $err)

        Assert-PwxEqual $hashBefore (Get-PwxSha256 -Path (Join-Path $ws 'main.txt')) 'store intacto'
        $parent = Split-Path -Parent $ws
        $leaf = Split-Path -Leaf $ws
        $siblings = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like ($leaf + '.pre-restore-*') -or $_.Name -like ($leaf + '.restore-tmp-*')
        })
        Assert-PwxEqual 0 $siblings.Count 'sin tmp/pre creados'
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}
