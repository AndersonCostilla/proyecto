Run-PwxTest -Name 'C1: escritura atomica no deja temporales y persiste JSON' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $path = Join-Path $ws 'probe\file.json'
    Set-PwxJsonFile -Path $path -Object @{ a = 1; arr = @('x', 'y') } | Out-Null
    $read = Get-PwxJsonFile -Path $path
    Assert-PwxEqual 1 ([int]$read.a)
    Assert-PwxEqual 'x' $read.arr[0]
    Set-PwxJsonFile -Path $path -Object @{ a = 2 } | Out-Null
    $updated = Get-PwxJsonFile -Path $path
    Assert-PwxEqual 2 ([int]$updated.a)
    $dir = Split-Path -Parent $path
    $tmp = @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -ErrorAction SilentlyContinue)
    Assert-PwxTrue ($tmp.Count -eq 0) 'No deben quedar archivos temporales'
    $bak = @(Get-ChildItem -LiteralPath $dir -Filter '*.bak' -ErrorAction SilentlyContinue)
    Assert-PwxTrue ($bak.Count -eq 0) 'No deben quedar archivos backup'
}

Run-PwxTest -Name 'T10: JSON corrupto lanza error claro' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $path = Join-Path $ws 'corrupt\job.json'
    New-PwxDirectory -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllText($path, '{esto no es json valido', (New-Object System.Text.UTF8Encoding($false)))
    $threw = $false
    try { Get-PwxJsonFile -Path $path } catch { $threw = $true }
    Assert-PwxTrue $threw 'Debe lanzar ante JSON corrupto'
}

Run-PwxTest -Name 'T10: sequences corrupto no genera IDs (fail-loud, sin duplicados)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $id1 = New-PwxSequenceId -Prefix 'C'
    Assert-PwxEqual 'C-0001' $id1
    $seqFile = Join-Path $ws '_meta\sequences.json'
    Assert-PwxTrue (Test-Path -LiteralPath $seqFile) 'sequences.json debe existir'
    [System.IO.File]::WriteAllText($seqFile, 'corrupto', (New-Object System.Text.UTF8Encoding($false)))
    $threw = $false
    try { New-PwxSequenceId -Prefix 'C' } catch { $threw = $true }
    Assert-PwxTrue $threw 'Debe fallar con sequences corrupto en lugar de generar IDs duplicados'
}

Run-PwxTest -Name 'C1: lock de secuencias protege el read-modify-write' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    New-PwxSequenceId -Prefix 'C' | Out-Null
    $lockPath = Join-Path $ws '_meta\sequences.lock'
    Assert-PwxTrue (Test-Path -LiteralPath $lockPath) 'Archivo de lock debe existir'
    $manual = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $threw = $false
        try { Enter-PwxFileLock -Path $lockPath -TimeoutMs 150 } catch { $threw = $true }
        Assert-PwxTrue $threw 'Con el lock tomado, una segunda adquisicion debe bloquearse'
    }
    finally {
        $manual.Dispose()
    }
    $handle = Enter-PwxFileLock -Path $lockPath -TimeoutMs 1000
    try {
        Assert-PwxTrue ($null -ne $handle) 'Lock liberado debe permitir la adquisicion'
    }
    finally {
        Exit-PwxFileLock $handle
    }
    $id = New-PwxSequenceId -Prefix 'C'
    Assert-PwxEqual 'C-0002' $id 'La secuencia debe continuar tras liberar el lock'
}

Run-PwxTest -Name 'ingest: archivo valido se copia a input y registra metadata' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Ingreso'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $src = Join-Path $ws 'fuente-datos.xlsx'
    [System.IO.File]::WriteAllText($src, 'contenido de prueba', (New-Object System.Text.UTF8Encoding($false)))
    $entry = Add-PwxJobInputFile -JobId $job.id -SourcePath $src
    Assert-PwxEqual 'fuente-datos.xlsx' $entry.name
    $found = Find-PwxJob -JobId $job.id
    $dest = Join-Path $found.JobDir 'input\fuente-datos.xlsx'
    Assert-PwxTrue (Test-Path -LiteralPath $dest) 'Archivo debe copiarse a input'
    $jobAfter = Get-PwxJob -JobId $job.id
    $registered = @($jobAfter.files.input | Where-Object { $_.name -eq 'fuente-datos.xlsx' })
    Assert-PwxTrue ($registered.Count -eq 1) 'Debe quedar registrado en files.input'
}

Run-PwxTest -Name 'ingest: nombre peligroso rechazado (separadores / ..)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Ingest2'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $src = Join-Path $ws 'ok.txt'
    [System.IO.File]::WriteAllText($src, 'x', (New-Object System.Text.UTF8Encoding($false)))
    Assert-PwxThrows { Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName 'a\b.txt' }
    Assert-PwxThrows { Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName 'a/b.txt' }
    Assert-PwxThrows { Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName '..\evil.txt' }
    Assert-PwxThrows { Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName '../evil.txt' }
}

Run-PwxTest -Name 'ingest: ruta absoluta rechazada' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Ingest3'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $src = Join-Path $ws 'ok2.txt'
    [System.IO.File]::WriteAllText($src, 'x', (New-Object System.Text.UTF8Encoding($false)))
    Assert-PwxThrows { Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName 'C:\evil.txt' }
}

Run-PwxTest -Name 'ingest: destino fuera del job rechazado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Ingest4'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $src = Join-Path $ws 'ok3.txt'
    [System.IO.File]::WriteAllText($src, 'x', (New-Object System.Text.UTF8Encoding($false)))
    Assert-PwxThrows { Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName '..\..\fuera.txt' }
    $found = Find-PwxJob -JobId $job.id
    $leak = Join-Path $found.JobDir '..\fuera.txt'
    Assert-PwxTrue (-not (Test-Path -LiteralPath $leak)) 'No debe escribirse fuera del job'
}