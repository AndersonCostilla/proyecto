function Add-PwxBackupSeedFile {
    param(
        [string]$Workspace,
        [string]$RelPath,
        [string]$Content
    )
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    $full = Join-Path $Workspace ($RelPath.Replace('/', $sep))
    $dir = Split-Path -Parent $full
    New-PwxDirectory -Path $dir | Out-Null
    [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

Run-PwxTest -Name 'backup: create genera bundle verificable (manifest v1, checksums, orden ordinal)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        $env:PWX_BACKUP_DIR = Join-Path $ws '_backups'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'z/inner.txt' -Content 'interno'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'B.txt' -Content 've'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'a.txt' -Content 'aito'

        $b = New-PwxBackup -Label 'prueba'
        $bundle = $b.path
        Assert-PwxTrue (Test-Path -LiteralPath $bundle) 'bundle creado'
        Assert-PwxTrue ((Split-Path -Leaf $bundle) -match '^\d{8}-\d{6}-prueba$') 'nombre <stamp>-<label>'
        Assert-PwxEqual 3 $b.file_count 'file_count del resumen'
        Assert-PwxTrue ($b.content_hash -like 'sha256:*') 'content_hash con prefijo sha256'

        $m = Get-PwxJsonFile -Path (Join-Path $bundle 'manifest.json')
        Assert-PwxEqual '1' ([string]$m.schema_version) 'schema_version string "1"'
        Assert-PwxEqual 'pwx-store-backup' $m.kind 'kind'
        Assert-PwxEqual 'store' $m.source 'source'
        Assert-PwxEqual (Get-PwxVersion) $m.pwx_version 'pwx_version'
        Assert-PwxTrue ([string]$m.created_utc -match 'Z$') 'created_utc en UTC termina en Z'
        Assert-PwxTrue ([bool]$m.complete) 'complete=true'
        Assert-PwxEqual 3 ([int]$m.file_count) 'manifest.file_count'
        Assert-PwxEqual ([int64]$b.total_bytes) ([int64]$m.total_bytes) 'total_bytes coincide con resumen'

        $paths = @($m.files | ForEach-Object { $_.path })
        Assert-PwxEqual ('store/B.txt|store/a.txt|store/z/inner.txt') ($paths -join '|') 'files en orden ordinal (B < a < z)'
        foreach ($p in $paths) {
            Assert-PwxTrue ($p -like 'store/*') "toda ruta es relativa a store/: $p"
        }
        $joinedPaths = $paths -join ' '
        Assert-PwxTrue ($joinedPaths -notlike '*_backups*') 'sin auto-inclusion de backups'
        Assert-PwxTrue ($joinedPaths -notlike '*config*' -and $joinedPaths -notlike '*.local.json*') 'sin config ni secretos'

        $ckPath = Join-Path $bundle 'checksums.sha256'
        Assert-PwxTrue (Test-Path -LiteralPath $ckPath) 'checksums.sha256 existe'
        $ckLines = @([System.IO.File]::ReadAllLines($ckPath))
        Assert-PwxEqual 4 $ckLines.Count '4 lineas (manifest.json + 3 store)'
        foreach ($l in $ckLines) {
            Assert-PwxTrue ($l -match '^[0-9A-Fa-f]{64}  \S') "linea con dos espacios: $l"
        }
        Assert-PwxTrue (($ckLines -join "`n") -like '*manifest.json*') 'checksums cubre manifest.json'

        $r = Test-PwxBackupBundle -Path $bundle
        Assert-PwxTrue $r.ok ('verify debe pasar; problemas: ' + ($r.problems -join '; '))
        Assert-PwxEqual 0 @($r.problems).Count 'sin problemas'

        $r2 = Test-PwxBackupBundle -Path ($bundle + [string][System.IO.Path]::DirectorySeparatorChar)
        Assert-PwxTrue $r2.ok ('verify con -Path bajo barra final; problemas: ' + ($r2.problems -join '; '))
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}

Run-PwxTest -Name 'backup: tamper de 1 byte en bundle -> verify falla y nombra el archivo' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        $env:PWX_BACKUP_DIR = Join-Path $ws '_backups'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'one.txt' -Content 'contenido uno'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'two.txt' -Content 'contenido dos'

        $b = New-PwxBackup
        $target = Join-Path $b.path ('store' + [string][System.IO.Path]::DirectorySeparatorChar + 'one.txt')
        $bytes = [System.IO.File]::ReadAllBytes($target)
        Assert-PwxTrue ($bytes.Length -gt 0) 'archivo con bytes'
        $bytes[0] = $bytes[0] -bxor 0xFF
        [System.IO.File]::WriteAllBytes($target, $bytes)

        $r = Test-PwxBackupBundle -Path $b.path
        Assert-PwxTrue (-not $r.ok) 'verify debe fallar tras tamper'
        $joined = @($r.problems) -join "`n"
        Assert-PwxTrue ($joined -like '*BACKUP_HASH_MISMATCH*') ('debe reportar BACKUP_HASH_MISMATCH; obtuvo: ' + $joined)
        Assert-PwxTrue ($joined -like '*store/one.txt*') 'debe nombrar el archivo alterado'
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}

