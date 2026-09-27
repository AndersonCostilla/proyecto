# Backup verificable del store (PR-2: create/list/verify; restore en PR-3).
# Bundle = directorio en backups/<UTCSTAMP>[-label]/ con:
#   manifest.json   - enumeracion de store/** con sha256/bytes + metadata (schema v1)
#   checksums.sha256 - lineas '<sha256>  <path>' (dos espacios), rutas / y orden ordinal
#   store/**        - copia byte a byte del workspace (store)
# El backup solo incluye el store: nunca config/, ni *.local.json, ni la propia
# carpeta de backups (auto-inclusion evitada). Determinismo: dos backups
# consecutivos del mismo store comparten content_hash (no asi created_utc).

function Get-PwxBackupRootDir {
    # Raiz de bundles: env PWX_BACKUP_DIR > <repoRoot>/backups.
    # No crea el directorio (list sobre raiz inexistente = lista vacia).
    # Sin barra final: StartsWith(root + sep) del anti-auto-inclusion y del
    # assert de contencion fallarian con '.../backups/'.
    $root = $env:PWX_BACKUP_DIR
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path $global:PwxRoot 'backups'
    }
    $full = [System.IO.Path]::GetFullPath($root)
    $seps = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [char]'/')
    if ($full.Length -gt 1) { $full = $full.TrimEnd($seps) }
    return $full
}

function Get-PwxBackupContentHash {
    # Hash canonico del contenido: sha256 de la concatenacion UTF-8 de
    # "<sha256>  <path>\n" por cada archivo, con las rutas ordenadas con
    # comparador ordinal (case-sensitive). Sin archivos -> sha256('').
    param([object[]]$Files)
    $pairs = @()
    if ($Files) {
        foreach ($f in $Files) {
            if ($null -ne $f) { $pairs += , $f }
        }
    }
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $pairs) { [void]$paths.Add([string]$p.path) }
    $paths.Sort([System.StringComparer]::Ordinal)
    $text = ''
    if ($paths.Count -gt 0) {
        $byPath = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        foreach ($p in $pairs) { $byPath[[string]$p.path] = [string]$p.sha256 }
        $chunks = New-Object 'System.Collections.Generic.List[string]'
        foreach ($p in $paths) { [void]$chunks.Add(('{0}  {1}' -f $byPath[$p], $p)) }
        $text = ($chunks -join "`n") + "`n"
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return ('sha256:' + ([System.BitConverter]::ToString($digest) -replace '-', ''))
}

