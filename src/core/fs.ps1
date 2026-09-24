function Resolve-PwxFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Ruta vacia'
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    return $full
}

function Get-PwxRelativePath {
    param([string]$BasePath, [string]$ChildPath)
    $base = Resolve-PwxFullPath -Path $BasePath
    $child = Resolve-PwxFullPath -Path $ChildPath
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $result = $null
    if ($child.StartsWith($base + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
        $result = $child.Substring($base.Length + 1)
    }
    return $result
}

function Assert-PwxSafeWorkspacePath {
    param([string]$WorkspacePath, [string]$Path)
    $ws = Resolve-PwxFullPath -Path $WorkspacePath
    $full = $null
    try {
        $full = Resolve-PwxFullPath -Path $Path
    }
    catch {
        throw "Ruta no resolubille dentro del workspace: $Path"
    }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($ws + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path traversal bloqueado: '$Path' queda fuera de '$ws'"
    }
    return $full
}

function Get-PwxSafePath {
    param([string]$WorkspacePath, [string]$Path)
    return (Assert-PwxSafeWorkspacePath -WorkspacePath $WorkspacePath -Path $Path)
}

function Assert-PwxSafeFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'Nombre de archivo vacio'
    }
    if ($Name -match '[\\/]|\.\.') {
        throw "Nombre de archivo invalido (no se permiten separadores ni '..'): $Name"
    }
    return $Name
}

function New-PwxDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    }
    return $Path
}

function Set-PwxJsonFile {
    param([string]$Path, [object]$Object)
    $parent = Split-Path -Parent $Path
    New-PwxDirectory -Path $parent | Out-Null
    $json = $Object | ConvertTo-Json -Depth 100
    $tmp = Join-Path $parent ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $stream = [System.IO.File]::Create($tmp)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $Path) {
            $backup = Join-Path $parent ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.bak')
            [System.IO.File]::Replace($tmp, $Path, $backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue | Out-Null
        }
        else {
            [System.IO.File]::Move($tmp, $Path)
        }
        return $Path
    }
    catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null
        }
        throw
    }
}

function Enter-PwxFileLock {
    param([string]$Path, [int]$TimeoutMs = 10000)
    $parent = Split-Path -Parent $Path
    New-PwxDirectory -Path $parent | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            return ([System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None))
        }
        catch [System.IO.IOException] {
            if ($sw.ElapsedMilliseconds -ge $TimeoutMs) {
                throw "Timeout obteniendo lock '$Path' tras $($TimeoutMs) ms"
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Exit-PwxFileLock {
    param([object]$Handle)
    if ($null -ne $Handle) {
        $Handle.Dispose()
    }
}

function Get-PwxJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try {
        return ($text | ConvertFrom-Json)
    }
    catch {
        throw "JSON invalido en $Path : $($_.Exception.Message)"
    }
}

function Get-PwxSha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Archivo inexistente para hash: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}