Run-PwxTest -Name 'backup: archivo faltante en el bundle -> verify falla nombrandolo' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        $env:PWX_BACKUP_DIR = Join-Path $ws '_backups'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'one.txt' -Content 'uno'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'two.txt' -Content 'dos'

        $b = New-PwxBackup
        $missing = Join-Path $b.path ('store' + [string][System.IO.Path]::DirectorySeparatorChar + 'two.txt')
        Remove-Item -LiteralPath $missing -Force

        $r = Test-PwxBackupBundle -Path $b.path
        Assert-PwxTrue (-not $r.ok) 'verify debe fallar con archivo faltante'
        $joined = @($r.problems) -join "`n"
        Assert-PwxTrue ($joined -like '*BACKUP_FILE_MISSING*') ('debe reportar BACKUP_FILE_MISSING; obtuvo: ' + $joined)
        Assert-PwxTrue ($joined -like '*store/two.txt*') 'debe nombrar el archivo faltante'
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}

Run-PwxTest -Name 'backup: schema_version != "1" -> BACKUP_SCHEMA_UNSUPPORTED' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        $env:PWX_BACKUP_DIR = Join-Path $ws '_backups'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'one.txt' -Content 'uno'

        $b = New-PwxBackup
        $manifestPath = Join-Path $b.path 'manifest.json'
        $m = Get-PwxJsonFile -Path $manifestPath
        $m.schema_version = '2'
        Set-PwxJsonFile -Path $manifestPath -Object $m | Out-Null

        $r = Test-PwxBackupBundle -Path $b.path
        Assert-PwxTrue (-not $r.ok) 'verify debe rechazar schema distinto de "1"'
        $joined = @($r.problems) -join "`n"
        Assert-PwxTrue ($joined -like '*BACKUP_SCHEMA_UNSUPPORTED*') ('debe reportar BACKUP_SCHEMA_UNSUPPORTED; obtuvo: ' + $joined)
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}

Run-PwxTest -Name 'backup: content_hash estable entre dos backups consecutivos (mismo store)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        $env:PWX_BACKUP_DIR = Join-Path $ws '_backups'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'clientes/datos.json' -Content '{"id":"C-0001"}'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'secuencias.json' -Content '{"job":5}'

        $b1 = New-PwxBackup
        $b2 = New-PwxBackup
        Assert-PwxEqual $b1.content_hash $b2.content_hash 'mismo content_hash en corridas consecutivas'
        Assert-PwxEqual $b1.file_count $b2.file_count 'file_count identico (el primer bundle NO se auto-incluye)'
        Assert-PwxTrue ($b1.path -ne $b2.path) 'bundles con nombre distinto (sin colision)'

        $r1 = Test-PwxBackupBundle -Path $b1.path
        $r2 = Test-PwxBackupBundle -Path $b2.path
        Assert-PwxTrue $r1.ok ('verify bundle 1; problemas: ' + (@($r1.problems) -join '; '))
        Assert-PwxTrue $r2.ok ('verify bundle 2; problemas: ' + (@($r2.problems) -join '; '))
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}

Run-PwxTest -Name 'backup: list devuelve los bundles en orden ordinal' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        $env:PWX_BACKUP_DIR = Join-Path $ws '_backups'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'one.txt' -Content 'uno'

        Assert-PwxEqual 0 @(Get-PwxBackupList).Count 'lista vacia antes del primer backup'
        $b1 = New-PwxBackup -Label 'uno'
        $b2 = New-PwxBackup -Label 'dos'
        $items = @(Get-PwxBackupList)
        Assert-PwxEqual 2 $items.Count 'dos bundles listados'
        $names = @($items | ForEach-Object { $_.name })
        Assert-PwxTrue ($names -contains $b1.name -and $names -contains $b2.name) 'listado contiene ambos nombres'
        Assert-PwxTrue ([string]::CompareOrdinal($names[0], $names[1]) -le 0) ('orden ordinal del listado: {0} <= {1}' -f $names[0], $names[1])
        foreach ($it in $items) {
            Assert-PwxTrue ($it.content_hash -like 'sha256:*') ('content_hash presente en ' + $it.name)
            Assert-PwxTrue ([string]$it.created_utc -match 'Z$') ('created_utc UTC en ' + $it.name)
        }
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}

Run-PwxTest -Name 'backup: verify rechaza rutas fuera del bundle (path traversal)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $prevBackupDir = $env:PWX_BACKUP_DIR
    try {
        Invoke-PwxBootstrap
        $env:PWX_BACKUP_DIR = Join-Path $ws '_backups'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'one.txt' -Content 'uno'
        Add-PwxBackupSeedFile -Workspace $ws -RelPath 'two.txt' -Content 'dos'

        $b = New-PwxBackup
        $manifestPath = Join-Path $b.path 'manifest.json'
        $m = Get-PwxJsonFile -Path $manifestPath
        $m.files[0].path = 'store/../fuera.json'
        Set-PwxJsonFile -Path $manifestPath -Object $m | Out-Null

        $r = Test-PwxBackupBundle -Path $b.path
        Assert-PwxTrue (-not $r.ok) 'verify debe fallar con ruta insegura'
        $joined = @($r.problems) -join "`n"
        Assert-PwxTrue ($joined -like '*BACKUP_PATH_UNSAFE*') ('debe reportar BACKUP_PATH_UNSAFE; obtuvo: ' + $joined)
    }
    finally {
        $env:PWX_BACKUP_DIR = $prevBackupDir
    }
}