function New-PwxBackup {
    param([string]$Label = '')
    $srcFull = Resolve-PwxFullPath -Path (Get-PwxWorkspacePath)
    $rootFull = Get-PwxBackupRootDir
    if ($rootFull -eq $srcFull) {
        throw 'PWX_BACKUP_DIR no puede ser el propio workspace (el backup no puede respaldarse a si mismo)'
    }
    if (-not [string]::IsNullOrEmpty($Label)) {
        if ($Label -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            throw "Label invalido (se permite [A-Za-z0-9._-] sin separadores ni '..'): $Label"
        }
    }
    $stamp = ([DateTime]::UtcNow).ToString('yyyyMMdd-HHmmss')
    $baseName = if ([string]::IsNullOrEmpty($Label)) { $stamp } else { ('{0}-{1}' -f $stamp, $Label) }
    New-PwxDirectory -Path $rootFull | Out-Null
    $bundle = Join-Path $rootFull $baseName
    $suffix = 2
    while (Test-Path -LiteralPath $bundle) {
        $bundle = Join-Path $rootFull ('{0}-{1}' -f $baseName, $suffix)
        $suffix++
    }
    $bundle = New-PwxDirectory -Path $bundle
    $storeDir = Join-Path $bundle 'store'
    New-PwxDirectory -Path $storeDir | Out-Null

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $sepStr = [string]$sep
    $rootPrefix = $rootFull + $sepStr

    # 1) copia byte a byte del store (sin la raiz de backups si quedara dentro)
    if (Test-Path -LiteralPath $srcFull) {
        foreach ($f in (Get-ChildItem -LiteralPath $srcFull -File -Recurse -ErrorAction SilentlyContinue)) {
            if ($f.FullName.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $rel = Get-PwxRelativePath -BasePath $srcFull -ChildPath $f.FullName
            if (-not $rel) { continue }
            $dest = Join-Path $storeDir $rel
            $destParent = Split-Path -Parent $dest
            New-PwxDirectory -Path $destParent | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        }
    }

    # 2) enumeracion canonica de lo copiado (sobre el bundle, no sobre el origen)
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in (Get-ChildItem -LiteralPath $storeDir -File -Recurse -ErrorAction SilentlyContinue)) {
        $rel = Get-PwxRelativePath -BasePath $bundle -ChildPath $f.FullName
        if (-not $rel) { continue }
        [void]$paths.Add($rel.Replace($sep, [char]'/'))
    }
    $paths.Sort([System.StringComparer]::Ordinal)

    $entries = @()
    $totalBytes = [long]0
    foreach ($p in $paths) {
        $nativeRel = $p.Replace([char]'/', $sep)
        $full = Join-Path $bundle $nativeRel
        $entries += [pscustomobject]@{
            path   = $p
            sha256 = Get-PwxSha256 -Path $full
            bytes  = [long](Get-Item -LiteralPath $full).Length
        }
        $totalBytes += [long](Get-Item -LiteralPath $full).Length
    }

    # 3) manifest schema v1 (orden de propiedades fijo; JSON determinista via Set-PwxJsonFile)
    $fileObjs = @()
    foreach ($e in $entries) {
        $fileObjs += [ordered]@{
            path   = $e.path
            sha256 = $e.sha256
            bytes  = $e.bytes
        }
    }
    $manifest = [ordered]@{
        schema_version = '1'
        kind           = 'pwx-store-backup'
        created_utc    = Get-PwxUtcTimestamp
        pwx_version    = Get-PwxVersion
        source         = 'store'
        content_hash   = Get-PwxBackupContentHash -Files $entries
        file_count     = $entries.Count
        total_bytes    = $totalBytes
        complete       = $true
        files          = $fileObjs
    }
    $manifestPath = Join-Path $bundle 'manifest.json'
    Set-PwxJsonFile -Path $manifestPath -Object $manifest | Out-Null

    # 4) checksums.sha256: manifest.json + store/**, rutas /, orden ordinal por
    #    la RUTA (no por la linea: la linea empieza por el hash), UTF-8 sin BOM.
    $ckLines = New-Object 'System.Collections.Generic.List[string]'
    [void]$ckLines.Add(('{0}  {1}' -f (Get-PwxSha256 -Path $manifestPath), 'manifest.json'))
    foreach ($e in $entries) {
        [void]$ckLines.Add(('{0}  {1}' -f $e.sha256, $e.path))
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $bundle 'checksums.sha256'),
        (($ckLines -join "`n") + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))

    # Nota: deliberadamente NO se escribe aqui en el log del workspace: el log
    # vive en store/logs/ y una linea nueva entre dos backups cambiaria el
    # content_hash, violando la estabilidad exigida para el mismo store.
    return [ordered]@{
        name         = (Split-Path -Leaf $bundle)
        path         = $bundle
        created_utc  = $manifest.created_utc
        file_count   = $entries.Count
        total_bytes  = $totalBytes
        content_hash = $manifest.content_hash
    }
}

function Get-PwxBackupList {
    # Bundles validos = subdirectorios de la raiz con manifest.json.
    # Orden estable: nombre de directorio con comparador ordinal.
    $root = Get-PwxBackupRootDir
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'manifest.json')) {
            [void]$names.Add($d.Name)
        }
    }
    $names.Sort([System.StringComparer]::Ordinal)
    $result = @()
    foreach ($n in $names) {
        $m = Get-PwxJsonFile -Path (Join-Path (Join-Path $root $n) 'manifest.json')
        if ($null -eq $m) { continue }
        $result += [pscustomobject][ordered]@{
            name         = $n
            path         = (Join-Path $root $n)
            created_utc  = $m.created_utc
            file_count   = $m.file_count
            total_bytes  = $m.total_bytes
            content_hash = $m.content_hash
            complete     = $m.complete
        }
    }
    return $result
}

function Test-PwxBackupBundle {
    # Verificacion standalone del bundle (no requiere PWX corriendo sobre el store):
    # manifest legible, schema '1', archivos presentes con hash/bytes correctos,
    # rutas contenidas en el bundle, content_hash recalculado y checksums cruzados.
    # Devuelve { ok, problems[], manifest }. problems[] = 'CODIGO: detalle'.
    param([Parameter(Mandatory)][string]$Path)
    $bundle = Resolve-PwxFullPath -Path $Path
    $trim = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [char]'/')
    if ($bundle.Length -gt 1) { $bundle = $bundle.TrimEnd($trim) }
    $mkResult = {
        param($Ok, $Problems, $Manifest)
        [pscustomobject]@{ ok = $Ok; problems = @($Problems); manifest = $Manifest }
    }
    if (-not (Test-Path -LiteralPath $bundle)) {
        return (& $mkResult $false @('BACKUP_BUNDLE_NOT_FOUND: no existe el directorio del bundle') $null)
    }
    $manifestPath = Join-Path $bundle 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return (& $mkResult $false @('BACKUP_MANIFEST_MISSING: falta manifest.json') $null)
    }
    $manifest = $null
    try {
        $manifest = Get-PwxJsonFile -Path $manifestPath
    }
    catch {
        return (& $mkResult $false @(('BACKUP_MANIFEST_INVALID: {0}' -f $_.Exception.Message)) $null)
    }
    if ($null -eq $manifest) {
        return (& $mkResult $false @('BACKUP_MANIFEST_INVALID: manifest.json vacio') $null)
    }
    if ([string]$manifest.schema_version -ne '1') {
        return (& $mkResult $false @(('BACKUP_SCHEMA_UNSUPPORTED: schema_version={0} (se esperaba ''1'')' -f [string]$manifest.schema_version)) $manifest)
    }
    if ([string]$manifest.kind -ne 'pwx-store-backup') {
        return (& $mkResult $false @(('BACKUP_KIND_UNSUPPORTED: kind={0}' -f [string]$manifest.kind)) $manifest)
    }

    $problems = New-Object 'System.Collections.Generic.List[string]'
    if ($manifest.complete -ne $true) {
        [void]$problems.Add('BACKUP_INCOMPLETE: manifest.complete no es true')
    }

    $files = @()
    if ($null -ne $manifest.files) { $files = @($manifest.files) }

    # rutas del manifiesto: formato, presencia y hash
    $manifestByPath = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $listedBytes = [long]0
    foreach ($f in $files) {
        $p = [string]$f.path
        if ($p -notmatch '^store/' -or $p.Contains('\') -or $p.Contains('..') -or $p.Contains(':')) {
            [void]$problems.Add(('BACKUP_PATH_UNSAFE: {0}' -f $p))
            continue
        }
        if ($manifestByPath.ContainsKey($p)) {
            [void]$problems.Add(('BACKUP_PATH_DUPLICADA: {0}' -f $p))
            continue
        }
        $nativeRel = $p.Replace([char]'/', $sep)
        $full = Join-Path $bundle $nativeRel
        $contained = $true
        try {
            Assert-PwxSafeWorkspacePath -WorkspacePath $bundle -Path $full | Out-Null
        }
        catch {
            $contained = $false
        }
        if (-not $contained) {
            [void]$problems.Add(('BACKUP_PATH_UNSAFE: {0}' -f $p))
            continue
        }
        $manifestByPath[$p] = [string]$f.sha256
        if (-not (Test-Path -LiteralPath $full)) {
            [void]$problems.Add(('BACKUP_FILE_MISSING: {0}' -f $p))
            continue
        }
        $actual = Get-PwxSha256 -Path $full
        if ($actual -ne [string]$f.sha256) {
            [void]$problems.Add(('BACKUP_HASH_MISMATCH: {0} (esperado {1}, actual {2})' -f $p, [string]$f.sha256, $actual))
        }
        $size = [long](Get-Item -LiteralPath $full).Length
        if ($size -ne [long]$f.bytes) {
            [void]$problems.Add(('BACKUP_SIZE_MISMATCH: {0} (esperado {1}, actual {2})' -f $p, [long]$f.bytes, $size))
        }
        $listedBytes += [long]$f.bytes
    }

    if ($files.Count -ne [int]$manifest.file_count) {
        [void]$problems.Add(('BACKUP_COUNT_MISMATCH: manifest.file_count={0} pero files tiene {1}' -f [int]$manifest.file_count, $files.Count))
    }
    if ($listedBytes -ne [long]$manifest.total_bytes) {
        [void]$problems.Add(('BACKUP_BYTES_MISMATCH: manifest.total_bytes={0} pero la suma de files es {1}' -f [long]$manifest.total_bytes, $listedBytes))
    }

    # archivos reales del bundle: content_hash recalculado + deteccion de sobrantes
    $actualPaths = New-Object 'System.Collections.Generic.List[string]'
    $storeDir = Join-Path $bundle 'store'
    if (Test-Path -LiteralPath $storeDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $storeDir -File -Recurse -ErrorAction SilentlyContinue)) {
            $rel = Get-PwxRelativePath -BasePath $bundle -ChildPath $f.FullName
            if (-not $rel) { continue }
            [void]$actualPaths.Add($rel.Replace($sep, [char]'/'))
        }
    }
    $actualPaths.Sort([System.StringComparer]::Ordinal)
    $recomputed = @()
    $actualBytes = [long]0
    foreach ($p in $actualPaths) {
        if (-not $manifestByPath.ContainsKey($p)) {
            [void]$problems.Add(('BACKUP_FILE_UNLISTED: {0} existe en el bundle pero no en manifest' -f $p))
            continue
        }
        $full = Join-Path $bundle $p.Replace([char]'/', $sep)
        $recomputed += [pscustomobject]@{ path = $p; sha256 = Get-PwxSha256 -Path $full }
        $actualBytes += [long](Get-Item -LiteralPath $full).Length
    }
    $expectedHash = [string]$manifest.content_hash
    $actualHash = Get-PwxBackupContentHash -Files $recomputed
    if ($actualHash -ne $expectedHash) {
        [void]$problems.Add(('BACKUP_CONTENT_HASH_MISMATCH: manifest={0} actual={1}' -f $expectedHash, $actualHash))
    }

    # checksums.sha256: formato, cobertura (manifest.json + cada archivo) y hash
    $checksumsPath = Join-Path $bundle 'checksums.sha256'
    if (-not (Test-Path -LiteralPath $checksumsPath)) {
        [void]$problems.Add('BACKUP_CHECKSUMS_MISSING: falta checksums.sha256')
    }
    else {
        $ckByPath = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        foreach ($line in ([System.IO.File]::ReadAllLines($checksumsPath))) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -notmatch '^([0-9A-Fa-f]{64})  (.+)$') {
                [void]$problems.Add(('BACKUP_CHECKSUMS_FORMAT: linea invalida: {0}' -f $line))
                continue
            }
            # capturar el hash ANTES de cualquier otro -notmatch (pisan $Matches)
            $ckHash = $Matches[1]
            $ckPath = $Matches[2]
            if ($ckPath -notmatch '^(store/|manifest\.json$)' -or $ckPath.Contains('\') -or $ckPath.Contains('..') -or $ckPath.Contains(':')) {
                [void]$problems.Add(('BACKUP_PATH_UNSAFE: {0}' -f $ckPath))
                continue
            }
            if ($ckByPath.ContainsKey($ckPath)) {
                [void]$problems.Add(('BACKUP_CHECKSUMS_DUPLICADA: {0}' -f $ckPath))
                continue
            }
            $ckByPath[$ckPath] = $ckHash
        }
        $expectedPaths = New-Object 'System.Collections.Generic.List[string]'
        [void]$expectedPaths.Add('manifest.json')
        foreach ($p in $manifestByPath.Keys) { [void]$expectedPaths.Add($p) }
        foreach ($p in $expectedPaths) {
            if (-not $ckByPath.ContainsKey($p)) {
                [void]$problems.Add(('BACKUP_CHECKSUM_COVERAGE: sin linea en checksums.sha256 para {0}' -f $p))
                continue
            }
            $nativeRel = $p.Replace([char]'/', $sep)
            $full = Join-Path $bundle $nativeRel
            if (-not (Test-Path -LiteralPath $full)) {
                [void]$problems.Add(('BACKUP_CHECKSUM_MISMATCH: {0} (archivo inexistente)' -f $p))
                continue
            }
            $actual = Get-PwxSha256 -Path $full
            if ($actual -ne $ckByPath[$p]) {
                [void]$problems.Add(('BACKUP_CHECKSUM_MISMATCH: {0} (esperado {1}, actual {2})' -f $p, $ckByPath[$p], $actual))
            }
        }
    }

    $arr = @()
    foreach ($p in $problems) { $arr += $p }
    return [pscustomobject]@{
        ok       = ($arr.Count -eq 0)
        problems = $arr
        manifest = $manifest
    }
}

function Restore-PwxBackup {
    # PR-3: restore verificable, no destructivo y lo mas atomico posible.
    # Siempre al workspace actual (Get-PwxConfig.WorkspacePath == lo que usaria
    # Get-PwxWorkspacePath, pero SIN el mkdir efecto secundario: la decision de
    # existencia/vacio se toma aqui). Sin -TargetWorkspace en v1.
    # Orden de guardas:
    #   1) BACKUP_RESTORE_BUNDLE_DENTRO_DEL_STORE (antes de tocar nada)
    #   2) Test-PwxBackupBundle debe pasar -> BACKUP_RESTORE_VERIFY_FAILED
    #   3) workspace no vacio exige -Force -> BACKUP_RESTORE_FORCE_REQUIRED
    #   4) staging en <workspace>.restore-tmp-<stamp> + hashes contra manifest
    #   5) swap por rename: workspace -> <workspace>.pre-restore-<stamp> (si habia
    #      datos; nunca se borra automaticamente) y tmp -> workspace
    # Sin logging ni escrituras dentro del workspace: el restore deja
    # exactamente los bytes respaldados.
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force
    )
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $sepStr = [string]$sep
    $trim = [char[]]@($sep, [char]'/')

    $bundle = Resolve-PwxFullPath -Path $Path
    if ($bundle.Length -gt 1) { $bundle = $bundle.TrimEnd($trim) }
    $target = [System.IO.Path]::GetFullPath([string](Get-PwxConfig).WorkspacePath)
    if ($target.Length -gt 1) { $target = $target.TrimEnd($trim) }

    # Guarda C: el bundle no puede vivir dentro del workspace (el swap por
    # rename moveria el bundle en mitad del proceso y romperia las rutas).
    if ($bundle -eq $target -or $bundle.StartsWith($target + $sepStr, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('BACKUP_RESTORE_BUNDLE_DENTRO_DEL_STORE: el bundle {0} esta dentro del workspace {1}. Use una raiz PWX_BACKUP_DIR fuera del store.' -f $bundle, $target)
    }

    # Guarda A: el bundle debe verificar OK antes de tocar nada.
    $check = Test-PwxBackupBundle -Path $bundle
    if (-not $check.ok) {
        throw ('BACKUP_RESTORE_VERIFY_FAILED: bundle invalido, no se toco el workspace. Problemas: {0}' -f (@($check.problems) -join '; '))
    }
    $manifest = $check.manifest

    # Guarda B: workspace con datos exige -Force.
    $exists = Test-Path -LiteralPath $target
    $isEmpty = $true
    if ($exists) {
        $items = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)
        $isEmpty = ($items.Count -eq 0)
    }
    $needPre = ($exists -and (-not $isEmpty))
    if ($needPre -and (-not $Force)) {
        throw ('BACKUP_RESTORE_FORCE_REQUIRED: el workspace {0} no esta vacio; sin -Force no se toca nada. Con -Force el store actual se preserva en {0}.pre-restore-<UTCSTAMP>.' -f $target)
    }

    # Nombres de hermanos (mismo parent => mismo volumen) sin colision.
    $stamp = ([DateTime]::UtcNow).ToString('yyyyMMdd-HHmmss')
    $tmp = '{0}.restore-tmp-{1}' -f $target, $stamp
    $pre = '{0}.pre-restore-{1}' -f $target, $stamp
    $suffix = 2
    while ((Test-Path -LiteralPath $tmp) -or ($needPre -and (Test-Path -LiteralPath $pre))) {
        $tmp = '{0}.restore-tmp-{1}-{2}' -f $target, $stamp, $suffix
        $pre = '{0}.pre-restore-{1}-{2}' -f $target, $stamp, $suffix
        $suffix++
    }

    # Staging: copiar <bundle>/store/** al tmp re-validando contencion por ruta
    # y re-verificando cada sha256 contra el manifest (barato y local).
    New-PwxDirectory -Path $tmp | Out-Null
    $files = @($manifest.files)
    $copied = 0
    foreach ($f in $files) {
        $p = [string]$f.path
        if (-not $p.StartsWith('store/', [System.StringComparison]::Ordinal) -or $p.Contains('\') -or $p.Contains('..') -or $p.Contains(':')) {
            throw ('BACKUP_RESTORE_STAGING_FAILED: ruta insegura en manifest: {0} (tmp queda en {1}; store intacto)' -f $p, $tmp)
        }
        $srcFull = Join-Path $bundle $p.Replace([char]'/', $sep)
        try {
            Assert-PwxSafeWorkspacePath -WorkspacePath $bundle -Path $srcFull | Out-Null
        }
        catch {
            throw ('BACKUP_RESTORE_STAGING_FAILED: origen fuera del bundle: {0} (tmp queda en {1}; store intacto)' -f $p, $tmp)
        }
        $destRel = $p.Substring('store/'.Length)
        $dest = Join-Path $tmp $destRel.Replace([char]'/', $sep)
        try {
            Assert-PwxSafeWorkspacePath -WorkspacePath $tmp -Path $dest | Out-Null
        }
        catch {
            throw ('BACKUP_RESTORE_STAGING_FAILED: destino fuera del tmp: {0} (tmp queda en {1}; store intacto)' -f $p, $tmp)
        }
        New-PwxDirectory -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $srcFull -Destination $dest -Force
        $got = Get-PwxSha256 -Path $dest
        if ($got -ne [string]$f.sha256) {
            throw ('BACKUP_RESTORE_STAGING_FAILED: hash distinto en tmp para {0} (esperado {1}, actual {2}; tmp queda en {3}; store intacto)' -f $p, [string]$f.sha256, $got, $tmp)
        }
        $copied++
    }
    if ($copied -ne $files.Count) {
        throw ('BACKUP_RESTORE_STAGING_FAILED: se copiaron {0} de {1} archivos (tmp queda en {2}; store intacto)' -f $copied, $files.Count, $tmp)
    }

    # Swap. Recien aqui se mueve el workspace actual (nada antes del tmp completo).
    $preRestore = $null
    try {
        if (Test-Path -LiteralPath $target) {
            $itemsNow = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)
            if ($itemsNow.Count -eq 0) {
                Remove-Item -LiteralPath $target -Force
            }
            else {
                if (-not $Force) {
                    throw ('BACKUP_RESTORE_FORCE_REQUIRED: el workspace dejo de estar vacio durante el restore; se aborta antes del swap (tmp en {0})' -f $tmp)
                }
                Move-Item -LiteralPath $target -Destination $pre
                $preRestore = $pre
            }
        }
        Move-Item -LiteralPath $tmp -Destination $target
    }
    catch {
        if ($_.Exception.Message -like 'BACKUP_RESTORE_FORCE_REQUIRED*') { throw }
        $rolledBack = $false
        if ($preRestore -and (-not (Test-Path -LiteralPath $target)) -and (Test-Path -LiteralPath $preRestore)) {
            try {
                Move-Item -LiteralPath $preRestore -Destination $target
                $rolledBack = $true
            }
            catch {
                $rolledBack = $false
            }
        }
        $msg = 'BACKUP_RESTORE_SWAP_FAILED: no se pudo completar el swap: {0}' -f $_.Exception.Message
        if ($rolledBack) {
            $msg += ('. Rollback OK: el store original volvio a {0}; el contenido nuevo queda en {1} (renombrar a mano si hace falta)' -f $target, $tmp)
        }
        elseif ($preRestore) {
            $msg += ('. Sin rollback automatico: estado previo en {0} y contenido listo en {1}; renombrar manualmente para recuperar' -f $preRestore, $tmp)
        }
        else {
            $msg += ('. El store no llego a moverse; el contenido listo queda en {0} (renombrar a mano si hace falta)' -f $tmp)
        }
        throw $msg
    }

    # Deliberadamente sin Write-PwxLog: escribiria dentro del store restaurado.
    return [ordered]@{
        workspace        = $target
        bundle           = $bundle
        restored_at_utc  = Get-PwxUtcTimestamp
        pre_restore_path = $preRestore
        tmp_path         = $null
        file_count       = [int]$manifest.file_count
        total_bytes      = [long]$manifest.total_bytes
        content_hash     = [string]$manifest.content_hash
    }
}
